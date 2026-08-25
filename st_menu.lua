-- st_menu.lua — Top-level menu and submenus
--
-- Menu architecture (current):
--
--   Syncthing  ← top-level entry; label is a smart status header
--   ├── Smart status line                  (read-only or tappable, context-aware)
--   ├── Start / Stop / Install             (primary action, context-aware)
--   ├── Quick Sync / Rescan all folders    (start, sync, stop — one button)
--   ├── Pause all folders / Resume all     (dynamic label with paused count)
--   │
--   ├── Status & conflicts ▸               (dashboard + folders + devices + pending + conflicts)
--   ├── Setup ▸                            (Web GUI, pair wizard, password, port, resource, network)
--   ├── Automation ▸                       (notifications, auto-start, periodic sync, charging gate)
--   ├── Maintenance ▸                      (logs, API errors, Copy API key, reset, restart, updates...)
--
-- Design principles enforced throughout this file:
--   • Every menu item has a help_text describing what it does.
--   • Every gated menu item (enabled_func) has a hold_callback explaining
--     WHY it is currently disabled, surfaced via st_disabled.
--   • Every user-facing message follows: "what happened — why — what to
--     do next" where applicable.
--   • Every callback that mutates state goes through self.safe() so a
--     stray exception doesn't kill the menu.

local DataStorage = require("datastorage")
local Device      = require("device")
local ConfirmBox  = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local TextViewer  = require("ui/widget/textviewer")
local UIManager   = require("ui/uimanager")
local QRMessage   = require("ui/widget/qrmessage")
local NetworkMgr  = require("ui/network/manager")
local sort 		  = require("sort")
local FS 		  = require("st_filesystem")
local ffiutil     = require("ffi/util")
local util        = require("util")
local _rapidjson_ok, _rapidjson = pcall(require, "rapidjson")
local JSON = _rapidjson_ok and _rapidjson or require("json")
local T           = ffiutil.template

local _    = require("syncthing_i18n").gettext
local N_   = require("syncthing_i18n").ngettext
local U    = require("st_utils")
local D    = require("st_disabled")
local Settings = require("st_settings")
local path = DataStorage:getFullDataDir()

local FOLDER_CACHE_TTL = U.FOLDER_CACHE_TTL

---------------------------------------------------------------------------
-- Shared double-confirmation before ENABLING reading-progress auto-merge.
-- Mirrors the factory-reset flow: an explicit warning with a concrete
-- data-loss example, then a final confirmation.  Used by BOTH the standard
-- Automation menu and the Android remote-mode menu, so the gate is identical
-- on every device.  Disabling is always safe, so callers wrap only the
-- OFF -> ON transition.
---------------------------------------------------------------------------
local function confirmEnableAutoMerge(on_confirm)
    UIManager:show(ConfirmBox:new{
        text = _(
            "Enable automatic reading-progress merge?\n\n"
            .. "After each Quick Sync, for every KOReader metadata conflict the copy "
            .. "that is further ahead in the book replaces the other one — the whole "
            .. "sidecar, including its annotations. It looks only at reading position, "
            .. "not at which copy is newer or has more annotations.\n\n"
            .. "So annotations can be lost when the copy that holds them is not the "
            .. "one read furthest.\n\n"
            .. "Example: on your e-reader you read and add highlights up to page 50. "
            .. "On your phone you had already read ahead to page 80. When the two "
            .. "sync, auto-merge keeps the page-80 copy (80 > 50) and replaces the "
            .. "e-reader copy whole, dropping the highlights you made.\n\n"
            .. "This runs automatically without asking each time, and cannot be undone."),
        ok_text     = _("I understand, continue →"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            -- Second confirmation: prevents an accidental e-ink misfire from
            -- arming a feature that can delete annotations.
            UIManager:show(ConfirmBox:new{
                text = _(
                    "⚠  Final confirmation  ⚠\n\n"
                    .. "Auto-merge can permanently delete annotations when one device "
                    .. "is further ahead in a book than another.\n\n"
                    .. "Enable it anyway?"),
                ok_text     = _("Enable auto-merge"),
                cancel_text = _("Cancel"),
                ok_callback = function()
                    if on_confirm then on_confirm() end
                end,
            })
        end,
    })
end

---------------------------------------------------------------------------
-- Folder state → human label
---------------------------------------------------------------------------
local STATE_LABELS = {
    scanning                 = _("Scanning…"),
    syncing                  = _("Syncing…"),
    error                    = _("Error"),
    unknown                  = _("Unknown"),
    ["sync-preparing"]       = _("Preparing…"),
    ["sync-waiting"]         = _("Waiting…"),
    ["cleaning"]             = _("Cleaning…"),
    ["clean-waiting"]        = _("Waiting…"),
    ["prepare-scan"]         = _("Preparing scan…"),
    ["waiting-for-scanning"] = _("Waiting…"),
}

local function humanizeFolderState(state, is_paused, has_errors, need_bytes)
    if is_paused  then return _("Paused") end
    if has_errors then return _("Error") end
    if state == "idle" then
        return (need_bytes and need_bytes > 0)
            and T(_("Syncing… (%1 remaining)"), util.getFriendlySize(need_bytes))
            or  _("Up to date")
    end
    local label = STATE_LABELS[state]
    return label or (state or _("Unknown"))
end

---------------------------------------------------------------------------
-- Status & conflicts submenu
---------------------------------------------------------------------------

-- Build the conflict-resolution rows: the headline "Resolve all …" bulk
-- action (auto-merge / keep-mine / use-theirs) followed by one row per
-- conflicting file (capped at 50).  Shared by the "Conflicts" door in the
-- status menu and by the standalone view opened from the status header.
-- Make conflict rows readable: turn the raw
-- "<name>.sync-conflict-YYYYMMDD-HHMMSS-<DEVICE>.<ext>" filename into the
-- book/file it actually belongs to, plus a compact timestamp for the right
-- column.  KOReader sidecar (.sdr) conflicts are about reading progress, so we
-- surface the book name instead of the opaque "metadata.epub.lua".
local function conflictDisplayName(conflict_path)
    local orig = require("st_conflict").deriveOriginalPath(conflict_path)
    local sdr  = orig:match("([^/]+)%.sdr/")
    if sdr then
        return (sdr:gsub("%.[%w]+$", ""))
    end
    return orig:match("/([^/]+)$") or orig
end

local function conflictWhen(conflict_path)
    local d, t = conflict_path:match("sync%-conflict%-(%d%d%d%d%d%d%d%d)%-(%d%d%d%d%d%d)")
    if d and t then
        return d:sub(5, 6) .. "-" .. d:sub(7, 8) .. " " .. t:sub(1, 2) .. ":" .. t:sub(3, 4)
    end
    return nil
end

local function buildConflictsItems(self, conflicts)
    local items = {}

    -- Bulk-resolve item with three strategies.  This is the headline
    -- conflict-handling action: one tap, three buttons, all conflicts
    -- handled.
    local bulk_help = _("Apply one strategy to every conflict at once.\n\n"
                     .. "Auto-merge is recommended for KOReader metadata files — it picks whichever copy has more reading progress.\n\n"
                     .. "Keep ALL mine: discard every conflict copy, keep this device's version for each.\n"
                     .. "Use ALL theirs: replace every local file with the conflict copy.")
    table.insert(items, {
        text           = T(N_("Resolve the conflict…", "Resolve all %1 conflicts…", #conflicts), #conflicts),
        help_text      = bulk_help,
        hold_callback  = D.helpHold(bulk_help),
        keep_menu_open = true,
        callback       = self.safe("Bulk resolve", function(tmi)
            UIManager:show(ConfirmBox:new{
                text = T(N_(
                    "Resolve the conflict.\n\nChoose a strategy:",
                    "Resolve all %1 conflicts.\n\nChoose a strategy:", #conflicts), #conflicts),
                ok_text     = _("Auto-merge progress"),
                cancel_text = _("Cancel"),
                other_buttons = {{
                    {
                        text     = _("Keep ALL mine"),
                        callback = function()
                            local removed, failed = 0, 0
                            for _, cp in ipairs(conflicts) do
                                if FS.remove(cp) then
                                    removed = removed + 1
                                else
                                    failed = failed + 1
                                end
                            end
                            self:_cacheInvalidate()
                            self:_invalidateConflictCache()
                            if self._notifiers then self._notifiers.notifyConflictsChanged(nil) end
                            if tmi then tmi:updateItems() end
                            local parts = {}
                            if removed > 0 then table.insert(parts, T(_("%1 removed"), removed)) end
                            if failed > 0 then table.insert(parts, T(_("%1 failed"), failed)) end
                            UIManager:show(InfoMessage:new{
                                icon    = failed > 0 and "notice-warning" or nil,
                                timeout = 3,
                                text    = table.concat(parts, "; "),
                            })
                        end,
                    },
                    {
                        text     = _("Use ALL theirs"),
                        callback = function()
                            local applied, skipped, failed = 0, 0, 0
                            for _, cp in ipairs(conflicts) do
                                local orig = require("st_conflict").deriveOriginalPath(cp)
                                if orig == cp then
                                    skipped = skipped + 1
                                elseif FS.rename(cp, orig) then
                                    applied = applied + 1
                                else
                                    failed = failed + 1
                                end
                            end
                            self:_cacheInvalidate()
                            self:_invalidateConflictCache()
                            -- Let companion plugins know about the mass change.
                            if self._notifiers then self._notifiers.notifyConflictsChanged(nil) end
                            if tmi then tmi:updateItems() end
                            local parts = {}
                            if applied > 0 then table.insert(parts, T(_("%1 applied"), applied)) end
                            if skipped > 0 then table.insert(parts, T(_("%1 skipped"), skipped)) end
                            if failed > 0 then table.insert(parts, T(_("%1 failed"), failed)) end
                            UIManager:show(InfoMessage:new{
                                icon    = failed > 0 and "notice-warning" or nil,
                                timeout = 3,
                                text    = table.concat(parts, "; "),
                            })
                        end,
                    },
                }},
                ok_callback = function()
                    local stats = self:autoMergeReadingProgress(conflicts)
                    if tmi then tmi:updateItems() end
                    if stats.deferred_open_book then
                        UIManager:show(InfoMessage:new{
                            timeout = 5,
                            text    = _("A book is open. Reading-progress conflicts were left untouched "
                                     .. "to avoid overwriting your live reading position and annotations "
                                     .. "when KOReader saves the book.\n\n"
                                     .. "Close the book and run auto-merge again, or tap individual "
                                     .. "conflicts to resolve them manually."),
                        })
                        return
                    end
                    -- Build the message string outside the table
                    local msg = T(_(
                        "Auto-merge complete.\n\n"
                        .. "Merged: %1 (kept newer reading progress)\n"
                        .. "  • from this device: %2\n"
                        .. "  • from other device: %3\n"
                        .. "Skipped (not metadata or unreadable): %4"),
                        -- Since we may have I/O errors on rename/remove, surface them if any.
                        stats.merged, stats.kept_local, stats.kept_remote, stats.skipped)
                    if stats.failed > 0 then
                        msg = msg .. "\n" .. T(_("Failed (I/O error): %1"), stats.failed)
                    end
                    msg = msg .. "\n\n" .. _("Tap any remaining conflicts to resolve them manually.")
                    UIManager:show(InfoMessage:new{
                        timeout = 5,
                        text    = msg,
                    })
                end,
            })
        end),
    })

    -- Per-file conflict list (capped at 50 to keep menus usable).
    -- For larger conflict sets, the user uses Resolve all instead.
    for i, conflict_path in ipairs(conflicts) do
        if i > 50 then
            table.insert(items, {
                text          = T(_("…and %1 more (use bulk resolve)"), #conflicts - 50),
                enabled_func  = function() return false end,
                hold_callback = D.helpHold(_("More conflicts exist than can fit in the menu.\n\n"
                                          .. "Use Resolve all conflicts at the top of this section to handle them in one go.")),
            })
            break
        end
        local name = conflictDisplayName(conflict_path)
        local when = conflictWhen(conflict_path)
        table.insert(items, {
            text           = "  " .. name,
            mandatory      = when,
            keep_menu_open = true,
            hold_callback  = D.helpHold(T(_(
                "Sync conflict for: %1\n\n"
                .. "Tap to choose: keep this device's version, use the other device's version, or open both for review."),
                name)),
            callback       = self.safe("Conflict resolve", function(tmi)
                self:resolveConflict(conflict_path, tmi)
            end),
        })
    end

    return items
end

-- Open the conflict-resolution view directly (used by the ⚠ status header,
-- which reads "tap to resolve").  No surrounding status menu — the user asked
-- to resolve, so we take them straight to the bulk action and per-file rows.
local function showConflicts(self)
    local conflicts = self:findConflicts()
    if #conflicts == 0 then return end
    local Menu = require("ui/widget/menu")
    UIManager:show(Menu:new{
        title      = _("Conflicts"),
        item_table = buildConflictsItems(self, conflicts),
    })
end

-- folderErrorExplanation — plain-language "what / why / what to do" for a
-- folder error, keyed by the category from U.classifyFolderError.  Shown by
-- the "Explain the error" button.  The raw Syncthing message is appended so
-- nothing is hidden from a developer.
local function folderErrorExplanation(category, raw_msg)
    local body
    if category == "ignored" then
        body = _("What happened: A folder was deleted on another device. Syncthing tried to delete it here too, but can't.\n\n"
              .. "Why: Inside it are files from your ignore list — for example KOReader's own working files. Because of .stignore, Syncthing won't touch them and refuses to delete the folder that contains them.\n\n"
              .. "What to do: If you no longer need this folder, delete it manually from a file manager. That removes the ignored files and syncing continues.\n"
              .. "\xe2\x9a\xa0 The files inside are deleted too — make sure they aren't the only copy of something important.\n\n"
              .. "Note: \"Remove folder\" only stops Syncthing from tracking it, without deleting files — so it does not fix this error.")
    elseif category == "nospace" then
        body = _("What happened: There isn't enough free space on the device.\n\n"
              .. "Why: Syncthing can't write the incoming files.\n\n"
              .. "What to do: Free up some space, then rescan the folder.")
    elseif category == "permission" then
        body = _("What happened: Syncthing can't write to this folder.\n\n"
              .. "Why: The folder is read-only, or its ownership/permissions don't allow writing.\n\n"
              .. "What to do: Check the folder's permissions.")
    elseif category == "missing" then
        body = _("What happened: The folder or its marker (.stfolder) is missing.\n\n"
              .. "Why: The path doesn't exist (an unmounted SD card?) or the marker was deleted.\n\n"
              .. "What to do: Check that the path exists; if the SD card is unmounted, mount it.")
    else
        body = _("Some items couldn't be synced. Try rescanning the folder. If it keeps happening, see the original message below.")
    end
    if raw_msg and raw_msg ~= "" then
        body = body .. "\n\n" .. T(_("Original message: %1"), raw_msg)
    end
    return body
end

-- openFolderDialog — the per-folder status/actions dialog.  Extracted from the
-- folder list so the status-header tap can open it directly for an erroring
-- folder (same destination idea as a conflict tap -> resolver).  Self-contained:
-- recomputes my_id / device names / stats rather than capturing closure state.
local function openFolderDialog(self, fid, folder_name, tmi)
    local function refresh_menu()
        if tmi then tmi:updateItems() end
    end
    local my_id = self:getDeviceId()
    local _devs = self:getDevices() or {}
    local device_name_map = {}
    for _, dev in pairs(_devs) do
        local did = dev["deviceID"]
        if did then
            device_name_map[did] = (dev["name"] and dev["name"] ~= "") and dev["name"] or did
        end
    end
    local function getDeviceName(did) return device_name_map[did] or did end
    local stat = (self:getFolderStats() or {})[fid] or {}

    local status = self:getFolderStatus(fid) or {}
    local has_error   = (tonumber(status["errors"]) or 0) > 0
    local err_fixable = false
    local first_error = nil
    if has_error then
        local ferr  = self:getFolderErrors(fid)
        local elist = (ferr and ferr["errors"]) or {}
        err_fixable = #elist > 0
        for _, e in ipairs(elist) do
            local emsg = e["error"] or ""
            if not first_error and emsg ~= "" then first_error = emsg end
            if not U.isTransientFolderError(emsg) then err_fixable = false end
        end
    end
    local err_category = has_error and U.classifyFolderError(first_error or "") or nil
    local need_items = tonumber(status["needTotalItems"]) or 0
    local need_data  = tonumber(status["needBytes"])      or 0
    local need_str   = need_items > 0
        and T(N_("%1 item (%2)", "%1 items (%2)", need_items), need_items, util.getFriendlySize(need_data))
        or  _("Nothing — fully synced")
    local live_fh2    = self:getFolderHealth()
    local live_fs2    = (live_fh2 and live_fh2.folder_states and live_fh2.folder_states[fid]) or {}
    local is_paused   = live_fs2.paused or false
    local live_folders = self:getFolders() or {}
    local live_folder  = nil
    for _, lf in pairs(live_folders) do
        if lf["id"] == fid then live_folder = lf; break end
    end
    local folder_path    = (live_folder and live_folder["path"]) or "?"
    local folder_devices = (live_folder and live_folder["devices"]) or {}

    local detail_state = humanizeFolderState(
        status["state"],
        is_paused,
        (status["errors"] or 0) > 0,
        status["needBytes"])

    local device_name_list = {}
    for __, d in pairs(folder_devices) do
        local did2 = d["deviceID"]
        if did2 and did2 ~= my_id then
            table.insert(device_name_list, "  \xe2\x80\xa2 " .. getDeviceName(did2))
        end
    end
    local shared_str = #device_name_list > 0
        and table.concat(device_name_list, "\n")
        or  _("  (only this device)")

    local summary = string.format(
        "%s: %s\n%s: %s\n%s: %s\n%s: %s",
        _("Path"),      folder_path,
        _("Status"),    detail_state,
        _("Remaining"), need_str,
        _("Errors"),    (not has_error) and _("none") or (first_error or tostring(status["errors"] or 0)))

    local other_buttons = {{
            {
                text     = _("Full details"),
                callback = function()
                    UIManager:show(TextViewer:new{
                        title = folder_name,
                        text  = string.format(
                            "%s: %s\n%s: %s\n%s: %s\n%s: %s\n%s: %s\n%s: %s\n\n%s:\n%s",
                            _("Path"),         folder_path,
                            _("Status"),       detail_state,
                            _("Remaining"),    need_str,
                            _("Errors"),       tonumber(status["errors"]) == 0 and _("none") or tostring(status["errors"] or 0),
                            _("Last scan"),    U.formatTime(stat["lastScan"]),
                            _("Last file"),    (stat["lastFile"] and stat["lastFile"]["filename"]) or _("none yet"),
                            _("Shared with"),  shared_str),
                        width  = math.floor(Device.screen:getWidth()  * 0.92),
                        height = math.floor(Device.screen:getHeight() * 0.80),
                    })
                end,
            },
            (has_error and err_category ~= "transient") and {
                text     = _("Explain the error"),
                callback = function()
                    UIManager:show(TextViewer:new{
                        title  = folder_name,
                        text   = folderErrorExplanation(err_category, first_error),
                        width  = math.floor(Device.screen:getWidth()  * 0.92),
                        height = math.floor(Device.screen:getHeight() * 0.80),
                    })
                end,
            } or nil,
            (not is_paused) and {
                text     = (has_error and err_fixable) and _("Fix error") or _("Rescan folder"),
                callback = function()
                    local result = self:scanFolder(fid)
                    UIManager:show(InfoMessage:new{
                        text    = U.isOk(result)
                            and T(_("Rescan started on \"%1\"."), folder_name)
                            or  T(_("Could not rescan \"%1\"."), folder_name),
                        timeout = 2,
                    })
                    refresh_menu()
                end,
            } or nil,
        }, {
            {
                text     = _("Remove folder"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Remove folder \"%1\"?\n\n"
                               .. "The files on disk are NOT deleted. "
                               .. "Syncthing will stop tracking this folder."),
                               folder_name),
                        ok_text     = _("Remove"),
                        cancel_text = _("Cancel"),
                        ok_callback = function()
                            local result = self:deleteFolder(fid)
                            local ok = U.isOk(result)
                            self:_cacheInvalidate()
                            self:_invalidateFolders()
                            if ok then
                                UIManager:show(InfoMessage:new{
                                    timeout = 3,
                                    text = T(_("Folder \"%1\" removed."), folder_name),
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    icon = "notice-warning",
                                    text = T(_("Could not remove folder.\n\n%1"), U.errOf(result)),
                                })
                            end
                            refresh_menu()
                        end,
                    })
                end,
            },
        }}
        for i = #other_buttons[1], 1, -1 do
            if not other_buttons[1][i] then
                table.remove(other_buttons[1], i)
            end
        end
    UIManager:show(ConfirmBox:new{
        title = folder_name,
        text  = summary,
        ok_text = is_paused and _("Resume folder") or _("Pause folder"),
        cancel_text = _("Close"),
        other_buttons = other_buttons,
        ok_callback = function()
            local new_paused = not is_paused
            local result = self:patchFolder(fid, { paused = new_paused })
            local ok = U.isOk(result)
            self:_cacheInvalidate()
            self:_invalidateFolders()
            if ok then
                UIManager:show(InfoMessage:new{
                    timeout = 2,
                    text = new_paused
                        and T(_("Folder \"%1\" paused."), folder_name)
                        or  T(_("Folder \"%1\" resumed."), folder_name),
                })
            else
                UIManager:show(InfoMessage:new{
                    icon = "notice-warning",
                    text = T(_("Could not change folder state.\n\n%1"), U.errOf(result)),
                })
            end
            refresh_menu()
        end,
    })
end

-- openErroringFolder — for the status-header tap: jump straight to the problem,
-- the way a conflict tap opens the resolver.  Opens the erroring folder's dialog
-- (one folder), or a flat picker of the erroring folders (several).  Returns
-- true if it showed something; false if no erroring folder was found, so the
-- caller can fall back to the full status view.
local function openErroringFolder(self, tmi)
    local h = self:getFolderHealth()
    local states = (h and h.folder_states) or {}
    local cfg = self:getFolders() or {}
    local name_of = {}
    for _, fdef in pairs(cfg) do
        local id = fdef["id"]
        if id then
            local nm = fdef["label"]
            if not nm or nm == "" then nm = id end
            name_of[id] = nm
        end
    end
    local erroring = {}
    for fid, fs in pairs(states) do
        if fs.errors then
            erroring[#erroring + 1] = { fid = fid, name = name_of[fid] or fid }
        end
    end
    if #erroring == 0 then return false end
    if #erroring == 1 then
        openFolderDialog(self, erroring[1].fid, erroring[1].name, tmi)
        return true
    end
    table.sort(erroring, function(a, b) return a.name < b.name end)
    local items = {}
    for _, ef in ipairs(erroring) do
        items[#items + 1] = {
            text     = ef.name,
            callback = function() openFolderDialog(self, ef.fid, ef.name, tmi) end,
        }
    end
    local Menu = require("ui/widget/menu")
    UIManager:show(Menu:new{
        title      = _("Folders with errors"),
        item_table = items,
    })
    return true
end

local function getStatusMenu(self, touchmenu_instance)
    local sub = {}

    -- Top of the submenu: the dashboard bullets from st_health.
    -- Each bullet is a read-only summary row.  Tap-and-hold shows a longer
    -- explanation of what that line means and what to do about it.
    local bullets = self:getStatusBullets()

    -- Map each severity to a one-paragraph explanation shown on tap-and-hold.
    -- This way even read-only rows have meaningful "what does this mean?"
    -- behavior instead of just sitting there inert.
    local severity_help = {
        ok    = _("Everything is working as expected. No action needed."),
        warn  = _("Something needs your attention but isn't broken.\n\n"
              .. "Tap-and-hold any specific row below for details, or open the relevant submenu."),
        error = _("Something is broken and may need fixing.\n\n"
              .. "Check the View logs item under Maintenance, or try Reset sync database if Syncthing is stuck."),
        info  = _("Informational status — neither good nor bad."),
    }

    for __, b in ipairs(bullets) do
        table.insert(sub, {
            text          = b.symbol .. "  " .. b.text,
            enabled_func  = function() return false end,
            hold_callback = D.helpHold(severity_help[b.severity] or severity_help.info),
        })
    end
    if #sub > 0 then sub[#sub].separator = true end

    -- AD-19: database-location row, shown whenever the DB lives somewhere other
    -- than the config dir (relocated off a hard_remove FUSE mount), or when no
    -- safe location was found.  We compare directories rather than matching the
    -- reason string, because after the first relocation the reason becomes
    -- "sticky" on later runs — matching only "redirected" would make this row
    -- vanish even though the DB is still relocated.  Passive (enabled_func=
    -- false) so it never pops up or competes with dialogs; the explanation
    -- lives on tap-and-hold in plain language (no "FUSE" jargon).
    do
        local ddir, dreason = U.getDataDir()
        local cfg_dir = U.getConfigDir()
        if ddir ~= cfg_dir then
            table.insert(sub, {
                text          = _("Database: on internal storage")
                                .. (dreason == "redirected_tight" and "  (low space)" or ""),
                enabled_func  = function() return false end,
                separator     = true,
                hold_callback = D.helpHold(_(
                    "This device uses a filesystem on which Syncthing's database can't run "
                    .. "reliably, so it was placed on the device's internal storage instead. "
                    .. "This is automatic and normal — your files are not affected.")),
            })
        elseif dreason == "fallback_warn" then
            table.insert(sub, {
                text          = _("Database storage issue — tap and hold"),
                enabled_func  = function() return false end,
                separator     = true,
                hold_callback = D.helpHold(_(
                    "This device's storage can make Syncthing's database unreliable, and no "
                    .. "alternative partition has enough free space. Syncing may be unstable. "
                    .. "Free up space on internal storage (e.g. /var/local) and restart Syncthing.")),
            })
        end
    end

    if not self:isRunning() then
        table.insert(sub, {
            text          = _("Start Syncthing to see folder details and conflicts."),
            enabled_func  = function() return false end,
            hold_callback = D.helpHold(_("Folder and device details are only available while Syncthing is running. Start it from the main menu first.")),
        })
        return sub
    end

    -- Per-folder rows: label + real state, drilling into details on tap.
    --
    -- State is derived from getFolderHealth (which caches db/status calls
    -- made on the previous health check) so no extra HTTP calls happen per
    -- menu open.  If the cache is cold, state falls back to "Checking…"
    -- for non-paused folders — acceptable because getFolderHealth will
    -- populate on the next health cycle.
    local cfg_folders = self:getFolders() or {}
    local cfg_devices = self:getDevices() or {}
    local fld_stats   = self:getFolderStats() or {}
    local my_id       = self:getDeviceId()

    -- Pull per-folder state snapshot from the folder_health cache.
    -- This is free — it was already computed by the last getFolderHealth call.
    local folder_health = self:getFolderHealth()
    local folder_states = (folder_health and folder_health.folder_states) or {}

    local device_name_map = {}
    for _, dev in pairs(cfg_devices) do
        local did = dev["deviceID"]
        if did then
            device_name_map[did] = (dev["name"] and dev["name"] ~= "") and dev["name"] or did
        end
    end
    local function getDeviceName(did) return device_name_map[did] or did end

    -- Pending devices & folders
    local pending_devices = self:getPendingDevices() or {}
    local pending_folders = self:getPendingFolders() or {}
    local has_pending = next(pending_devices) or next(pending_folders)
    if has_pending then
        table.insert(sub, {
            text          = _("── Pending ──"),
            enabled_func  = function() return false end,
            hold_callback = D.helpHold(_("Devices and folders that are waiting for your approval.\n\n"
                                      .. "Tap a device to accept or ignore it; tap a folder to accept it.")),
        })

        for device_id, device in pairs(pending_devices) do
            local default_name = device.name or device_id
            table.insert(sub, {
                text           = "  " .. default_name .. "  (" .. _("device") .. ")",
                keep_menu_open = true,
                hold_callback  = D.helpHold(T(_("Pending device \"%1\". Tap to accept or ignore."), default_name)),
                -- FIX: receive tmi from TouchMenu:onMenuSelect(callback(self))
                -- so the menu refreshes after accept/ignore without needing
                -- the outer touchmenu_instance (which is nil via sub_item_table_func).
                callback       = function(tmi)
                    UIManager:show(ConfirmBox:new{
                        text        = T(_("Accept device \"%1\"?\n\nID: %2"), default_name, device_id),
                        ok_text     = _("Accept"),
                        cancel_text = _("Ignore"),
                        ok_callback = function() self:acceptDevice(device_id, default_name, tmi) end,
                        cancel_callback = function()
                            self:ignorePendingDevice(device_id)
                            self:_invalidateProcess()
                            if tmi then tmi:updateItems() end
                        end,
                    })
                end,
            })
        end

        for folder_id, offerers in pairs(pending_folders) do
            for offerer_id, info in pairs(offerers.offeredBy or {}) do
                local label = (info and info.label) or folder_id
                table.insert(sub, {
                    text           = "  " .. label .. "  (" .. _("folder") .. ")",
                    keep_menu_open = true,
                    hold_callback  = D.helpHold(T(_("Pending folder \"%1\". Tap to accept."), label)),
                    -- FIX: same as pending devices above.
                    callback       = function(tmi)
                        UIManager:show(ConfirmBox:new{
                            text        = T(_("Accept folder \"%1\" from this device?"), label),
                            ok_text     = _("Accept"),
                            cancel_text = _("Ignore"),
                            ok_callback = function() self:acceptFolder(folder_id, label, offerer_id, tmi) end,
                            cancel_callback = function()
                                self:ignorePendingFolder(folder_id, offerer_id)
                                self:_invalidateFolders()
                                if tmi then tmi:updateItems() end
                            end,
                        })
                    end,
                })
            end
        end
    end

    -- Per-category item lists.  Each detail section (folders, devices,
    -- conflicts) is collected into its own table and then hung off a single
    -- "door" row in `sub`, so the top level stays compact: dashboard + doors.
    -- The doors are added only when their list is non-empty (hide-when-empty).
    local folders_items = {}

    -- Folder list, sorted alphabetically by label/id.
    local folder_list = {}
    for _, f in pairs(cfg_folders) do table.insert(folder_list, f) end
    local cmp = sort.natsort_cmp()
    table.sort(folder_list, function(a, b)
        return cmp(a["label"] or a["id"] or "", b["label"] or b["id"] or "")
    end)

    for __, folder in ipairs(folder_list) do
        local _folder = folder
        local fid     = _folder["id"] or ""
        local stat    = fld_stats[fid] or {}
        local folder_name = _folder["label"]
        if not folder_name or folder_name == "" then
            folder_name = fid
        end

        table.insert(folders_items, {
            text_func = function()
                -- Read live data so the label reflects the real state after
                -- Pause/Resume without needing to close and reopen the menu.
                local live_fh     = self:getFolderHealth()
                local live_states = (live_fh and live_fh.folder_states) or {}
                local fs          = live_states[fid] or {}
                local current_state
                if fs.paused then
                    current_state = _("Paused")
                elseif fs.errors then
                    current_state = _("Error")
                elseif fs.need_bytes and fs.need_bytes > 0 then
                    current_state = T(_("Syncing… (%1)"), util.getFriendlySize(fs.need_bytes))
                elseif fs.state == "idle" then
                    current_state = _("Up to date")
                else
                    current_state = _("Checking…")
                end
                return string.format("%s: %s", folder_name, current_state)
            end,
            keep_menu_open = true,
            hold_callback  = D.helpHold(T(_(
                "Folder \"%1\".\n\n"
                .. "Tap to see details: full path, remaining files, last scan time, last file synced, and which other devices share this folder."),
                folder_name)),
            -- FIX: receive tmi so refresh_menu() works after Rescan/Remove/Pause/Resume.
            -- TouchMenu:onMenuSelect calls callback(self) where self = the TouchMenu
            -- rendering this folder list; tmi:updateItems() refreshes it in place.
            callback = function(tmi)
                self.safe("Folder details", function()
                    openFolderDialog(self, fid, folder_name, tmi)
                end)()
            end,
        })
    end

    if #folders_items > 0 then
        table.insert(sub, {
            text                = _("Folders"),
            sub_item_table_func = function() return folders_items end,
            hold_callback       = D.helpHold(_("Each folder and its sync state. "
                               .. "Tap a folder to see its path, what's left to sync, and to pause, rescan, or remove it.")),
        })
    end

    -- Devices list
    local devices_items = {}
    local connections = self:getConnections() or {}
    local conn_dict   = (connections and connections["connections"]) or {}
    local dev_stats   = self:getDeviceStats() or {}

    local conn_list = {}
    for did, conn in pairs(conn_dict) do
        if U.isValidDeviceID(did) then
            table.insert(conn_list, { id = did, conn = conn })
        end
    end
    local cmp_dev = sort.natsort_cmp()
    table.sort(conn_list, function(a, b)
        return cmp_dev(getDeviceName(a.id), getDeviceName(b.id))
    end)

    for __, entry in ipairs(conn_list) do
        local did      = entry.id
        local conn     = entry.conn
        local ds       = dev_stats[did] or {}
        local dev_name = getDeviceName(did)

        table.insert(devices_items, {
            text_func = function()
                -- Read live connection data so the label updates after
                -- Pause/Resume without closing and reopening the menu.
                local connections = self:getConnections() or {}
                local conn_map    = (connections and connections["connections"]) or {}
                local conn        = conn_map[did] or {}
                local dev_stats   = self:getDeviceStats() or {}
                local ds          = dev_stats[did] or {}
                local status_str  = conn["connected"] and _("Connected")
                    or T(_("Last seen: %1"),
                        U.formatTime(ds["lastSeen"]) ~= _("N/A")
                            and U.formatTime(ds["lastSeen"])
                            or _("Never connected"))
                return string.format("%s: %s", dev_name, status_str)
            end,
            keep_menu_open = true,
            hold_callback  = D.helpHold(T(_(
                "Remote device \"%1\".\n\n"
                .. "Tap to see the device ID, connection address, and pause status."),
                dev_name)),
            -- FIX: receive tmi for refresh_menu() after Pause/Resume.
            callback = function(tmi)
                self.safe("Device info", function(tmi)
                    local function refresh_menu()
                        if tmi then tmi:updateItems() end
                    end
                    -- Read live connection so the dialog shows the real
                    -- current state, not the stale conn snapshot.
                    local live_conns2    = self:getConnections() or {}
                    local live_conn_map2 = (live_conns2 and live_conns2["connections"]) or {}
                    local live_conn2     = live_conn_map2[did] or conn
                    local live_ds2       = (self:getDeviceStats() or {})[did] or ds
                    local is_paused      = live_conn2["paused"] == true
                    local summary = string.format(
                        "%s: %s\n%s: %s\n%s: %s\n%s: %s",
                        _("Device ID"),  did,
                        _("Address"),    live_conn2["connected"] and (live_conn2["address"] or _("unknown")) or _("offline"),
                        _("Connected"),  live_conn2["connected"] and _("yes") or _("no"),
                        _("Paused"),     is_paused and _("yes") or _("no"))
                    UIManager:show(ConfirmBox:new{
                        title = dev_name,
                        text  = summary,
                        ok_text = is_paused and _("Resume device") or _("Pause device"),
                        cancel_text = _("Close"),
                        other_buttons = {{
                            {
                                text     = _("Full details"),
                                callback = function()
                                    UIManager:show(TextViewer:new{
                                        title = dev_name,
                                        text  = string.format(
                                            "%s: %s\n%s: %s\n%s: %s\n%s: %s\n%s: %s",
                                            _("Device ID"),  did,
                                            _("Address"),    live_conn2["connected"] and (live_conn2["address"] or _("unknown")) or _("offline"),
                                            _("Connected"),  live_conn2["connected"] and _("yes") or _("no"),
                                            _("Paused"),     is_paused and _("yes") or _("no"),
                                            _("Last seen"),  U.formatTime(live_ds2["lastSeen"])),
                                        width  = math.floor(Device.screen:getWidth()  * 0.92),
                                        height = math.floor(Device.screen:getHeight() * 0.80),
                                    })
                                end,
                            },
                        }},
                        ok_callback = function()
                            local new_paused = not is_paused
                            local result = self:patchDevice(did, { paused = new_paused })
                            local ok = U.isOk(result)
                            self:_invalidateProcess()
                            self:_cacheInvalidate()
                            if ok then
                                UIManager:show(InfoMessage:new{
                                    timeout = 2,
                                    text = new_paused
                                        and T(_("Device \"%1\" paused."), dev_name)
                                        or  T(_("Device \"%1\" resumed."), dev_name),
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    icon = "notice-warning",
                                    text = T(_("Could not change device state.\n\n%1"), U.errOf(result)),
                                })
                            end
                            refresh_menu()
                        end,
                    })
                end)(tmi)
            end,
        })
    end

    if #devices_items > 0 then
        table.insert(sub, {
            text                = _("Devices"),
            sub_item_table_func = function() return devices_items end,
            hold_callback       = D.helpHold(_("Each remote device and its connection status. "
                               .. "Tap a device to see its ID and address, and to pause or resume syncing.")),
        })
    end

    -- Conflicts section
    -- Call findConflicts() live inside sub_item_table_func so resolved
    -- conflicts disappear immediately when updateItems() runs.
    local has_conflicts = #(self:findConflicts()) > 0
    if has_conflicts then
        table.insert(sub, {
            text                = _("Conflicts"),
            sub_item_table_func = function()
                return buildConflictsItems(self, self:findConflicts())
            end,
            hold_callback       = D.helpHold(_("A conflict happens when two devices change the same file before they could sync.\n\n"
                                           .. "Syncthing keeps both copies side by side. The original file stays put, and the alternate version gets a name like \"…sync-conflict-DATE-TIME-DEVICE.ext\".\n\n"
                                           .. "Use Resolve all to apply one strategy to every conflict at once, or tap an individual conflict to choose for each one.")),
        })
    end

    return sub
end

---------------------------------------------------------------------------
-- Pending devices & folders submenu (fallback when Syncthing is stopped)
---------------------------------------------------------------------------
local function getPendingMenu(self, touchmenu_instance)
    return {{
        text          = _("Syncthing is not running."),
        enabled_func  = function() return false end,
        hold_callback = D.helpHold(_("Pending devices and folders can only be listed while Syncthing is running.\n\n"
                                  .. "Start Syncthing from the main menu first.")),
    }}
end

---------------------------------------------------------------------------
-- Setup submenu (Web GUI, pair, password, port)
---------------------------------------------------------------------------
local function getSetupMenu(self)
    local sub = {}

    -- Web GUI access — show the URL to open in a browser
    local web_gui_help = _("Show the address to open the Syncthing Web GUI from any browser on the same Wi-Fi.\n\n"
                        .. "The Web GUI is where you add folders, configure ignore patterns, and tweak advanced options.")
    table.insert(sub, {
        text           = _("Web GUI access"),
        help_text      = web_gui_help,
        keep_menu_open = true,
        enabled_func   = D.enabled(self, "isRunning"),
        hold_callback  = D.gatedHold(self, "isRunning", web_gui_help),
        callback       = self.safe("Web GUI", function()
            local ip          = U.getDeviceIP()
            local host        = ip:find(":", 1, true) and ("[" .. ip .. "]") or ip
            local url         = string.format("http://%s:%s", host, self.syncthing_port)
            local is_loopback = (ip == "127.0.0.1")
            local note = is_loopback
                and _("\n\n ⚠ Wi-Fi appears disconnected. The Web GUI is only reachable from this device.")
                or  ""
            UIManager:show(ConfirmBox:new{
                text = T(_(
                    "Open this address in a browser on any device on the same Wi-Fi:\n\n"
                    .. "%1%2\n\n"
                    .. "Or scan the QR code with another device."),
                    url, note),
                ok_text     = _("Show QR code"),
                cancel_text = _("Close"),
                ok_callback = function()
                                UIManager:show(QRMessage:new{
                                    text   = url,
                                    width  = math.floor(Device.screen:getWidth() * 0.8),
                                    height = math.floor(Device.screen:getHeight() * 0.8),
                                })
                            end,
            })
        end),
        separator = true,
    })

    -- Pair wizard — guided flow that replaces the bare Device ID submenu
    local pair_help = _("Step-by-step wizard: shows your device ID and QR code, then watches for incoming pairing requests.\n\n"
                     .. "When the other device sends a pairing request, this wizard offers to accept it automatically — you don't have to switch back and forth between devices.")
    table.insert(sub, {
        text           = _("Pair with another device"),
        help_text      = pair_help,
        keep_menu_open = true,
        enabled_func   = D.enabled(self, "isRunning"),
        hold_callback  = D.gatedHold(self, "isRunning", pair_help),
        callback       = self.safe("Pair wizard", function()
            self:startPairWizard()
        end),
    })

    -- Password — single dialog, password-first
    local pwd_help = _("Set or remove the password for the Syncthing Web GUI.\n\n"
                    .. "Without a password, anyone on your Wi-Fi can change Syncthing's settings. Strongly recommended on shared or public networks.\n\n"
                    .. "Syncthing must be stopped to change the password.")
    table.insert(sub, {
        text           = _("Web GUI password"),
        help_text      = pwd_help,
        keep_menu_open = true,
        hold_callback  = D.helpHold(pwd_help),
        callback       = function(tmi) Settings.showPasswordDialog(self, tmi) end,
    })

    -- Port — change once and forget
    local port_help = _("The TCP port Syncthing listens on for the Web GUI.\n\n"
                     .. "Change this only if another app already uses port 8384, or if your platform requires a non-default port.\n\n"
                     .. "Syncthing must be stopped to change the port.")
    table.insert(sub, {
        text_func = function()
            return T(_("Web GUI port: %1"), self.syncthing_port)
        end,
        help_text      = port_help,
        keep_menu_open = true,
        hold_callback  = D.helpHold(port_help),
        -- Port change requires a restart.  If Syncthing is running, offer
        -- to stop it inline so the user never has to hunt for Stop first.
        callback       = self.safe("Set port", function(tmi)
            local function openPortDialog()
                local dlg
                dlg = InputDialog:new{
                    title      = _("Web GUI port"),
                    input      = tostring(self.syncthing_port),
                    input_type = "number",
                    input_hint = "8384",
                    buttons    = {{
                        {
                            text     = _("Cancel"),
                            id       = "close",
                            callback = function() UIManager:close(dlg) end,
                        },
                        {
                            text             = _("Save"),
                            is_enter_default = true,
                            callback         = function()
                                local val = tonumber(dlg:getInputText())
                                if not val or val < 1024 or val > 65535 then
                                    UIManager:show(InfoMessage:new{
                                        icon = "notice-warning",
                                        text = _("Port must be a number between 1024 and 65535."),
                                    })
                                    return
                                end
                                self.syncthing_port = tostring(val)
                                G_reader_settings:saveSetting("syncthing_port", self.syncthing_port)
                                UIManager:close(dlg)
                                UIManager:show(InfoMessage:new{
                                    timeout = 3,
                                    text    = T(_("Port set to %1.\n\nStart Syncthing to apply."), val),
                                })
                                if tmi then tmi:updateItems() end
                            end,
                        },
                    }},
                }
                UIManager:show(dlg)
                dlg:onShowKeyboard()
            end

            if self:isRunning() then
                UIManager:show(ConfirmBox:new{
                    text        = _("Changing the port requires stopping Syncthing.\n\nStop Syncthing now and continue?"),
                    ok_text     = _("Stop & continue"),
                    cancel_text = _("Cancel"),
                    ok_callback = function()
                        self:stop(function() openPortDialog() end)
                    end,
                })
                return
            end
            openPortDialog()
        end),
        separator = true,
    })

    local resource_help = _("Choose how many system resources Syncthing may use.\n\n"
        .. "• Low: Strongly limits memory and CPU usage. Suitable for most e-ink devices. "
        .. "Syncthing will be restricted to 64 MiB of RAM and minimal background activity.\n\n"
        .. "• Normal: Relaxes limits, allowing more concurrency and higher memory usage (128 MiB). "
        .. "Best for devices with 512 MB+ RAM.\n\n"
        .. "The memory and CPU limits are applied at the process level and take full effect after a restart. "
        .. "Additional fine-grained folder and device settings can be applied separately with 'Apply resource tweaks'.")
    table.insert(sub, {
        text_func = function()
            return self.resource_profile == "normal"
                and _("Resource profile: Normal")
                or  _("Resource profile: Low")
        end,
        help_text      = resource_help,
        keep_menu_open = true,
        hold_callback  = D.helpHold(resource_help),
        callback = function(tmi)
            self.resource_profile = (self.resource_profile == "normal") and "low" or "normal"
            G_reader_settings:saveSetting("syncthing_resource_profile", self.resource_profile)
            if tmi then tmi:updateItems() end

            if self:isRunning() then
                -- API-based tweaks take effect immediately
                self:applyPerformanceSettings()
                self:applyNetworkSettings()
                UIManager:show(ConfirmBox:new{
                    text = _(
                        "Resource profile changed.\n\n" ..
                        "• Folder/device limits and network settings have been applied immediately.\n" ..
                        "• Memory and CPU limits (GOMEMLIMIT, GOGC) require a Syncthing restart to take effect.\n\n" ..
                        "Restart Syncthing now?"
                    ),
                    ok_text     = _("Restart Syncthing"),
                    cancel_text = _("Later"),
                    ok_callback = function()
                        self:stop(function()
                            self._silentStart = true
                            self:start()
                        end)
                    end,
                })
            else
                UIManager:show(InfoMessage:new{
                    timeout = 3,
                    text    = _("Resource profile saved. All limits (including memory/CPU) will apply on next start."),
                })
            end
        end,
    })
    -- Fine resource tuning — immediately after Resource profile because it
    -- applies that profile's limits to a running Syncthing instance.  Users
    -- naturally look here after switching profiles.
    local tweaks_help = _("Apply or reset profile‑specific performance settings.\n\n"
						.. "• Apply: push folder/device limits (copiers, hashers, pullerMaxPendingKiB, "
						.. "scanProgressIntervalS, numConnections) to a running Syncthing instance. "
						.. "For folders on FAT/FUSE filesystems it also sets "
						.. "modTimeWindowS=2, ignorePerms=true, and disables ownership & xattr sync.\n"
						.. "• Reset: revert all these limits to Syncthing defaults. The FAT/FUSE safety settings are cleared too, but are re-applied automatically the next time Syncthing starts.\n\n"
						.. "FAT/FUSE safety defaults (modTimeWindowS, ignorePerms, ownership) "
						.. "are already applied automatically when Syncthing starts — you only "
						.. "need this menu to change profile‑specific limits or to reset everything.\n\n"
						.. "Syncthing must be running.")
    table.insert(sub, {
        text           = _("Fine resource tuning"),
        help_text      = tweaks_help,
        keep_menu_open = true,
        enabled_func   = D.enabled(self, "isRunning"),
        hold_callback  = D.gatedHold(self, "isRunning", tweaks_help),
        -- ButtonDialog gives each action its own dedicated button, which is
        -- more reliable than cancel_callback (whose behaviour is ambiguous in
        -- some KOReader versions) and clearer for the user.
        callback       = function()
            local ButtonDialog = require("ui/widget/buttondialog")
            local dlg
            dlg = ButtonDialog:new{
                title = _("Fine resource tuning"),
                info  = _("Apply: push folder/device limits per the current "
                       .. "Resource profile to Syncthing right now.\n\n"
                       .. "Reset: revert all limits to Syncthing defaults.\n\n"
                       .. "Both options are safe and can be re-applied at any time."),
                buttons = {
                    {
                        {
                            text     = _("Apply"),
                            callback = function()
                                UIManager:close(dlg)
                                self:applyPerformanceSettings()
                            end,
                        },
                        {
                            text     = _("Reset to defaults"),
                            callback = function()
                                UIManager:close(dlg)
                                self:resetPerformanceSettings()
                            end,
                        },
                    },
                    {
                        {
                            text     = _("Cancel"),
                            callback = function() UIManager:close(dlg) end,
                        },
                    },
                },
            }
            UIManager:show(dlg)
        end,
        separator = true,
    })

    -- Network access
    local network_help = _("Choose whether Syncthing may connect to the Internet.\n\n"
        .. "• LAN only: No external connections. Global discovery, relays, NAT, crash reporting, "
        .. "and automatic upgrades are all disabled. This is the safest and most private mode.\n\n"
        .. "• Global: Enables global discovery, relays, NAT traversal, crash reporting, "
        .. "and automatic upgrades. Required for syncing across different networks.\n\n"
        .. "Changes are applied immediately and persist across restarts.")
    table.insert(sub, {
        text_func = function()
            return self.network_access == "global"
                and _("Network access: Global")
                or  _("Network access: LAN only")
        end,
        help_text      = network_help,
        keep_menu_open = true,
        hold_callback  = D.helpHold(network_help),
        callback       = function(tmi)
            self.network_access = (self.network_access == "global") and "lan" or "global"
            G_reader_settings:saveSetting("syncthing_network_access", self.network_access)
            if tmi then tmi:updateItems() end
            -- Apply immediately if Syncthing is already running.
            -- Note: the Go runtime limits (GOMEMLIMIT/GOGC) and --no-upgrade
            -- are set at process launch by start-syncthing and require a
            -- restart to change; we inform the user if that is the case.
            if self:isRunning() then
                self:applyNetworkSettings()
                UIManager:show(InfoMessage:new{
                    timeout = 3,
                    text    = _("Network settings applied."),
                })
            end
        end,
        separator = true,
    })

    return sub
end

---------------------------------------------------------------------------
-- Automation submenu
---------------------------------------------------------------------------
local function getAutomationMenu(self)
    -- Notifications (at the top, separated from the rest)
    local notifications_help = _("Show a brief notification outside the KOSyncthing+ menu when:\n"
                        .. "• A Quick Sync completes\n"
                        .. "• New sync conflicts are detected\n\n"
                        .. "Notifications are silent, appear at the top of the screen, and vanish after a few seconds.\n\n"
                        .. "Manual actions always show feedback directly in the menu, regardless of this setting.")
	-- Autostart Syncthing
    local always_help = _("Syncthing stays running whenever possible.\n\n"
        .. "Wi-Fi is turned on automatically when needed; if it cannot be turned on, Syncthing does not start. "
        .. "A check every 60 seconds restarts Syncthing if it should be running but isn't. "
        .. "When Wi-Fi goes off it stops, then starts again when Wi-Fi returns.\n\n"
        .. "Stopping Syncthing by hand keeps it stopped until you start it again or restart KOReader.")

    local autostart_help = _("Choose how Syncthing runs.")

    local wifi_help = _("Syncthing follows Wi-Fi, without ever turning it on.\n\n"
        .. "It starts when Wi-Fi is already on and stops when Wi-Fi goes off; an accidental drop is not fought, and Wi-Fi is left exactly as you set it.\n\n"
        .. "Stopping Syncthing by hand keeps it stopped until you start it again or restart KOReader.")

    local charging_help = _("Automation rules above only fire if the device is plugged in and charging.\n\n"
                         .. "Useful when you have a large library and don't want an unexpected Wi-Fi join to drain your battery mid-read.")

    -- Auto-merge after sync
    local auto_merge_help = _("Automatically merge reading-progress conflicts after every Quick Sync completes.\n\n"
                           .. "For each KOReader metadata conflict, the copy with the higher reading progress wins. "
                           .. "Non-metadata files are skipped.\n\n"
                           .. "A brief notification appears when merges are performed or when a merge fails. "
                           .. "Disabled by default — enable only after you are comfortable with the manual "
                           .. "Auto-merge progress action in Status & conflicts.\n\n"
                           .. "It compares reading position only: the copy that is further ahead wins "
                           .. "the whole sidecar, so highlights made on a copy that is not the "
                           .. "furthest-read one can be overwritten. Skipped while a book is open.")

    -- Periodic Quick Sync
    local periodic_sync_help = _("Automatically run a Quick Sync at regular intervals when the device is awake.\n\n"
                        .. "Works silently in the background — no pop‑ups, no interruptions. "
                        .. "A small notification appears only when files are transferred or if a problem occurs.\n\n"
                        .. "Uses KOReader's seamless Wi‑Fi framework — Wi‑Fi is turned on/off automatically according to your Network settings.\n\n"
                        .. "For fully automatic operation, set 'Action when Wi‑Fi is off' to 'turn on' in KOReader → Network.")

    -- Sync interval
    local interval_help = _("Choose how often to run the periodic Quick Sync, in minutes.\n\n"
                        .. "Set any value between 1 and 1440 (24 hours). Examples: 15, 45, 90, 120.")

    return {
        {
            text           = _("Show notifications"),
            help_text      = notifications_help,
            keep_menu_open = true,
            checked_func   = function() return self.notifications_enabled end,
            hold_callback  = D.helpHold(notifications_help),
            callback       = function(tmi)
                self.notifications_enabled = not self.notifications_enabled
                G_reader_settings:saveSetting("syncthing_notifications_enabled", self.notifications_enabled)
                if tmi then tmi:updateItems() end
            end,
            separator = true,
        },
        {
            text_func = function()
                if self.autostart_mode == "always" then
                    return T(_("Start mode: %1"), _("Always (brings Wi-Fi up)"))
                elseif self.autostart_mode == "wifi" then
                    return T(_("Start mode: %1"), _("When Wi-Fi is on"))
                end
                return _("Start mode")
            end,
            help_text      = autostart_help,
            keep_menu_open = true,
            hold_callback  = D.helpHold(autostart_help),
            sub_item_table = {
                {
                    text           = _("When Wi-Fi is on"),
                    help_text      = wifi_help,
                    keep_menu_open = true,
                    checked_func   = function() return self.autostart_mode == "wifi" end,
                    hold_callback  = D.helpHold(wifi_help),
                    callback       = function(tmi)
                        self:_setAutostartMode(self.autostart_mode == "wifi" and "off" or "wifi")
                        if tmi then tmi:updateItems() end
                    end,
                },
                {
                    text           = _("Always (brings Wi-Fi up)"),
                    help_text      = always_help,
                    keep_menu_open = true,
                    checked_func   = function() return self.autostart_mode == "always" end,
                    hold_callback  = D.helpHold(always_help),
                    callback       = function(tmi)
                        self:_setAutostartMode(self.autostart_mode == "always" and "off" or "always")
                        if tmi then tmi:updateItems() end
                    end,
                },
            },
        },
        {
            text           = _("Periodic Quick Sync"),
            help_text      = periodic_sync_help,
            keep_menu_open = true,
            checked_func   = function() return self.periodic_sync_enabled end,
            hold_callback  = D.helpHold(periodic_sync_help),
            callback       = function(tmi)
                self.periodic_sync_enabled = not self.periodic_sync_enabled
                G_reader_settings:saveSetting("syncthing_periodic_sync_enabled", self.periodic_sync_enabled)
                if self.periodic_sync_enabled then
                    if Device:hasSeamlessWifiToggle() and G_reader_settings:readSetting("wifi_enable_action") ~= "turn_on" then
                        UIManager:show(InfoMessage:new{
                            text = _("Tip: Set 'Action when Wi‑Fi is off' to 'turn on' in KOReader Network settings for fully automatic sync."),
                            timeout = 5,
                        })
                    end
                    self:_startPeriodicSyncTimer()
                else
                    self:_stopPeriodicSyncTimer()
                end
                if tmi then tmi:updateItems() end
            end,
        },
        {
            text_func = function()
                local base = T(_("Sync interval: %1 min"), self.periodic_sync_interval_min)
                if self.periodic_sync_enabled and self._next_periodic_sync_at then
                    local remaining_sec = self._next_periodic_sync_at - os.time()
                    local remaining_min = math.max(0, math.ceil(remaining_sec / 60))
                    return base .. "  ·  " .. T(_("next in %1 min"), remaining_min)
                end
                return base
            end,
            help_text      = interval_help,
            keep_menu_open = true,
            enabled_func   = function() return self.periodic_sync_enabled end,
            hold_callback  = D.helpHold(interval_help),
            callback       = function(tmi)
                local dlg
                dlg = InputDialog:new{
                    title      = _("Sync interval (minutes)"),
                    input      = tostring(self.periodic_sync_interval_min),
                    input_type = "number",
                    input_hint = "30",
                    buttons    = {{
                        {
                            text     = _("Cancel"),
                            id       = "close",
                            callback = function() UIManager:close(dlg) end,
                        },
                        {
                            text             = _("Save"),
                            is_enter_default = true,
                            callback         = function()
                                local val = tonumber(dlg:getInputText())
                                if not val or val < 1 or val > 1440 then
                                    UIManager:show(InfoMessage:new{
                                        icon = "notice-warning",
                                        text = _("Interval must be between 1 and 1440 minutes (24 hours)."),
                                    })
                                    return
                                end
                                self.periodic_sync_interval_min = val
                                G_reader_settings:saveSetting("syncthing_periodic_sync_interval_min", val)
                                UIManager:close(dlg)
                                self:_stopPeriodicSyncTimer()
                                self:_startPeriodicSyncTimer()
                                if tmi then tmi:updateItems() end
                            end,
                        },
                    }},
                }
                UIManager:show(dlg)
                dlg:onShowKeyboard()
            end,
            separator = true,
        },
        {
            text_func = function()
                return G_reader_settings:isTrue("syncthing_auto_merge_conflicts")
                    and _("Auto-merge conflicts after sync ✓")
                    or  _("Auto-merge conflicts after sync")
            end,
            help_text      = auto_merge_help,
            keep_menu_open = true,
            checked_func   = function()
                return G_reader_settings:isTrue("syncthing_auto_merge_conflicts")
            end,
            hold_callback  = D.helpHold(auto_merge_help),
            callback       = function(tmi)
                if G_reader_settings:isTrue("syncthing_auto_merge_conflicts") then
                    -- Disabling is always safe — no confirmation needed.
                    G_reader_settings:saveSetting("syncthing_auto_merge_conflicts", false)
                    if tmi then tmi:updateItems() end
                else
                    -- Enabling can delete annotations — require explicit double confirmation.
                    confirmEnableAutoMerge(function()
                        G_reader_settings:saveSetting("syncthing_auto_merge_conflicts", true)
                        if tmi then tmi:updateItems() end
                    end)
                end
            end,
            separator = true,
        },
        {
            text_func = function()
                return self.auto_start_charging
                    and _("Apply automation only when charging ✓")
                    or  _("Apply automation only when charging")
            end,
            help_text      = charging_help,
            keep_menu_open = true,
            checked_func   = function() return self.auto_start_charging end,
            enabled_func   = D.enabled(self, "hasAutomation"),
            hold_callback  = D.gatedHold(self, "hasAutomation", charging_help),
            callback       = function(tmi)
                self.auto_start_charging = not self.auto_start_charging
                G_reader_settings:saveSetting("syncthing_auto_start_charging", self.auto_start_charging)
                if tmi then tmi:updateItems() end
            end,
        },
    }
end
---------------------------------------------------------------------------
-- Maintenance submenu (logs, debug, update, reset)
---------------------------------------------------------------------------
local function getMaintenanceMenu(self, touchmenu_instance)
    -- The log lives in the config directory (start-syncthing writes
    -- --log-file there).  Use getConfigDir() so the path stays centralized.
    local log_path = U.getConfigDir() .. "/syncthing.log"

    -- Help texts hoisted to locals so each one is referenced both by
    -- help_text (shown in some KOReader UIs) and by hold_callback (always
    -- available via tap-and-hold).  Keeping them as named locals keeps
    -- the menu items themselves readable.
    local view_log_help     = _("Show the last lines of the Syncthing log.\n\n"
                             .. "Useful when reporting bugs or diagnosing why Syncthing failed to start.")
    local clear_log_help    = _("Delete the Syncthing log file.\n\n"
                             .. "A new log will be created automatically the next time Syncthing runs. Use this to reclaim disk space or to start with a clean log after fixing an issue.")
    local update_help       = _("Check GitHub for a newer Syncthing binary and install it if available.\n\n"
                             .. "Wi-Fi is required. The currently installed version is shown in the menu label.")
    local install_help      = _("Download and install the Syncthing binary for this device's platform.\n\n"
                             .. "Wi-Fi is required.")
    local plugin_update_help = _("Check GitHub for a newer release of the KOSyncthing+ plugin and install it in place.\n\n"
                             .. "Wi-Fi is required. Your settings, paired devices and the Syncthing binary are kept; KOReader restarts to load the new version.")
    local api_error_help    = _("Show details of the last failed Syncthing API request.\n\n"
                             .. "Useful when reporting bugs. Becomes available only after an API call has failed.")
    local reset_db_help     = _("Delete the local Syncthing index so it is rebuilt from scratch on the next start.\n\n"
                             .. "No files are deleted — this only affects Syncthing's internal tracking database. Use this if Syncthing is stuck, reporting incorrect sync status, or failing to detect file changes.\n\n"
                             .. "First sync after a reset will be slower than usual.")
    local reset_all_help    = _("Wipe Syncthing's config, database, password, device ID, and all plugin settings.\n\n"
                             .. "Your synced files on disk are NOT deleted.\n\n"
                             .. "Use this when you want to start over cleanly. Other devices will need to re-pair with the new device ID this generates.")

    -- Build the log-related submenu once
    local log_items = {
        -- View logs
        {
            text           = _("View logs"),
            help_text      = view_log_help,
            keep_menu_open = true,
            hold_callback  = D.helpHold(view_log_help),
            callback       = self.safe("View log", function()
                if not util.pathExists(log_path) then
                    UIManager:show(InfoMessage:new{
                        text = _("No log file found yet.\n\nStart Syncthing at least once to generate one."),
                    })
                    return
                end
                local lines = {}
                local f = io.open(log_path, "r")
                if f then
                    for line in f:lines() do
                        table.insert(lines, line)
                        if #lines > 200 then table.remove(lines, 1) end
                    end
                    f:close()
                end
                local content = #lines > 0 and table.concat(lines, "\n") or ""
                UIManager:show(TextViewer:new{
                    title = _("Syncthing log"),
                    text  = content ~= "" and content or _("Log file is empty."),
                    width  = math.floor(Device.screen:getWidth()  * 0.92),
                    height = math.floor(Device.screen:getHeight() * 0.85),
                })
            end),
        },
        -- View errors only
        {
            text           = _("View errors only"),
            help_text      = _("Show only the warning and error lines from the Syncthing log, filtering out routine information."),
            keep_menu_open = true,
            hold_callback  = D.helpHold(_("Useful for diagnosing problems without scrolling through the entire log.")),
            callback       = self.safe("View errors", function()
                if not util.pathExists(log_path) then
                    UIManager:show(InfoMessage:new{
                        text = _("No log file found yet.\n\nStart Syncthing at least once to generate one."),
                    })
                    return
                end
                local lines = {}
                local f = io.open(log_path, "r")
                if f then
                    for line in f:lines() do
                        if line:find("%[WARNING%]") or line:find("%[ERROR%]") then
                            table.insert(lines, line)
                            if #lines > 200 then table.remove(lines, 1) end
                        end
                    end
                    f:close()
                end
                local content = #lines > 0 and table.concat(lines, "\n") or ""
                UIManager:show(TextViewer:new{
                    title = _("Syncthing log (errors only)"),
                    text  = content ~= "" and content or _("No errors found in the log."),
                    width  = math.floor(Device.screen:getWidth()  * 0.92),
                    height = math.floor(Device.screen:getHeight() * 0.85),
                })
            end),
        },
        -- Clear log
        {
            text           = _("Clear log file"),
            help_text      = clear_log_help,
            keep_menu_open = true,
            hold_callback  = D.helpHold(clear_log_help),
            callback       = self.safe("Clear log", function()
                if not util.pathExists(log_path) then
                    UIManager:show(InfoMessage:new{ text = _("No log file exists yet.") })
                    return
                end
                UIManager:show(ConfirmBox:new{
                    text        = _("Delete the Syncthing log file?\n\nA new log will be created automatically on the next start."),
                    ok_text     = _("Delete log"),
                    cancel_text = _("Cancel"),
                    ok_callback = function()
                        FS.remove(log_path)
                        UIManager:show(InfoMessage:new{ timeout = 2, text = _("Log file deleted.") })
                    end,
                })
            end),
        },
    }

    return {
        -- Logs (grouped)
        {
            text                = _("Logs"),
            help_text           = _("View, filter, or clear the Syncthing log."),
            keep_menu_open      = true,
            hold_callback       = D.helpHold(_("View the full log, show only errors, or delete the log file to free space.")),
            sub_item_table_func = function() return log_items end,
            separator           = true,   -- separator after the Logs group
        },

        -- Copy diagnostic info
        -- Collects plugin state, versions, folder health, recent errors and
        -- log lines into a QR code (scan with your phone), a text viewer,
        -- and the clipboard.  Paste into a bug report or support request.
        {
            text           = _("Copy diagnostic info"),
            help_text      = _("Collect plugin state, version info, folder health, recent errors and log lines into a QR code (scan with your phone) and copy to clipboard.\n\nPaste into a bug report or support request."),
            keep_menu_open = true,
            hold_callback  = D.helpHold(_("Useful when reporting bugs. Shows a QR code you can scan with your phone to get the full diagnostic snapshot.")),
callback = self.safe("Diagnostic snapshot", function()
    local lines = {}
    local function ln(s)  lines[#lines + 1] = s or "" end
    local function head(t)
        if #lines > 0 then ln("") end
        ln(t)
    end
    local function kv(k, v)
        ln(string.format("  %-11s%s", k, tostring(v)))
    end

    -- ── meta ────────────────────────────────────────────────────────────────
    local meta = {}
    do
        local ok, m = pcall(dofile, U.plugin_path .. "_meta.lua")
        if ok and type(m) == "table" then meta = m end
    end
    local pid = self:getPid()

    -- ── KOReader version (best-effort) ───────────────────────────────────────
    local kr_version = "unknown"
    do
        local ok, Version = pcall(require, "version")
        if ok and Version and Version.getCurrentRevision then
            kr_version = Version:getCurrentRevision() or "unknown"
        end
    end

    -- ── platform string ──────────────────────────────────────────────────────
    local platform = Device:isKindle() and "Kindle"
                  or Device:isKobo()   and "Kobo"
                  or Device:isAndroid() and "Android"
                  or Device:isPocketBook() and "PocketBook"
                  or "unknown"

    -- ── device short ID ─────────────────────────────────────────────────────
    local full_id    = self:getDeviceId()
    local short_id   = (type(full_id) == "string" and full_id ~= "")
                       and full_id:sub(1, 7) or "not cached"

    -- ── Header ───────────────────────────────────────────────────────────────
    ln("KOSyncthing+ " .. (meta.version or "?") .. "  ·  " .. os.date("%Y-%m-%d %H:%M"))

    -- ── System ───────────────────────────────────────────────────────────────
    head("SYSTEM")
    kv("Plugin",    meta.version or "?")
    kv("Syncthing", self:getCurrentVersion() or "not installed")
    kv("KOReader",  kr_version)
    kv("Platform",  platform)
    kv("Running",   (self:isRunning() and "yes" or "no")
                    .. (pid and ("  (PID " .. tostring(pid) .. ")") or ""))
    kv("Port",      tostring(self.syncthing_port or "?"))
    kv("Device ID", short_id)

    -- ── Binary & Process ─────────────────────────────────────────────────────
    head("BINARY")
    local bin_path = U.getBinaryPath()
    if not util.pathExists(bin_path) then
        kv("Arch", "not found")
        ln("    " .. bin_path)
    else
        local arch = U.isELF(bin_path) and (self:getBinaryArch() or "unknown") or "NOT ELF"
        local size_str = ""
        do
            local _ok, lfs2 = pcall(require, "libs/libkoreader-lfs")
            if not _ok then _ok, lfs2 = pcall(require, "lfs") end
            if _ok and lfs2 then
                local attr = lfs2.attributes(bin_path)
                if attr and attr.size then
                    size_str = "  (" .. U.formatBytes(attr.size) .. ")"
                end
            end
        end
        kv("Arch", arch .. size_str)
        if arch == "NOT ELF" then
            local f = io.open(bin_path, "r")
            if f then
                local preview = f:read(80)
                f:close()
                if preview then
                    ln("    preview: " .. preview:gsub("\n", " "):gsub("%s+", " "):sub(1, 70))
                end
            end
        end
    end
    if pid then
        local rss, thr, cpu = "?", "?", "?"
        local f = io.open("/proc/" .. pid .. "/status", "r")
        if f then
            for line in f:lines() do
                local v = line:match("^VmRSS:%s*(%d+)")
                if v then rss = U.formatBytes(tonumber(v) * 1024) end
                v = line:match("^Threads:%s*(%d+)")
                if v then thr = v end
            end
            f:close()
        end
        local sf = io.open("/proc/" .. pid .. "/stat", "r")
        if sf then
            local stat = sf:read("*a"); sf:close()
            if stat then
                local after = stat:match("%) (.*)")
                if after then
                    local nums = {}
                    for n in after:gmatch("%S+") do nums[#nums + 1] = n end
                    local ut = tonumber(nums[12]) or 0
                    local st = tonumber(nums[13]) or 0
                    cpu = string.format("%.1fs", (ut + st) / 100)
                end
            end
        end
        kv("Process", rss .. " RAM · " .. thr .. " threads · " .. cpu .. " CPU")
    end

    -- ── Storage ──────────────────────────────────────────────────────────────
    head("STORAGE")
    local plugin_fs = util.getFilesystemType(U.plugin_path) or "unknown"
    local config_dir = U.getConfigDir()
    local config_fs  = (config_dir ~= U.plugin_path)
                       and util.getFilesystemType(config_dir) or plugin_fs
    local fs_str = plugin_fs
    if config_fs ~= plugin_fs then
        fs_str = "plugin=" .. plugin_fs .. " config=" .. config_fs
    end
    local free_plugin = U.getFreeSpace(U.plugin_path)
    kv("Filesystem", fs_str .. (free_plugin and (" · " .. U.formatBytes(free_plugin) .. " free") or ""))

    local data_dir, dreason = U.getDataDir()
    local io_errs = 0
    if util.pathExists(log_path) then
        local lf = io.open(log_path, "r")
        if lf then
            for line in lf:lines() do
                if line:find("disk I/O error", 1, true) then io_errs = io_errs + 1 end
            end
            lf:close()
        end
    end
    local db_meta = tostring(dreason)
    if data_dir ~= config_dir then
        local free2 = U.getFreeSpace(data_dir)
        if free2 then db_meta = db_meta .. " · " .. U.formatBytes(free2) .. " free" end
    end
    kv("Database", db_meta)
    ln("    " .. tostring(data_dir))
    kv("I/O errors", tostring(io_errs) .. (io_errs > 0 and "  ⚠ DB on a failing filesystem" or ""))

    -- ── Network ──────────────────────────────────────────────────────────────
    head("NETWORK")
    local ip = U.getDeviceIP()
    kv("Status", (U.loopbackIsUp() and "up" or "down ⚠")
                 .. (ip and ip ~= "127.0.0.1" and (" · " .. ip) or ""))
    if Device:isKindle() then
        local sync_open = U.execOk(os.execute("iptables -C INPUT -p tcp --dport 22000 -j ACCEPT 2>/dev/null"))
        local disc_open = U.execOk(os.execute("iptables -C INPUT -p udp --dport 21027 -j ACCEPT 2>/dev/null"))
        kv("Ports", "TCP 22000 " .. (sync_open and "open" or "blocked ⚠")
                    .. " · UDP 21027 " .. (disc_open and "open" or "blocked ⚠"))
    end

    -- ── Configuration ────────────────────────────────────────────────────────
    head("CONFIG")
    local folders  = self:getFolders()  or {}
    local devices  = self:getDevices()  or {}
    local gui_set  = true
    local config_xml = U.getConfigDir() .. "/config.xml"
    if util.pathExists(config_xml) then
        local f = io.open(config_xml, "r")
        if f then
            local content = f:read("*a"); f:close()
            if content and not (content:find("<user>") and content:find("<password>")) then
                gui_set = false
            end
        end
    end
    kv("Folders", #folders)
    kv("Devices", #devices)
    kv("GUI auth", gui_set and "set" or "not set ⚠")

    -- ── Folders ──────────────────────────────────────────────────────────────
    head(string.format("FOLDERS (%d)", #folders))
    local fh = self:getFolderHealth()
    local folder_states = fh and fh.folder_states or {}
    if #folders == 0 then
        ln("  (none)")
    else
        ln(string.format("  %-20s  %-10s  %s", "name", "state", "errors"))
        for _, folder in ipairs(folders) do
            local fid   = folder["id"] or ""
            local label = folder["label"] or fid
            local fs    = folder_states[fid] or {}
            local state = fs.paused and "paused"
                       or (fs.state or "unknown")
            local errcnt = fs.errors and "1" or "0"
            local warn   = (fs.errors and not fs.errors_fixable) and "  ⚠ needs attention" or
                           (fs.errors and fs.errors_fixable)     and "  (rescan-fixable)"  or ""
            ln(string.format("  %-20s  %-10s  %s%s", label:sub(1, 20), state, errcnt, warn))
            if fs.error_texts then
                for _, msg in ipairs(fs.error_texts) do
                    ln("    ! " .. msg:sub(1, 60))
                end
            end
        end
    end

    -- ── Syncthing log (last 5 entries via REST) ───────────────────────────────
    head("SYNCTHING LOG (last 5)")
    if self:isRunning() then
        local log_resp = self:GET("system/log")
        local entries  = log_resp and log_resp.data and log_resp.data.messages or {}
        local start    = math.max(1, #entries - 4)
        if #entries == 0 then
            ln("  (none)")
        else
            for i = start, #entries do
                local e   = entries[i]
                local ts  = (e.when or ""):match("T(%d%d:%d%d:%d%d)") or (e.when or "?"):sub(1, 16)
                local lvl = (e.level or "info"):upper():sub(1, 7)
                ln(string.format("  %s  %-7s  %s", ts, lvl, (e.message or ""):sub(1, 55)))
            end
        end
    else
        ln("  (Syncthing not running)")
    end

    -- ── Plugin log (last 5 WARN/ERROR) ───────────────────────────────────────
    head("PLUGIN LOG (last 5 WARN/ERROR)")
    if not util.pathExists(log_path) then
        ln("  (no log file)")
    else
        local plugin_lines = {}
        local lf = io.open(log_path, "r")
        if lf then
            for line in lf:lines() do
                if line:find("%[WARNING%]") or line:find("%[ERROR%]") then
                    plugin_lines[#plugin_lines + 1] = line
                    if #plugin_lines > 5 then table.remove(plugin_lines, 1) end
                end
            end
            lf:close()
        end
        if #plugin_lines == 0 then
            ln("  (none)")
        else
            for _, l in ipairs(plugin_lines) do
                local short = l:match("%[W[^%]]+%].*") or l:match("%[E[^%]]+%].*") or l
                ln("  " .. short:sub(1, 72))
            end
        end
    end

    -- ── API errors ───────────────────────────────────────────────────────────
    head("API ERRORS")
    local api_errors = self:getApiErrors()
    if not api_errors or #api_errors == 0 then
        ln("  none")
    else
        for i = math.max(1, #api_errors - 4), #api_errors do
            local e = api_errors[i]
            ln(string.format("  [%d] %s %s → %s",
                i, e.endpoint or "?", e.method or "", e.error or e.status or "?"))
        end
    end

    local snapshot = table.concat(lines, "\n")

    -- Show QR then viewer + clipboard
    UIManager:show(QRMessage:new{
        text   = snapshot,
        width  = math.floor(Device.screen:getWidth()  * 0.85),
        height = math.floor(Device.screen:getHeight() * 0.85),
        dismiss_callback = function()
            UIManager:show(TextViewer:new{
                title  = _("Diagnostic info (also copied to clipboard)"),
                text   = snapshot,
                width  = math.floor(Device.screen:getWidth()  * 0.92),
                height = math.floor(Device.screen:getHeight() * 0.85),
            })
        end,
    })
    U.copyToClipboard(snapshot)
end),
		},

        -- Debug: API error viewer (now shows up to 8 recent errors)
        {
            text_func = function()
                local errors = self:getApiErrors()
                local count = errors and #errors or 0
                return count > 0
                    and T(_("View API errors (%1)"), count)
                    or  _("View API errors")
            end,
            help_text      = api_error_help,
            keep_menu_open = true,
            enabled_func   = D.enabled(self, "hasApiError"),
            hold_callback  = D.gatedHold(self, "hasApiError", api_error_help),
            callback       = self.safe("API errors", function()
                local errors = self:getApiErrors()
                if #errors == 0 then
                    UIManager:show(InfoMessage:new{
                        text = _("No API errors recorded."),
                    })
                    return
                end
                local text = ""
                for i, err in ipairs(errors) do
                    text = text .. string.format(
                        "#%d  %s\n%s: %s\n%s: %s\n\n%s:\n%s\n\n───\n\n",
                        i,
                        os.date("%Y-%m-%d %H:%M:%S", err.time),
                        _("Path"),   err.path or "?",
                        _("Status"), err.status or "?",
                        _("Body"),   err.body or _("(empty)"))
                end
                UIManager:show(TextViewer:new{
                    title = T(_("API errors (%1)"), #errors),
                    text  = text,
                    width  = math.floor(Device.screen:getWidth()  * 0.92),
                    height = math.floor(Device.screen:getHeight() * 0.80),
                })
            end),
        },

        {
            text           = _("Clear all API errors"),
            help_text      = _("Remove all stored API errors from memory."),
            keep_menu_open = true,
            enabled_func   = D.enabled(self, "hasApiError"),
            hold_callback  = D.gatedHold(self, "hasApiError", _("Tap to clear all API errors from memory.")),
            callback       = function(tmi)
                self:_clearApiErrors()
                UIManager:show(InfoMessage:new{
                    timeout = 2,
                    text    = _("All API errors cleared."),
                })
                if tmi then tmi:updateItems() end
            end,
            separator      = true,
        },

        -- Copy API key
        {
            text           = _("Copy API key"),
            help_text      = _("Copy the Syncthing API key to the clipboard."),
            keep_menu_open = true,
            hold_callback  = D.helpHold(_("The API key gives full access to Syncthing's settings via its REST API. Keep it secret.")),
            callback       = self.safe("Copy API key", function()
                local api_key = self:getAPIKey()
                if api_key and api_key ~= "" then
                    U.copyToClipboard(api_key)
                else
                    UIManager:show(InfoMessage:new{
                        icon = "notice-warning",
                        text = _("No API key found. Make sure Syncthing has been started at least once, or enter it in the connection settings."),
                        timeout = 3,
                    })
                end
            end),
        },

        -- Reset database — stop-and-continue so the user never has to
        -- hunt for the Stop button first.
        {
            text           = _("Reset sync database"),
            help_text      = reset_db_help,
            keep_menu_open = true,
            hold_callback  = D.helpHold(reset_db_help),
            callback       = self.safe("Reset db", function()
                local function doResetDb()
                    UIManager:show(ConfirmBox:new{
                        text = _("Delete the local Syncthing database?\n\n"
                              .. "Syncthing will rebuild its index on the next start. No files are deleted.\n\n"
                              .. "First sync after this may be slow."),
                        ok_text     = _("Reset database"),
                        cancel_text = _("Cancel"),
                        ok_callback = function()
                            -- AD-19: the index files live in the DATA dir, which
                            -- may be relocated off /mnt/us — use getDataDir(), not
                            -- a hardcoded settings/syncthing path, or the reset
                            -- would miss the real database.
                            local db_dir = U.getDataDir()
                            local ok, err = FS.purgeChildrenMatching(db_dir, "index-*", "any")
                                -- "index-*" is a POSIX shell glob (passed to find -name).
                                -- The previous "^index%-" was a Lua pattern and matched nothing (BUG-34).
                            if ok then
                                UIManager:show(InfoMessage:new{
                                    timeout = 3,
                                    text = _("Database reset.\n\nStart Syncthing to rebuild the index from disk."),
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    icon = "notice-warning",
                                    text = _("Database reset completed with errors.\n\n"
                                          .. "Some index files could not be removed. "
                                          .. "Check the logs for details."),
                                })
                            end
                        end,
                    })
                end
                if self:isRunning() then
                    UIManager:show(ConfirmBox:new{
                        text        = _("Resetting the database requires stopping Syncthing.\n\nStop now and continue?"),
                        ok_text     = _("Stop & continue"),
                        cancel_text = _("Cancel"),
                        ok_callback = function()
                            self:stop(function() doResetDb() end)
                        end,
                    })
                    return
                end
                doResetDb()
            end),
        },

        -- Reset everything: the escape hatch
        {
            text           = _("Reset everything to factory defaults"),
            help_text      = reset_all_help,
            keep_menu_open = true,
            hold_callback  = D.helpHold(reset_all_help),
            callback       = self.safe("Reset all", function(tmi)
                self:resetEverything(function()
                    if tmi then tmi:updateItems() end
                end)
            end),
        },

        -- Restart Syncthing
        {
            text           = _("Restart Syncthing"),
            help_text      = _("Stop Syncthing and start it again. Useful when Syncthing is unresponsive or after changing resource settings."),
            keep_menu_open = true,
            enabled_func   = D.enabled(self, "isRunning"),
            hold_callback  = D.gatedHold(self, "isRunning", _("Tap to restart Syncthing now.")),
            callback       = function(tmi)
                self:stop(function()
                    self._silentStart = true   -- без "Syncthing started" съобщение
                    self:start()
                    if tmi then tmi:updateItems() end
                end)
            end,
            separator = true,
        },

        -- Check for updates (submenu: Syncthing binary + the plugin itself)
        {
            text = _("Check for updates"),
            keep_menu_open = true,
            sub_item_table = {
                {
                    text_func = function()
                        if not self:binaryExists() then return _("Install Syncthing binary") end
                        local ver = self:getCurrentVersion()
                        return ver
                            and T(_("Update Syncthing binary  (v%1 installed)"), ver)
                            or  _("Update Syncthing binary")
                    end,
                    help_text = update_help,
                    keep_menu_open = true,
                    -- Use a context-aware hold so that we explain the right thing
                    -- depending on whether the binary is already installed.
                    hold_callback = function()
                        local txt = self:binaryExists() and update_help or install_help
                        UIManager:show(InfoMessage:new{ text = txt })
                    end,
                    callback = self.safe("Check updates", function()
                        if not self:binaryExists() then
                            self:showFirstRunDialog()
                        else
                            self:checkForUpdates()
                        end
                    end),
                },
                {
                    text_func = function()
                        local pv = require("st_plugin_update").getInstalledPluginVersion()
                        return (pv and pv ~= "unknown")
                            and T(_("Check for plugin updates  (%1 installed)"), pv)
                            or  _("Check for plugin updates")
                    end,
                    help_text = plugin_update_help,
                    keep_menu_open = true,
                    callback = self.safe("Check plugin updates", function()
                        self:checkForPluginUpdates()
                    end),
                },
            },
        },
    }
end


---------------------------------------------------------------------------
-- Top-level menu (the entry point in Tools)
---------------------------------------------------------------------------
-- ─────────────────────────────────────────────────────────────────────────────
-- Android remote-mode menu (separate from the Kindle/Kobo menu)
-- ─────────────────────────────────────────────────────────────────────────────
-- Built additively from ONLY what works without a local daemon, so the normal
-- menu builder below is never touched.  Reuses getStatusMenu (already a
-- standalone function) and calls existing methods for actions; the daemon
-- controls (start/stop/install/automation/maintenance/logs/reset) are simply
-- not offered, so their ConfirmBox/InfoMessage paths are never reached.
local function getAndroidMenu(self)
    local Android = require("st_android")

    -- Not connected yet (no saved key, or the app was unreachable at init):
    -- a single row that opens the connect dialog.
	if self._android_unavailable and not self._android_mode then
		local connect = Android.connectionSettingsMenuItem(self)
		return {
			{
				text      = _("Connect to the Syncthing app"),
				help_text = _("This plugin works alongside a Syncthing app (e.g. Syncthing-Fork) running on this device. Install and start it, then tap here to enter its API key."),
				keep_menu_open = true,
				callback  = function(tmi)
					connect.callback(tmi)
				end,
			},
		}
	end

    local sub = {}

    -- Status header — tap routes by state: open conflicts to resolve, do a
    -- one-tap rescan when that would fix the errors, else open the status view.
    sub[#sub + 1] = {
        text_func = function()
            local header = self:getStatusHeader()
            if not self:headerNeedsAction() then return header end
            local cached = self:_cacheGet("conflicts")
            local n = cached and #cached or 0
            if n > 0 then return header .. _(" — tap to resolve") end
            local h = self:getFolderHealth()
            if h and h.errors > 0 and h.errors_fixable then
                return header .. _(" — tap to fix")
            end
            return header .. _(" — tap to view")
        end,
        enabled_func   = function() return self:headerNeedsAction() end,
        help_text      = _("Open the status view: folder sync state, sync conflicts, and any pending devices or folders."),
        keep_menu_open = true,
        separator      = true,
        callback = self.safe("Status header", function(tmi)
            local function showStatus()
                local status_menu = getStatusMenu(self)
                if status_menu and #status_menu > 0 then
                    local Menu = require("ui/widget/menu")
                    UIManager:show(Menu:new{
                        title      = _("Status & conflicts"),
                        item_table = status_menu,
                    })
                end
            end
            if #self:findConflicts() > 0 then showConflicts(self); return end
            local h = self:getFolderHealth()
            if h and h.errors > 0 and h.errors_fixable then
                -- One-tap fix: a rescan clears the transient ("changed during
                -- …") errors. Same action as the "Rescan all folders" item.
                local ok = self:apiCall("db/scan", "POST")
                self:_cacheInvalidate()
                UIManager:show(InfoMessage:new{
                    text    = ok and _("Rescan started.") or _("Rescan failed — is the Syncthing app running?"),
                    timeout = 2,
                })
                if tmi and tmi.updateItems then tmi:updateItems() end
            else
                if not openErroringFolder(self, tmi) then showStatus() end
            end
        end),
    }

    -- Rescan all folders (POST /rest/db/scan via the API).
    sub[#sub + 1] = {
        text_func      = function()
            local h = self:getFolderHealth()
            if h and h.errors > 0 and h.errors_fixable then return _("Fix errors") end
            return _("Rescan all folders")
        end,
        help_text      = _("Ask the Syncthing app to rescan every folder now, so recent file changes are detected and synced without waiting."),
        keep_menu_open = true,
        callback = self.safe("Android rescan", function(tmi)
            local ok = self:apiCall("db/scan", "POST")
            self:_cacheInvalidate()
            UIManager:show(InfoMessage:new{
                text    = ok and _("Rescan started.") or _("Rescan failed — is the Syncthing app running?"),
                timeout = 2,
            })
            -- A rescan only *starts* a sync; any conflict files are pulled
            -- afterwards.  Merging right now would scan a disk that doesn't
            -- have this round's conflicts yet, so defer it briefly to let the
            -- rescan land.  runSyncCompleted is itself gated on the setting and
            -- pcall-guarded, so an early/empty run is a harmless no-op, and
            -- anything not yet present is caught on the next rescan.
            if ok and G_reader_settings:isTrue("syncthing_auto_merge_conflicts") then
                UIManager:scheduleIn(5, function()
                    self:onSyncthingSyncCompleted()
                end)
            end
            if tmi and tmi.updateItems then tmi:updateItems() end
        end),
    }

    -- Auto-merge conflicts after sync
    sub[#sub + 1] = {
        text_func = function()
            return G_reader_settings:isTrue("syncthing_auto_merge_conflicts")
                and _("Auto-merge conflicts after sync ✓")
                or  _("Auto-merge conflicts after sync")
        end,
        help_text      = _("Automatically merge reading-progress conflicts after every Quick Sync completes.\n\n"
                         .. "For each KOReader metadata conflict, the copy with the higher reading progress wins. "
                         .. "Non-metadata files are skipped.\n\n"
                         .. "A brief notification appears when merges are performed or when a merge fails. "
                         .. "Disabled by default — enable only after you are comfortable with the manual "
                         .. "Auto-merge progress action in Status & conflicts.\n\n"
                         .. "It compares reading position only: the copy that is further ahead wins "
                         .. "the whole sidecar, so highlights made on a copy that is not the "
                         .. "furthest-read one can be overwritten. Skipped while a book is open."),
        keep_menu_open = true,
        checked_func   = function()
            return G_reader_settings:isTrue("syncthing_auto_merge_conflicts")
        end,
        callback       = function(tmi)
            if G_reader_settings:isTrue("syncthing_auto_merge_conflicts") then
                -- Disabling is always safe — no confirmation needed.
                G_reader_settings:saveSetting("syncthing_auto_merge_conflicts", false)
                if tmi and tmi.updateItems then tmi:updateItems() end
            else
                -- Enabling can delete annotations — same double confirmation as the standard menu.
                confirmEnableAutoMerge(function()
                    G_reader_settings:saveSetting("syncthing_auto_merge_conflicts", true)
                    if tmi and tmi.updateItems then tmi:updateItems() end
                end)
            end
        end,
        separator      = true,
    }

    -- Pause / resume all folders.
    sub[#sub + 1] = {
        text_func = function()
            local h = self:getFolderHealth()
            local paused = h and h.paused or 0
            local total  = h and h.total or 0
            if paused > 0 then return T(N_("Resume %1 paused folder", "Resume %1 paused folders", paused), paused) end
            return total > 0 and T(N_("Pause the folder", "Pause all %1 folders", total), total) or _("Pause all folders")
        end,
        help_text = _("Pause all folders to stop syncing temporarily (saves battery and data), or resume them again."),
        keep_menu_open = true,
        callback = self.safe("Android pause", function(tmi)
            local h = self:getFolderHealth()
            local do_pause = not (h and h.paused and h.paused > 0)
            self:setPauseAll(do_pause, function() if tmi and tmi.updateItems then tmi:updateItems() end end)
        end),
    }

    -- Status & conflicts — the core of remote mode (lfs conflict scan + merge).
    sub[#sub + 1] = {
        text_func = function()
            local n = #self:findConflicts()
            return n > 0 and T(_("Status & conflicts (%1)"), n) or _("Status & conflicts")
        end,
        help_text           = _("View sync status and resolve sync conflicts — for example when the same book was annotated on two devices. Reading progress can be auto-merged."),
        keep_menu_open      = true,
		sub_item_table_func = self.safe("Status menu", function(tmi)
			local menu = getStatusMenu(self, tmi)
			UIManager:nextTick(function()
				if tmi and tmi.updateItems then tmi:updateItems() end
			end)
			return menu
		end),
        separator           = true,
    }

    -- Web GUI access (address + QR), scheme-aware.
    sub[#sub + 1] = {
        text           = _("Web GUI access"),
        help_text      = _("Show the address to open the Syncthing Web GUI from any browser on the same Wi-Fi.\n\nThe Web GUI is where you add folders, configure ignore patterns, and tweak advanced options."),
        keep_menu_open = true,
        callback = self.safe("Android web GUI", function()
            local ip     = U.getDeviceIP()
            local host   = ip:find(":", 1, true) and ("[" .. ip .. "]") or ip
            local scheme = self._api_scheme or "http"
            local url    = string.format("%s://%s:%s", scheme, host, self.syncthing_port)
            UIManager:show(ConfirmBox:new{
                text = T(_("Open this address in a browser on the same Wi-Fi:\n\n%1\n\nOr scan the QR code with another device."), url),
                ok_text     = _("Show QR code"),
                cancel_text = _("Close"),
                ok_callback = function()
                    UIManager:show(QRMessage:new{
                        text   = url,
                        width  = math.floor(Device.screen:getWidth() * 0.8),
                        height = math.floor(Device.screen:getHeight() * 0.8),
                    })
                end,
            })
        end),
    }

    -- Pair with another device (reuses the existing wizard).
    sub[#sub + 1] = {
        text           = _("Pair with another device"),
        help_text      = _("Step-by-step wizard: shows your device ID and QR code, then watches for incoming pairing requests.\n\nWhen the other device sends a pairing request, this wizard offers to accept it automatically — you don't have to switch back and forth between devices."),
        keep_menu_open = true,
        separator      = true,
		callback = self.safe("Android pair", function(tmi)
			self:startPairWizard()
			if tmi and tmi.updateItems then tmi:updateItems() end
		end),
    }

    -- Connection settings (re-enter API key / re-detect scheme).
    sub[#sub + 1] = Android.connectionSettingsMenuItem(self)

    -- Plugin self-update.  Remote mode has no plugin-managed binary, so the
    -- full "Check for updates" submenu is absent here; the plugin can still
    -- update itself, so offer that one action with an Android-accurate help.
    sub[#sub + 1] = {
        text_func = function()
            local pv = require("st_plugin_update").getInstalledPluginVersion()
            return (pv and pv ~= "unknown")
                and T(_("Check for updates  (%1 installed)"), pv)
                or  _("Check for updates")
        end,
        help_text = _("Check GitHub for a newer release of the KOSyncthing+ plugin and install it in place.\n\nWi-Fi is required. Your settings and the saved connection to the Syncthing app are kept; KOReader restarts to load the new version."),
        keep_menu_open = true,
        callback = self.safe("Check plugin updates", function()
            self:checkForPluginUpdates()
        end),
    }

    -- Diagnostic snapshot — Android-relevant fields (no PID/legacy/binary).
    sub[#sub + 1] = {
        text           = _("Copy diagnostic info"),
        help_text      = _("Show plugin state, the connection scheme and port, and recent API errors, and copy them to the clipboard for a bug report."),
        keep_menu_open = true,
        callback = self.safe("Android diagnostic", function()
            local lines = {}
            local function ln(s)  lines[#lines + 1] = s or "" end
            local function head(t)
                if #lines > 0 then ln("") end
                ln(t)
            end
            local function kv(k, v)
                ln(string.format("  %-11s%s", k, tostring(v)))
            end

            local meta = {}
            do
                local ok, m = pcall(dofile, U.plugin_path .. "_meta.lua")
                if ok and type(m) == "table" then meta = m end
            end

            ln("KOSyncthing+ " .. (meta.version or "?") .. "  ·  " .. os.date("%Y-%m-%d %H:%M"))

            head("CONNECTION")
            kv("Mode",      "Android remote")
            kv("Scheme",    tostring(self._api_scheme))
            kv("Port",      tostring(self.syncthing_port))
            kv("Reachable", self:isRunning() and "yes" or "no")
            local dev = self._cacheGet and self:_cacheGet("device_id") or nil
            if dev then kv("Device ID", tostring(dev)) end

            head("API ERRORS")
            local errs = (self.getApiErrors and self:getApiErrors()) or self._api_errors or {}
            if #errs == 0 then
                ln("  none")
            else
                for i = math.max(1, #errs - 3), #errs do
                    local e = errs[i]
                    if e then ln(string.format("  [%d] %s → %s", i, tostring(e.path), tostring(e.status))) end
                end
            end

            head("FOLDERS")
            local fh = self:getFolderHealth()
            if fh and fh.folder_states then
                local printed_any = false
                for fid_d, fs in pairs(fh.folder_states) do
                    if fs.error_texts and #fs.error_texts > 0 then
                        printed_any = true
                        ln("  " .. tostring(fid_d) .. "  (" ..
                           (fs.errors_fixable and "rescan-fixable" or "needs attention ⚠") .. ")")
                        for _, m in ipairs(fs.error_texts) do
                            ln("    ! " .. tostring(m):sub(1, 60))
                        end
                    end
                end
                if not printed_any then
                    if (fh.errors or 0) > 0 then
                        ln("  " .. tostring(fh.errors) .. " error(s) (details unavailable)")
                    else
                        ln("  none")
                    end
                end
            else
                ln("  (unavailable)")
            end

            local text = table.concat(lines, "\n")
            pcall(function()
                if Device.input and Device.input.setClipboardText then
                    Device.input.setClipboardText(text)
                end
            end)
            UIManager:show(TextViewer:new{ title = _("Diagnostic info (also copied to clipboard)"), text = text })
        end),
    }

    sub[#sub + 1] = {
        text           = _("Reset connection"),
        help_text      = _("Forget the saved API key and reset the plugin's settings on this device, returning to the connect screen. The Syncthing app and its synced files are not affected."),
        keep_menu_open = true,
        callback       = self.safe("Android reset", function(tmi)
            self:resetEverything(function()
                if tmi and tmi.updateItems then tmi:updateItems() end
            end)
        end),
    }

    return sub
end

local function addToMainMenu(self, menu_items)
    -- Android remote mode: route to a separate, purpose-built menu.  The
    -- Kindle/Kobo construction below is left completely untouched.
    if self._android_mode or self._android_unavailable then
        menu_items.kosyncthing_plus = {
            text                = _("KOSyncthing+"),
            sorting_hint        = "tools",
            sub_item_table_func = function() return getAndroidMenu(self) end,
        }
        return
    end

    local startstop_help = _("Turn Syncthing on or off.\n\n"
                          .. "When off, no syncing happens and your battery is preserved.\n"
                          .. "When on, Syncthing watches your folders and exchanges files with your other devices over Wi-Fi.\n\n"
                          .. "If Syncthing isn't installed yet, this option offers to download it.")

    local quicksync_top_help = _("Run a one-shot sync: start Syncthing, scan your folders, "
                                .. "exchange changes, then stop.\n\n"
                                .. "If Syncthing is already running, this just triggers a rescan.\n\n"
                                .. "Wi-Fi is turned on/off automatically according to your Network "
                                .. "settings — no prompts, no interruptions.\n\n"
                                .. "A small notification appears only when the sync completes "
                                .. "(or if an error occurs).\n\n"
                                .. "Best for battery — saves you from leaving Syncthing running all day.")

    local pause_help = _("Pause syncing on all folders, or resume them all.\n\n"
                      .. "Useful before traveling, when sharing Wi-Fi with someone bandwidth-conscious, or to save battery without stopping Syncthing entirely.\n\n"
                      .. "Paused folders keep their settings — they just stop syncing.")

    local status_help = _("Dashboard showing what Syncthing is doing right now: per-folder state, "
                        .. "connected remote devices, and any sync conflicts.\n\n"
                        .. "When the header line starts with ⚠ you can tap it to jump directly here.\n\n"
                        .. "If two devices change the same file before they could sync, "
                        .. "you'll find conflicts here to resolve.")

    local setup_help = _("Connect new devices, set the Web GUI password, change the Web GUI port, "
                        .. "and adjust resource and network settings.\n\n"
                        .. "This is where you go after installing Syncthing for the first time, "
                        .. "or when you want to tweak performance or add another device.")

    local automation_help = _("Pick when Syncthing starts and stops automatically.\n\n"
                            .. "Periodic Quick Sync works silently in the background — no pop‑ups, no interruptions. "
                            .. "A small notification appears only when files are actually transferred or if a problem occurs.\n\n"
                            .. "For most users this is the best balance between convenience and battery life: "
                            .. "Syncthing runs only when needed, and your reading is never disturbed.")

    local maintenance_help = _("Logs, updates, debug info, and reset options.\n\n"
                            .. "Most users won't need anything in here. Useful when reporting bugs or recovering from a broken setup.")

    local syncthing_sub = {
        {
            text_func = function()
                local header = self:getStatusHeader()
                if self:headerNeedsAction() then
                    local cached   = self:_cacheGet("conflicts")
                    local n_cached = cached and #cached or 0
                    if n_cached > 0 then return header .. _(" — tap to resolve") end
                    local h = self:getFolderHealth()
                    if h and h.errors > 0 and h.errors_fixable then
                        return header .. _(" — tap to fix")
                    end
                    return header .. _(" — tap to view")
                end
                return header
            end,
            enabled_func        = function() return self:headerNeedsAction() end,
            separator           = true,
            keep_menu_open      = true,
            hold_callback       = function()
                if not self:binaryExists() then
                    UIManager:show(InfoMessage:new{
                        text = _("Syncthing is not installed yet."),
                        timeout = 3,
                    })
                elseif not self:isRunning() then
                    self:runManualStart()
                else
                    local conflicts = self:findConflicts()
                    if #conflicts > 0 then
                        showConflicts(self)
                    else
                        -- Errors a rescan won't fix (permission/space/marker/I/O):
                        -- open the status view instead of a Quick Sync that can't
                        -- help. Everything else (up to date, or rescan-fixable
                        -- errors) still triggers Quick Sync, exactly as before.
                        local h = self:getFolderHealth()
                        if h and h.errors > 0 and not h.errors_fixable then
                            local status_menu = getStatusMenu(self)
                            if status_menu and #status_menu > 0 then
                                local Menu = require("ui/widget/menu")
                                UIManager:show(Menu:new{
                                    title      = _("Status & conflicts"),
                                    item_table = status_menu,
                                })
                            end
                        else
                            self:runQuickSync()
                        end
                    end
                end
            end,
            callback = self.safe("Status header", function(tmi)
                local function showStatus()
                    local status_menu = getStatusMenu(self)
                    if status_menu and #status_menu > 0 then
                        local Menu = require("ui/widget/menu")
                        UIManager:show(Menu:new{
                            title      = _("Status & conflicts"),
                            item_table = status_menu,
                        })
                    end
                end
                if #self:findConflicts() > 0 then showConflicts(self); return end
                local h = self:getFolderHealth()
                if h and h.errors > 0 and h.errors_fixable then
                    -- One-tap fix: a rescan clears the transient ("changed
                    -- during …") errors. Same action as "Rescan all folders".
                    self:quickSync(function() if tmi then tmi:updateItems() end end)
                else
                    if not openErroringFolder(self, tmi) then showStatus() end
                end
            end),
        },
        {
            text_func = function()
                if not self:binaryExists() then return _("Install Syncthing binary") end
                return self:isRunning() and _("Stop Syncthing") or _("Start Syncthing")
            end,
            help_text      = startstop_help,
            keep_menu_open = true,
            hold_callback  = D.helpHold(startstop_help),
            callback       = self.safe("Start/Stop", function(tmi)
                if not self:binaryExists() then
                    self:showFirstRunDialog(function()
                        self:_invalidateBinaryCache()
                        self:_cacheInvalidate()
                        if tmi then tmi:updateItems() end
                    end)
                else
                    self:onToggleSyncthingServer(function()
                        self:_cacheInvalidate()
                        if tmi then tmi:updateItems() end
                    end)
                end
            end),
        },
        {
            text_func = function()
                if self:isRunning() then
                    local h = self:getFolderHealth()
                    if h and h.errors > 0 and h.errors_fixable then return _("Fix errors") end
                    return _("Rescan all folders")
                end
                return _("Quick Sync")
            end,
            help_text      = quicksync_top_help,
            keep_menu_open = true,
            enabled_func   = D.enabled(self, "binaryExists"),
            hold_callback  = D.gatedHold(self, "binaryExists", quicksync_top_help),
			callback 	   = self.safe("Quick Sync", function(tmi)
				self:quickSync(function()
					if tmi then tmi:updateItems() end
				end)
			end),
        },
        {
            text_func = function()
                local h        = self:isRunning() and self:getFolderHealth() or nil
                local n_paused = h and h.paused or 0
                local n_total  = h and h.total  or 0
                if n_paused > 0 then
                    if n_paused == n_total then
                        return T(N_("Resume the folder", "Resume all %1 folders", n_total), n_total)
                    else
                        return T(N_("Resume %1 paused folder", "Resume %1 paused folders", n_paused), n_paused)
                    end
                end
                return n_total > 0
                    and T(N_("Pause the folder", "Pause all %1 folders", n_total), n_total)
                    or  _("Pause all folders")
            end,
            help_text      = pause_help,
            keep_menu_open = true,
            enabled_func   = D.enabled(self, "isRunning"),
            hold_callback  = D.gatedHold(self, "isRunning", pause_help),
			callback = self.safe("Pause toggle", function(tmi)
				local h       = self:isRunning() and self:getFolderHealth() or nil
				local paused  = h and h.paused or 0
				local do_pause = paused == 0
				self:setPauseAll(do_pause, function()
					if tmi then tmi:updateItems() end
				end)
			end),
        },
        {
            text_func = function()
                local n = self:isRunning() and #self:findConflicts() or 0
                if n > 0 then
                    return T(_("Status & conflicts (%1)"), n)
                end
                return _("Status & conflicts")
            end,
            help_text           = status_help,
            keep_menu_open      = true,
            hold_callback       = D.helpHold(status_help),
			sub_item_table_func = self.safe("Status menu", function(tmi)
				local menu = getStatusMenu(self, tmi)
				UIManager:nextTick(function()
					if tmi and tmi.updateItems then tmi:updateItems() end
				end)
				return menu
			end),
            separator = true,
        },
        {
            text                = _("Setup"),
            help_text           = setup_help,
            keep_menu_open      = true,
            hold_callback       = D.helpHold(setup_help),
            sub_item_table_func = self.safe("Setup menu", function() return getSetupMenu(self) end),
        },
        {
            text_func = function()
                local parts = {}
                if self.autostart_mode == "always" then
                    table.insert(parts, _("always"))
                elseif self.autostart_mode == "wifi" then
                    table.insert(parts, _("on Wi-Fi"))
                end
                if self.periodic_sync_enabled then table.insert(parts, _("periodic")) end
                return #parts > 0
                    and T(_("Automation: %1"), table.concat(parts, ", "))
                    or  _("Automation")
            end,
            help_text           = automation_help,
            keep_menu_open      = true,
            hold_callback       = D.helpHold(automation_help),
            sub_item_table_func = self.safe("Automation menu", function() return getAutomationMenu(self) end),
        },
        {
            text                = _("Maintenance"),
            help_text           = maintenance_help,
            keep_menu_open      = true,
            hold_callback       = D.helpHold(maintenance_help),
            sub_item_table_func = self.safe("Maintenance menu", function(tmi)
                return getMaintenanceMenu(self, tmi)
            end),
        },
    }

    menu_items.kosyncthing_plus = {
        text         = _("KOSyncthing+"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            -- Refresh the running-state belief so the menu reflects reality
            -- immediately (not only after the ≤5 s is_running cache TTL).
            self:reconcile("menu")
            if self:binaryExists()
                    and not self.gui_password
                    and not G_reader_settings:readSetting("syncthing_password_configured") then
                UIManager:scheduleIn(3, function()
                    self:_suggestPassword()
                end)
            end
            return syncthing_sub
        end,
    }
end

---------------------------------------------------------------------------
-- Module exports
-- showPasswordDialog and _suggestPassword live in st_settings.lua but are
-- re-exported here so that main.lua's mix-in loop doesn't need to change.
---------------------------------------------------------------------------
return {
    addToMainMenu       = addToMainMenu,
    getStatusMenu       = getStatusMenu,
    getSetupMenu        = getSetupMenu,
    getAutomationMenu   = getAutomationMenu,
    getMaintenanceMenu  = getMaintenanceMenu,
    getPendingMenu      = getPendingMenu,
    showPasswordDialog  = Settings.showPasswordDialog,
    _suggestPassword    = Settings._suggestPassword,
}
