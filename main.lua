-- main.lua - Plugin entry point, lifecycle, cache layer, periodic sync timer, event handlers, notification queue, Dispatcher integration
local DataStorage     = require("datastorage")
local Device          = require("device")
local Dispatcher      = require("dispatcher")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local NetworkMgr      = require("ui/network/manager")
local ffiutil         = require("ffi/util")
local logger          = require("logger")
local util 			  = require("util")
local time 		  	  = require("ui/time")
local T               = ffiutil.template

-- Try to load CacheSQLite for persistent cache; fall back to in-memory table
local CacheSQLite_available, CacheSQLite = pcall(require, "cachesqlite")
if not CacheSQLite_available then
    CacheSQLite = nil
end

local FallbackCache = {}
function FallbackCache:new(_)
    local store = {}
    return {
        check = function(_, key)
            local entry = store[key]
            if entry then
                return { val = entry.val, ts = entry.ts }
            end
            return nil
        end,
        insert = function(_, key, entry)
            store[key] = entry
        end,
        remove = function(_, key)
            store[key] = nil
        end,
        clear = function(_)
            for k in pairs(store) do store[k] = nil end
        end,
    }
end

local _    = require("syncthing_i18n").gettext
local path = DataStorage:getFullDataDir()

-- Android support is handled per-instance in Syncthing:init() (remote mode via
-- st_android), not by disabling the plugin at load time.  On Kindle/Kobo this
-- file behaves exactly as before.

-- Load all sub-modules
local U                = require("st_utils")
local public_api       = require("st_api_public")
local IgnoreRegistry   = public_api.IgnoreRegistry
local update_mod       = require("st_update")
local api_mod          = require("st_api")
local conflict_mod     = require("st_conflict")
local process_mod      = require("st_process")
local sync_mod         = require("st_sync")
local menu_mod         = require("st_menu")
local health_mod       = require("st_health")
local pair_mod         = require("st_pair")
local reset_mod        = require("st_reset")
local orchestrator_mod = require("st_orchestrator")

local Syncthing = WidgetContainer:extend{
    name        = "kosyncthing_plus",
    is_doc_only = false,
}

---------------------------------------------------------------------------
-- Cache layer (using KOReader's CacheSQLite with in-memory fallback)
---------------------------------------------------------------------------
local CACHE_TTL = 5  -- default TTL in seconds

local function cacheGet(self, key, ttl)
    if not self.cache then return nil end
    local data = self.cache:check(key)
    if data == nil then return nil end
    if data.val == nil then return nil end
	local now = os.time()
	local ts = tonumber(data.ts) or 0
	local effective_ttl = ttl or CACHE_TTL
	local age = now - ts
	if age < 0 or age > effective_ttl then
		self.cache:remove(key)
		return nil
	end
    return data.val
end

local function cacheSet(self, key, val)
    if not self.cache then return val end
	self.cache:insert(key, {
		val = val,
		ts  = os.time(),
	})
    return val
end

---------------------------------------------------------------------------
-- Cache invalidation strategy
---------------------------------------------------------------------------
local function invalidateProcess(self)
    if not self.cache then return end
    self.cache:remove("is_running")
    self._connections_cache         = nil
    self._connections_total         = nil
    self._connections_cache_time    = 0
end

local function invalidateFolders(self)
    if not self.cache then return end
    self.cache:remove("folder_health")
    self.cache:remove("any_paused")
end

-- Conflict files on disk changed.  Always paired with invalidateFolders
-- because resolving a conflict can change the folder's needBytes.
local function invalidateConflictCache(self)
    if not self.cache then return end
    self.cache:remove("conflicts")
    self.cache:remove("folder_health")
    self.cache:remove("any_paused")
end

local function cacheInvalidate(self)
    if not self.cache then return end
    self.cache:remove("is_running")
    self.cache:remove("folder_health")
    self.cache:remove("any_paused")
end

---------------------------------------------------------------------------
-- Error handling
---------------------------------------------------------------------------
local _error_dialog_shown = false

local function syncthing_error(context, err)
    local msg = "[Syncthing] Error in " .. context .. ":\n" .. tostring(err)
    logger.err(msg)
    if _error_dialog_shown then return end
    _error_dialog_shown = true
    local ok_sched = pcall(UIManager.scheduleIn, UIManager, 0, function()
        UIManager:show(require("ui/widget/confirmbox"):new{
            text                = msg,
            icon                = "notice-warning",
            ok_text             = _("Restart KOReader"),
            cancel_text         = _("Dismiss"),
            other_buttons_first = true,
            ok_callback         = function()
                _error_dialog_shown = false
                UIManager:restartKOReader()
            end,
            cancel_callback     = function() _error_dialog_shown = false end,
        })
    end)
    if not ok_sched then
        -- Scheduling failed — reset the flag so the next real error
        -- isn't silently swallowed.
        _error_dialog_shown = false
    end
end

local function safe(context, fn)
    return function(...)
        local ok, result = xpcall(fn, debug.traceback, ...)
        if not ok then
            pcall(syncthing_error, context, result)
            return nil
        end
        return result
    end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
local TARGET_SETTINGS_VERSION = 1

local MIGRATIONS = {
    [1] = function()
        logger.info("[Syncthing] Settings migration #1: baseline established.")
    end,
}

local function _isFreshInstall()
    -- Check ALL plugin-owned settings keys so this function can never drift
    -- out of sync with the key list.  Previously a hardcoded subset of 7 keys
    -- was used; that worked in practice, but ANY plugin key being set is
    -- sufficient proof the plugin has been used before and a migration should
    -- run.
    --
    -- syncthing_settings_version is excluded: _migrateSettings() already
    -- checked it (current == 0) before calling us, so it cannot be set here.
    for _, k in ipairs(U.ALL_SETTINGS_KEYS) do
        if k ~= "syncthing_settings_version"
            and G_reader_settings:readSetting(k) ~= nil then
            return false
        end
    end
    return true
end

local function _migrateSettings()
    local current = G_reader_settings:readSetting("syncthing_settings_version") or 0
    if current >= TARGET_SETTINGS_VERSION then return end
    if current == 0 and _isFreshInstall() then
        G_reader_settings:saveSetting("syncthing_settings_version", TARGET_SETTINGS_VERSION)
        return
    end
    for v = current + 1, TARGET_SETTINGS_VERSION do
        local fn = MIGRATIONS[v]
        if fn then
            local ok, err = pcall(fn)
            if not ok then
                logger.err("[Syncthing] Migration #" .. v .. " failed: " .. tostring(err))
                return
            end
        end
        G_reader_settings:saveSetting("syncthing_settings_version", v)
    end
end

---------------------------------------------------------------------------
function Syncthing:init()
    _migrateSettings()

    self.syncthing_port        = G_reader_settings:readSetting("syncthing_port", "8384")
    self.gui_password          = G_reader_settings:readSetting("syncthing_gui_password")
    self.gui_user              = G_reader_settings:readSetting("syncthing_gui_user", "syncthing")
    self.auto_start_charging   = G_reader_settings:readSetting("syncthing_auto_start_charging", false)
    -- Autostart mode: "off" | "wifi" | "always".
    -- Migrate the former boolean syncthing_auto_start_always (true -> "always").
    local autostart_mode = G_reader_settings:readSetting("syncthing_autostart_mode")
    if autostart_mode ~= "off" and autostart_mode ~= "wifi" and autostart_mode ~= "always" then
        autostart_mode = G_reader_settings:isTrue("syncthing_auto_start_always") and "always" or "off"
        G_reader_settings:saveSetting("syncthing_autostart_mode", autostart_mode)
    end
    self.autostart_mode        = autostart_mode
	self.notifications_enabled = G_reader_settings:readSetting("syncthing_notifications_enabled", true)
	self.resource_profile 	   = G_reader_settings:readSetting("syncthing_resource_profile", "low")
    self.network_access   	   = G_reader_settings:readSetting("syncthing_network_access", "lan")
	self.periodic_sync_enabled = G_reader_settings:isTrue("syncthing_periodic_sync_enabled")
    self.periodic_sync_interval_min = G_reader_settings:readSetting("syncthing_periodic_sync_interval_min", 30)
	self._was_running_before_suspend = false

    self._starting = false
    self._stopping = false
    self._last_sync_progress = nil
    self._health_sync_snapshot = nil
    self._last_api_error = nil
    self._health_check_active = true
	self._quick_sync_active = false
	self._sync_flow_counter = 0
	self._active_flow_id = nil
    self._drain_timer = nil

    -- Persistent cache (survives KOReader restarts), falls back to in-memory
    if CacheSQLite then
        local ok, result = pcall(function()
            return CacheSQLite:new{
                size      = 512 * 1024,
                db_path   = DataStorage:getSettingsDir() .. "/syncthing_cache.db",
                codec     = "zstd",
                auto_close = true,
            }
        end)
        if ok and result and type(result.remove) == "function" then
            self.cache = result
            logger.info("[Syncthing] CacheSQLite initialized successfully")
        else
            logger.info("[Syncthing] CacheSQLite not available, using in-memory cache")
            self.cache = FallbackCache:new{}
        end
    else
        logger.info("[Syncthing] CacheSQLite not available, using in-memory cache")
        self.cache = FallbackCache:new{}
    end

    -- connection cache (for countConnectedDevices in st_health)
    self._connections_cache      = nil
    self._connections_total      = nil
    self._connections_cache_time = 0

    -- Android: act as a remote client of the Syncthing app, which owns the
    -- daemon.  Runs after the cache exists (patched methods use self:_cacheSet)
    -- and before the menu / public API are wired.  Skipped entirely on
    -- Kindle/Kobo, so their path is unchanged.  On success Android.init patches
    -- self (apiCall→TLS, start/stop→no-op, findConflicts→lfs, …) and sets
    -- self._android_mode; on no saved key / unreachable app it leaves
    -- self._android_unavailable so the menu offers a connect row.
    if Device:isAndroid() then
        local ok, Android = pcall(require, "st_android")
        if not ok then
            logger.warn("[Syncthing] st_android unavailable: " .. tostring(Android))
            self._android_unavailable = true
        else
            self._android = Android
            if not Android.init(self) then
                self._android_unavailable = true
            end
        end
    end

    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
	
	if self:binaryExists() and not self.gui_password then
		-- Use U.getConfigDir() so this stays aligned with the configured path.
		local config_xml_path = U.getConfigDir() .. "/config.xml"
		if util.pathExists(config_xml_path) then
			local f = io.open(config_xml_path, "r")
			if f then
				local content = f:read("*a")
				f:close()
				if content and content:find("<user>") and content:find("<password>") then
					G_reader_settings:saveSetting("syncthing_password_configured", true)
				end
			end
		end
	end

    self._health_check_fn = function()
        if not self._health_check_active then return end
        -- Protect the work: a background error must neither crash KOReader nor
        -- silently stop the timer.  Log the traceback so a failure stays
        -- diagnosable (no 60 s notification storm); the reschedule below always
        -- runs regardless of the outcome.
        local ok, err = xpcall(function()
        if self:_autoStartEnabled() and not self:isRunning() then
            self:runAutoStart("health_check")
        elseif self:_autoStartEnabled() and self:isRunning() and not NetworkMgr:isOnline() then
            self:runAutoStop("health_check")
        elseif self:isRunning() then
            -- Refresh sync progress for the smart header.
            local folder_health = self:getFolderHealth()
            if folder_health and folder_health.need_bytes and folder_health.need_bytes > 0 then
                -- There is ongoing sync activity.
                local stats = self:getDeviceStats() or {}
                local sent_now, recv_now = 0, 0
                for _, ds in pairs(stats) do
                    sent_now = sent_now + (tonumber(ds.totalBytesSent) or 0)
                    recv_now = recv_now + (tonumber(ds.totalBytesReceived) or 0)
                end

                -- Take a snapshot the first time we see activity,
                -- or if the current need_bytes is larger than before
                -- (a new sync wave has started).
                local snap = self._health_sync_snapshot
                if not snap or folder_health.need_bytes > snap.need_bytes then
                    snap = {
                        sent = sent_now,
                        recv = recv_now,
                        need_bytes = folder_health.need_bytes,
                    }
                    self._health_sync_snapshot = snap
                end

                local transferred = (sent_now - snap.sent) + (recv_now - snap.recv)
                local total_work = transferred + folder_health.need_bytes
                local pct = total_work > 0 and math.floor((transferred / total_work) * 100) or 0

                self._last_sync_progress = {
                    pct = pct,
                    need_bytes = folder_health.need_bytes,
                }
            else
                -- No active sync; clear the progress and the snapshot.
                self._last_sync_progress = nil
                self._health_sync_snapshot = nil
            end
        end
        end, debug.traceback)
        if not ok then
            logger.warn("[Syncthing] health check failed: " .. tostring(err))
        end
        UIManager:scheduleIn(60, self._health_check_fn)
    end

    -- Build public API for companion plugins.
    -- The initialisation order matters:
    --   cache → buildPublicAPI → schedule timers → startup restore.
    --
    -- buildPublicAPI() captures `self` by reference; every closure it creates
    -- reads from `self` at call-time, not at build-time.  The health-check
    -- timer scheduled below calls runAutoStart() which may use
    -- self._notifiers, so the timer must not fire before buildPublicAPI()
    -- has stored the notifier table.  Scheduling the timer before
    -- buildPublicAPI() would be safe in practice (8 s >> init() duration),
    -- but the explicit ordering guards against a future refactor shortening
    -- the delay or moving buildPublicAPI() later.
    --
    -- There is no circular dependency between the _health_check_fn definition
    -- and buildPublicAPI(): the latter does not read any field of `self` at
    -- build time, only creating closures.  The ordering constraint exists
    -- solely to prevent a timer from firing before _notifiers is ready.
    self._notifiers = public_api.buildPublicAPI(self)

    -- Schedule health check only after _notifiers is set.
    UIManager:scheduleIn(8, self._health_check_fn)

    if self.periodic_sync_enabled then
        self:_startPeriodicSyncTimer()
    end

    -- Reconcile the plugin's belief about the daemon with reality before the
    -- "was running" restore decision below reads it (catches a process that
    -- died outside the plugin's control between sessions). Local-daemon only.
    if not self._android_mode then self:reconcile("init") end

    if not self._android_mode and G_reader_settings:isTrue("syncthing_was_running") then
        G_reader_settings:delSetting("syncthing_was_running")
        if NetworkMgr:isOnline() then
            self:runAutoStart("startup_restore")
        else
            -- WiFi is not available at boot time.  We cannot start Syncthing
            -- now, but we must not lose the restore intent either: the setting
            -- was just deleted, so we cannot re-read it later.  Keep the flag
            -- alive so runNetworkConnected() can act as soon as the network
            -- comes up – the same deferred-restore pattern that handles the
            -- suspend-while-offline case.  The flag is cleared by
            -- runNetworkConnected() when it acts, and overwritten by
            -- runSuspendStop() on the next suspend.  Factory reset already
            -- resets this flag, so a reset before WiFi arrives correctly
            -- cancels the deferred restore.
            self._was_running_before_suspend = true
        end
    elseif not self._android_mode and self:_autoStartEnabled() then
        -- Cold-start Autostart.  The branch above only RESTORES a daemon that
        -- was already running before the last session ended (was_running=true);
        -- it never cold-starts one.  When Autostart is enabled but Syncthing
        -- was NOT running at shutdown (you turned Autostart on without starting
        -- it, or it was auto-stopped), the ONLY remaining cold-start trigger is
        -- the health-check timer (scheduled 8 s above).  But onCloseWidget
        -- cancels that timer on every FileManager<->Reader transition, so on
        -- many real startups it never fires and nothing ever starts — Autostart
        -- silently does nothing.  Start it directly here instead.  runAutoStart
        -- re-checks isRunning (no double start across the FM/Reader instances),
        -- the session Autostart pause via isAutostartPaused (so a manual stop
        -- is still respected for the rest of the session — and because that
        -- flag lives in st_utils, it is shared across the FM/Reader instances,
        -- so navigation does not silently un-pause), the charging gate and the
        -- network, so calling it unconditionally on every init() is safe.
        self:runAutoStart("init_autostart")
    end
end

---------------------------------------------------------------------------
-- Periodic Sync methods (revised for seamless Wi‑Fi with st_sync._startQuickSync)
---------------------------------------------------------------------------
function Syncthing:_startPeriodicSyncTimer()
    if not self.periodic_sync_enabled then return end
    self:_scheduleNextPeriodicSync()
end

function Syncthing:_scheduleNextPeriodicSync()
    if not self.periodic_sync_enabled then return end
    local interval_seconds = self.periodic_sync_interval_min * 60

    if self._periodic_sync_timer then
        UIManager:unschedule(self._periodic_sync_timer)
        self._periodic_sync_timer = nil
    end

    self._next_periodic_sync_at = os.time() + interval_seconds
    self._periodic_sync_timer = function()
        self._periodic_sync_timer = nil
        if self.periodic_sync_enabled then
            -- Same class of protection as the health timer: a synchronous error
            -- in the tick must not crash KOReader.  The async sync flow
            -- (st_orchestrator) is already pcall-guarded and owns re-arming via
            -- _scheduleNextPeriodicSync, so we log and stop rather than risk a
            -- double re-arm here.
            local ok, err = xpcall(function() self:_onPeriodicSyncTick() end, debug.traceback)
            if not ok then
                logger.warn("[Syncthing] periodic sync tick failed: " .. tostring(err))
            end
        end
    end

    UIManager:scheduleIn(interval_seconds, self._periodic_sync_timer)
end

function Syncthing:_onPeriodicSyncTick()
    return self:runPeriodicSync()
end

function Syncthing:_stopPeriodicSyncTimer()
    if self._periodic_sync_timer then
        UIManager:unschedule(self._periodic_sync_timer)
        self._periodic_sync_timer = nil
    end
end

function Syncthing:_periodicSyncWifiDone()
    local wifi_disable_action = G_reader_settings:readSetting("wifi_disable_action")
    if wifi_disable_action == "turn_off" then
        NetworkMgr:disableWifi()
    end
end

---------------------------------------------------------------------------
function Syncthing:onCloseWidget()
    self._health_check_active = false
    if self._health_check_fn then
        UIManager:unschedule(self._health_check_fn)
        self._health_check_fn = nil
    end
    -- Cancel any pending drain timer so the notification loop does
    -- not outlive the plugin instance.
    if self._drain_timer then
        UIManager:unschedule(self._drain_timer)
        self._drain_timer = nil
    end
    self._notification_queue  = nil
    self._notification_active = false
    self:_stopPeriodicSyncTimer()
    -- IMPORTANT: the daemon is deliberately NOT stopped here.  onCloseWidget
    -- fires on every FileManager<->Reader transition (KOReader closes the
    -- outgoing UI with Event "CloseWidget"), so stopping the daemon here would
    -- kill it — and any in-progress sync — on routine navigation.  The daemon
    -- is a separate process and must survive navigation; it is stopped only on
    -- genuine teardown, handled by onSuspend / onExit / onPowerOff / onReboot.
end

-- Genuine teardown events.  Unlike onCloseWidget (which fires on every
-- FileManager<->Reader navigation), KOReader broadcasts these only when the
-- device/app is really going away, so they are the correct place to stop the
-- managed daemon cleanly:
--   Exit     - quit KOReader (back to the launcher / native OS)
--   PowerOff - device shutdown
--   Reboot   - device reboot
--   Close    - USB mass storage (KOReader exits to hand the storage to a PC)
--              and Alt+F4 / desktop window-close.  This one matters for data
--              safety: the daemon writes to the very storage that USB mass
--              storage hands to the PC, so it MUST stop before the hand-off or
--              the two writers can corrupt the filesystem.
-- Suspend/Resume are handled separately (orchestrator mixin).  Android is
-- skipped here too — the Syncthing app owns the daemon there.  The handler
-- returns nil so the event keeps propagating to the UI's own onClose/onExit.
function Syncthing:onExit()
    if not self._android_mode then
        self:runCloseStop()
    end
end
Syncthing.onPowerOff = Syncthing.onExit
Syncthing.onReboot   = Syncthing.onExit
Syncthing.onClose    = Syncthing.onExit

function Syncthing:_chargingConditionMet()
    return not self.auto_start_charging or (Device.powerd and Device.powerd:isCharging()) or false
end

function Syncthing:_autoStartEnabled()
    return self.autostart_mode == "wifi" or self.autostart_mode == "always"
end

-- Only the "always" mode may turn Wi-Fi on by itself; "wifi" mode follows
-- Wi-Fi but never forces the radio on.
function Syncthing:_autoStartForcesWifi()
    return self.autostart_mode == "always"
end

function Syncthing:_setAutostartMode(mode)
    if mode ~= "off" and mode ~= "wifi" and mode ~= "always" then return end
    self.autostart_mode = mode
    G_reader_settings:saveSetting("syncthing_autostart_mode", mode)
    if self:_autoStartEnabled() then
        -- "enable --now": clear any session pause and start now if possible.
        -- runAutoStart still honours charging and the network, and in "wifi"
        -- mode it will NOT force Wi-Fi on.
        U.setAutostartPaused(false)
        self:runAutoStart("autostart_mode_changed")
    end
end

function Syncthing:_autoStop(reason)
    return self:runAutoStop(reason)
end

function Syncthing:showNotification(text, timeout)
    if not self.notifications_enabled then return end
    -- Queue notifications so they never overlap each other.
    -- On e-ink devices, showing two notifications simultaneously causes
    -- them to render on top of each other and both become unreadable.
    if not self._notification_queue then
        self._notification_queue = {}
        self._notification_active = false
    end
    table.insert(self._notification_queue, { text = text, timeout = timeout or 3 })
    if not self._notification_active then
        self:_drainNotificationQueue()
    end
end

function Syncthing:_drainNotificationQueue()
    if not self._notification_queue or #self._notification_queue == 0 then
        self._notification_active = false
        return
    end
    self._notification_active = true
    local item = table.remove(self._notification_queue, 1)
    pcall(function()
        local Notification = require("ui/widget/notification")
        UIManager:show(Notification:new{
            text    = item.text,
            timeout = item.timeout,
        })
    end)
    -- Store the timer in a named field so onCloseWidget() can
    -- unschedule it.
    self._drain_timer = function()
        self._drain_timer = nil
        self:_drainNotificationQueue()
    end
    UIManager:scheduleIn(item.timeout + 0.3, self._drain_timer)
end

---------------------------------------------------------------------------
-- Dispatcher integration
---------------------------------------------------------------------------
function Syncthing:onDispatcherRegisterActions()
    -- Daemon toggle is meaningless in Android remote mode (the app owns the
    -- daemon); the rescan and pause/resume gestures work fine via the API.
    if not self._android_mode then
        Dispatcher:registerAction("toggle_syncthing_server", {
            category = "none",
            event    = "ToggleSyncthingServer",
            title    = _("Toggle Syncthing"),
            general  = true,
        })
    end
    Dispatcher:registerAction("syncthing_quick_sync", {
        category = "none",
        event    = "SyncthingQuickSync",
        title    = _("Syncthing: Quick Sync"),
        general  = true,
    })
    Dispatcher:registerAction("syncthing_pause_all", {
        category = "none",
        event    = "SyncthingPauseAll",
        title    = _("Syncthing: Pause / resume all folders"),
        general  = true,
    })
end

-- Called when the user triggers Quick Sync via a gesture / hardware button.
function Syncthing:onSyncthingQuickSync()
    self:runQuickSync(nil)
end

-- Called when the user triggers pause-all via a gesture / hardware button.
-- Toggles: pauses all folders if none are paused, resumes all if any are paused.
function Syncthing:onSyncthingPauseAll()
    if not self:isRunning() then return end
    local h = self:getFolderHealth()
    local do_pause = not (h and h.paused > 0)
    self:setPauseAll(do_pause, nil)
end

---------------------------------------------------------------------------
-- Mixin all external modules into Syncthing class
---------------------------------------------------------------------------
for name, func in pairs(update_mod)   do Syncthing[name] = func end
for name, func in pairs(api_mod)      do Syncthing[name] = func end
Syncthing["resolveConflict"]          = conflict_mod.resolveConflict
Syncthing["autoMergeReadingProgress"] = conflict_mod.autoMergeReadingProgress
Syncthing["getConflictsDetailed"]     = conflict_mod.getConflictsDetailed
for name, func in pairs(process_mod)  do Syncthing[name] = func end
for name, func in pairs(sync_mod)     do Syncthing[name] = func end
for name, func in pairs(menu_mod)     do Syncthing[name] = func end
for name, func in pairs(health_mod)   do Syncthing[name] = func end
for name, func in pairs(pair_mod)     do Syncthing[name] = func end
for name, func in pairs(reset_mod)    do Syncthing[name] = func end
for name, func in pairs(orchestrator_mod) do Syncthing[name] = func end

-- Plugin self-update (distinct from the Syncthing binary update above).
-- Lazy-required: this path is reached only from the Maintenance menu, so it
-- should not cost plugin load time.
function Syncthing:checkForPluginUpdates()
    require("st_plugin_update").check()
end

-- Infrastructure
Syncthing.safe = safe
Syncthing._cacheGet = cacheGet
Syncthing._cacheSet = cacheSet
Syncthing._cacheInvalidate         = cacheInvalidate
Syncthing._invalidateConflictCache = invalidateConflictCache
Syncthing._invalidateProcess       = invalidateProcess
Syncthing._invalidateFolders       = invalidateFolders

pcall(require, "st_insert_menu")

return Syncthing
