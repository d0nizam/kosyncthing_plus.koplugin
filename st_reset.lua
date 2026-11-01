-- st_reset.lua — Reset & re-pair flow
--
-- Provides a single "I want to start over" button that solves the long
-- tail of "my Syncthing is broken and I don't know why" support cases
-- without forcing the user to dig into config files.
--
-- The reset:
--   1. Stops Syncthing if running.
--   2. Deletes config.xml, the database directory, and the cached device-id.
--   3. Wipes the plugin's saved settings (port, password, automation).
--   4. Tells the user to restart Syncthing — first run will regenerate.
--
-- Synced folders on disk are LEFT ALONE.  Reset means "forget Syncthing's
-- internal state", not "delete files".  The user gets their device ID back
-- intact only if they note it down before reset; we make this clear in the
-- confirm dialog.

local DataStorage = require("datastorage")
local ConfirmBox  = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager   = require("ui/uimanager")
local _           = require("syncthing_i18n").gettext

local U = require("st_utils")

---------------------------------------------------------------------------
-- Internal: actually delete things.  Idempotent — safe to call when files
-- don't exist.
---------------------------------------------------------------------------
local function _wipe(self)
    local base = DataStorage:getFullDataDir() .. "/settings"
    local FS   = require("st_filesystem")

    -- AD-19: capture the relocated database directory before the settings
    -- loop below clears syncthing_data_dir, so the orphaned external DB (e.g.
    -- /var/local/kosyncthing_plus) is purged too.  Read it here, purge it after
    -- the config directories.
    local relocated_data = G_reader_settings:readSetting("syncthing_data_dir")

    -- Purge the standard directory and the obsolete directory that may remain
    -- after upgrading from a release that supported a second Syncthing binary.
    -- deletePluginSettings() applies the same migration cleanup (AD-18/BUG-25).
    local any_failed = false
    for _, dirname in ipairs({ "syncthing", "syncthing-legacy" }) do
        local dir = base .. "/" .. dirname
        local ok, _ = FS.purge(dir)
        if not ok then any_failed = true end
    end
    -- Purge the relocated database directory if it lives outside settings/.
    if relocated_data and relocated_data ~= ""
            and not relocated_data:find("/settings/syncthing", 1, true) then
        local pcall_ok, purge_ok = pcall(function() return FS.purge(relocated_data) end)
        if not pcall_ok or not purge_ok then any_failed = true end
    end
    if any_failed then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Factory reset could not completely remove Syncthing's data directory.\n\n"
                  .. "Some files may remain. Try rebooting your device and running the reset again."),
            timeout = 5,
        })
    end

    -- Plugin-side settings stored in KOReader's global settings.  We use
    -- the single source of truth from st_utils so this list and the one
    -- in st_process.deletePluginSettings can never drift apart.  Note
    -- that this INCLUDES syncthing_settings_version: a future schema
    -- migration must run after a factory reset too, so we drop the
    -- version marker and let migrations re-establish a clean baseline
    -- on the next start.
    for _, k in ipairs(U.ALL_SETTINGS_KEYS) do
        G_reader_settings:delSetting(k)
    end

    -- Reset in-memory state on the running plugin instance so the user
    -- doesn't have to restart KOReader.  Every setting we wiped from
    -- G_reader_settings needs a matching reset here — otherwise the
    -- first call to saveSetting() after the reset will write the stale
    -- in-memory value back to disk.
    self.api_key                = nil
    self.gui_password           = nil
    self.gui_user               = "syncthing"
    self.syncthing_port         = "8384"

    self.auto_start_charging    	= false
    self.autostart_mode         	= "off"
    self.notifications_enabled  	= true   -- default is true (main.lua init); false was wrong (BUG-26)
    self.resource_profile       	= "low"
    self.network_access         	= "lan"
	self.periodic_sync_enabled      = false
    self.periodic_sync_interval_min = 30
	self:_stopPeriodicSyncTimer()
    self._last_api_error        	= nil

    -- BUG-28: the BUG-27 fix intentionally keeps _was_running_before_suspend
    -- alive across network-offline resumes so that runNetworkConnected() can
    -- restore Syncthing later.  That is correct for normal suspend/resume
    -- cycles, but _wipe() must reset it: a factory reset means "start fresh",
    -- and leaving the flag true causes runNetworkConnected() to silently
    -- auto-start Syncthing on the next network event — directly contradicting
    -- the user's intent.  This reset does NOT affect the BUG-27 fix because
    -- _wipe() only runs on an explicit confirmed factory reset, never during
    -- a suspend/resume cycle.
    self._was_running_before_suspend = false

    -- BUG-29: if a Quick Sync was in progress when the user confirmed the
    -- reset, _quick_sync_active stays true after _wipe() (reset calls
    -- stop() which terminates the daemon and the sync flow, but _wipe()
    -- itself did not clear the guard).  Leaving it true blocks the next
    -- Quick Sync tap with "already in progress" until KOReader restarts.
    -- The flow-counter and active-flow-id are cosmetic companions: clearing
    -- them prevents a stale flow_id from suppressing the progress header on
    -- the first sync after reset.
    self._quick_sync_active  = false
    self._sync_flow_counter  = 0
    self._active_flow_id     = nil

    -- Cosmetic: clear stale progress display so the status header shows the
    -- correct "Stopped" state immediately after reset, not a leftover
    -- percentage from a sync that completed before the reset.
    self._last_sync_progress   = nil
    self._health_sync_snapshot = nil

    -- BUG-31: _notification_queue and _notification_active are initialised
    -- lazily by showNotification() — they are not set in init() — so they
    -- are not driven by the ALL_SETTINGS_KEYS loop above.  If a factory
    -- reset happens while a notification is draining (_notification_active
    -- is true), the drain loop's timer fires after the reset and finds
    -- _notification_active still true; subsequent calls to showNotification()
    -- enqueue items but never call _drainNotificationQueue(), locking the
    -- queue until KOReader restarts.  Setting both to nil/false restores the
    -- pre-first-call state; showNotification()'s lazy guard re-initialises
    -- them correctly on the next call.
    --
    -- NOT-A-BUG (regression analysis note): a pending _drain_timer can fire
    -- after this reset.  It calls _drainNotificationQueue(), which checks
    -- "if not self._notification_queue" — nil → active=false; return.  The
    -- timer self-terminates cleanly; no crash, no re-queuing.
    self._notification_queue  = nil
    self._notification_active = false

    -- BUG-33 companion: if a drain timer is pending at reset time, cancel it.
    -- The timer holds a closure over `self`; without this it would fire after
    -- the reset, call _drainNotificationQueue() on a wiped queue (harmless),
    -- but keep `self` referenced in the GC root set longer than necessary.
    if self._drain_timer then
        UIManager:unschedule(self._drain_timer)
        self._drain_timer = nil
    end

    -- Reset conflict-notification dedup state so a fresh conflict re-notifies
    -- after a reset (used by both the daemon path and the Android lfs scanner).
    self._last_notified_conflict_count = nil

    -- Android remote mode: drop the in-memory connection state too, so the menu
    -- falls back to the "Connect to the Syncthing app" screen instead of a
    -- half-connected state with a wiped key.  Guarded on the Android flags so
    -- this can NEVER flip a Kindle/Kobo install into the Android menu routing.
    if self._android_mode or self._android_unavailable then
        self._android_mode                = false
        self._android_unavailable         = true
        self._api_scheme                  = nil
        self._android_is_running_cache    = nil
        self._android_is_running_cache_at = 0
    end

    self:_cacheInvalidate()
    if self.cache then self.cache:clear() end

	self:_clearApiErrors()

    -- Invalidate every module-level cache so the plugin re-probes
    -- everything on the next interaction.  Without this, sticky caches
    -- (binary presence, version string, device-id) survive the reset
    -- and produce confusing UI states.
    local api_mod = require("st_api")
    api_mod._invalidateDeviceIdCache()
    if self._invalidateBinaryCache  then self:_invalidateBinaryCache()  end
    if self._invalidateVersionCache then self:_invalidateVersionCache() end
    U.invalidateLoopbackCache()
    U.invalidateCurlCache()
    U.invalidateDataDirCache()
end

---------------------------------------------------------------------------
-- Public: prompt the user, then perform the reset.
---------------------------------------------------------------------------
local function resetEverything(self, on_done)
    -- Capture before _wipe(), which flips _android_mode off.
    local is_android = self._android_mode or self._android_unavailable

    local function finish()
        UIManager:show(InfoMessage:new{
            timeout = 5,
            text    = is_android
                and _("Connection reset.\n\n"
                   .. "The saved API key and the plugin's settings on this device were cleared. "
                   .. "Tap \"Connect to the Syncthing app\" to set it up again.\n\n"
                   .. "The Syncthing app and its data were not touched.")
                or  _("Reset complete.\n\n"
                   .. "All Syncthing settings, the database, and your device ID have been cleared.\n\n"
                   .. "Start Syncthing again to generate a fresh setup.\n"
                   .. "Your synced files on disk were not touched."),
        })
        if on_done then on_done() end
    end

    local function doReset()
        -- On Android there is no local daemon to stop (stop() is a no-op and
        -- cannot stop the separate Syncthing app), so skip the stop/verify gate
        -- and wipe directly.
        if not is_android and self:isRunning() then
            self:stop(function()
                -- Double-check that the daemon really stopped before wiping.
                if self:isRunning() then
                    UIManager:show(InfoMessage:new{
                        icon = "notice-warning",
                        text = _("Could not stop Syncthing.\n\n"
                              .. "The daemon is still running and cannot be reset safely.\n"
                              .. "Try rebooting your device, then try again."),
                        timeout = 5,
                    })
                    if on_done then on_done() end
                    return
                end
                _wipe(self)
                finish()
            end)
        else
            _wipe(self)
            finish()
        end
    end

    if is_android then
        -- Low-stakes on Android (you just re-enter the key), so a single
        -- confirmation is enough; no daemon or device ID is destroyed.
        UIManager:show(ConfirmBox:new{
            text = _(
                "Reset the Syncthing connection?\n\n"
                .. "This clears the saved API key and the plugin's settings on this device "
                .. "and returns to the connect screen.\n\n"
                .. "The Syncthing app and its data are NOT touched — you can reconnect "
                .. "by entering the API key again."),
            ok_text     = _("Reset"),
            cancel_text = _("Cancel"),
            ok_callback = doReset,
        })
    else
        UIManager:show(ConfirmBox:new{
            text = _(
                "Reset Syncthing to factory defaults?\n\n"
                .. "This will:\n"
                .. "  • stop Syncthing if it's running\n"
                .. "  • delete the config (folder list, devices, password)\n"
                .. "  • delete the local sync database\n"
                .. "  • generate a NEW device ID on the next start\n\n"
                .. "Your synced files on disk are NOT deleted.\n\n"
                .. "Other devices will need to re-pair with the new ID.\n"
                .. "This cannot be undone."),
            ok_text     = _("Continue →"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                -- Second confirmation: prevents accidental e-ink misfires from
                -- triggering a destructive irreversible operation.
                UIManager:show(ConfirmBox:new{
                    text = _(
                        "⚠  Final confirmation  ⚠\n\n"
                        .. "Tap \"Reset everything\" to wipe all Syncthing\n"
                        .. "settings and your device ID.\n\n"
                        .. "There is no undo."),
                    ok_text     = _("Reset everything"),
                    cancel_text = _("Cancel"),
                    ok_callback = doReset,
                })
            end,
        })
    end
end

return {
    resetEverything = resetEverything,
}
