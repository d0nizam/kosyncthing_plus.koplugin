-- st_sync.lua - Quick Sync flow, folder health aggregation, conflict scanning, pause/resume all folders
local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr  = require("ui/network/manager")
local logger      = require("logger")
local _           = require("syncthing_i18n").gettext
local N_          = require("syncthing_i18n").ngettext
local T           = require("ffi/util").template
local util        = require("util")
local Event 	  = require("ui/event")
local time        = require("ui/time")

local U              = require("st_utils")
local IgnoreRegistry = require("st_api_public").IgnoreRegistry
local Guard          = require("st_guard")

local function hasNetwork()
    local connected = type(NetworkMgr.isConnected) == "function"
        and NetworkMgr:isConnected()
    return connected or NetworkMgr:isOnline()
end

local FOLDER_CACHE_TTL = U.FOLDER_CACHE_TTL
-- In Android remote mode getFolderHealth's data comes over REST from the
-- companion app (slower than the local loopback daemon on Kindle/Kobo), so the
-- menu caches it a little longer there.  Actions invalidate the cache, so this
-- only delays externally-driven status changes.
local ANDROID_FOLDER_CACHE_TTL = 20

-- Forward declarations to avoid reference errors during definition
local _startQuickSync, _waitForIdle

local function getFolderHealth(self)
    if not self:isRunning() then return nil end
    local cached = self:_cacheGet("folder_health",
        self._android_mode and ANDROID_FOLDER_CACHE_TTL or FOLDER_CACHE_TTL)
    if cached ~= nil then return cached end

    local config  = self:getConfig() or {}
    local folders = config["folders"] or {}
    local syncing, errors, need_bytes, paused, total = 0, 0, 0, 0, 0
    local watch_errors = {}
    local errors_all_fixable = true

    local folder_states = {}

    for _, folder in pairs(folders) do
        total = total + 1
        local fid = folder["id"] or ""
        local st  = (fid ~= "") and (self:getFolderStatus(fid) or {}) or {}
        local is_paused = folder["paused"] == true
        if is_paused then
            paused = paused + 1
        elseif (st["needBytes"] or 0) > 0 then
            syncing    = syncing + 1
            need_bytes = need_bytes + (st["needBytes"] or 0)
        end
        local folder_errors = (st["errors"] or 0) > 0
        local err_texts, err_fixable = nil, false
        if folder_errors then
            errors = errors + 1
            -- Fetch the actual error strings so we can tell a transient,
            -- rescan-fixable error ("changed during …") apart from one that
            -- needs the user (permission denied, no space, marker missing, I/O).
            local fe   = self:getFolderErrors(fid)
            local list = (fe and fe["errors"]) or {}
            err_texts   = {}
            err_fixable = #list > 0
            for _, e in ipairs(list) do
                local msg = e["error"] or ""
                err_texts[#err_texts + 1] = msg
                if not U.isTransientFolderError(msg) then err_fixable = false end
            end
            if not err_fixable then errors_all_fixable = false end
        end
        if st["watchError"] and st["watchError"] ~= "" then
            table.insert(watch_errors, folder["label"] or fid)
        end
        -- Per-folder state snapshot stored alongside the aggregate.
        -- Used by getStatusMenu to show real state without extra API calls.
        folder_states[fid] = {
            state          = st["state"] or "unknown",
            need_bytes     = st["needBytes"] or 0,
            errors         = folder_errors,
            error_texts    = err_texts,
            errors_fixable = err_fixable,
            paused         = is_paused,
        }
    end

    return self:_cacheSet("folder_health", {
        syncing        = syncing,
        errors         = errors,
        errors_fixable = (errors > 0) and errors_all_fixable or false,
        need_bytes     = need_bytes,
        paused         = paused,
        total          = total,
        watch_errors   = watch_errors,
        folder_states  = folder_states,
    })
end

local function anyFolderPaused(self)
    if not self:isRunning() then return false end
    local cached = self:_cacheGet("any_paused", FOLDER_CACHE_TTL)
    if cached ~= nil then return cached end
    local h = getFolderHealth(self)
    return self:_cacheSet("any_paused", h ~= nil and h.paused > 0)
end

-- Cache TTLs for findConflicts
local CONFLICT_CACHE_TTL_NO_CONFLICTS = 600
local CONFLICT_CACHE_TTL_HAS_CONFLICTS = 60

local function findConflicts(self)
    local user_ttl = G_reader_settings:readSetting("syncthing_conflict_cache_ttl")
    local function cache_ttl(has_conflicts)
        local base = has_conflicts
            and CONFLICT_CACHE_TTL_HAS_CONFLICTS
            or  CONFLICT_CACHE_TTL_NO_CONFLICTS
        if user_ttl and user_ttl > base then return user_ttl end
        if base < 10 then return 10 end
        return base
    end

    local current_generation = IgnoreRegistry:getGeneration()
    local registry_changed   = (self._conflicts_registry_generation ~= current_generation)

    if registry_changed
            or (self._conflicts_short_ttl_until
                and time.to_s(time.now()) > self._conflicts_short_ttl_until) then
        -- Force a fresh scan.
    else
        local cached = self:_cacheGet("conflicts", cache_ttl(false))
        if cached ~= nil then return cached end
    end

    if not self:isRunning() then
        self._conflicts_registry_generation = current_generation
        return self:_cacheSet("conflicts", {})
    end

    local config  = self:getConfig() or {}
    local folders = config["folders"] or {}
    if not next(folders) then
        self._conflicts_registry_generation = current_generation
        return self:_cacheSet("conflicts", {})
    end

    local dir_set = {}
    for _, folder in pairs(folders) do
        local p = folder["path"]
        if p and util.pathExists(p) then dir_set[p] = true end
    end

    local conflicts, seen = {}, {}
    for synced_dir in pairs(dir_set) do
        -- Match BOTH conflict separators (".sync-conflict-" and
        -- "~sync-conflict-"); registered companion patterns are applied below
        -- as a de-mangling post-filter, so the find expression itself needs no
        -- `! -name` exclusions.
        local cmd = string.format(
            "find '%s' "
            .. "-type d -name '.stfolder' -prune "
            .. "-o -type f \\( -name '*.sync-conflict-*' -o -name '*~sync-conflict-*' \\) "
            .. "-print 2>/dev/null",
            U.shellEscape(synced_dir))
        local f = io.popen(cmd)
        if f then
            for line in f:lines() do
                if not seen[line] then
                    seen[line] = true
                    local base = line:match("([^/]+)$") or line
                    if not IgnoreRegistry:matchesConflictBasename(base) then
                        table.insert(conflicts, line)
                    end
                end
            end
            f:close()
        end
    end

    if #conflicts > 0 then
        self._conflicts_short_ttl_until = time.to_s(time.now()) + cache_ttl(true)
    else
        self._conflicts_short_ttl_until = nil
    end

    self._conflicts_registry_generation = current_generation

    if self._notifiers then self._notifiers.notifyConflictsChanged(conflicts) end

    local prev_count = self._last_notified_conflict_count
    local new_count  = #conflicts

    -- Notification only on new conflicts (transition 0 → N)
    if new_count > 0 and (prev_count == nil or prev_count == 0) then
        self:showNotification(T(N_("Sync conflict detected: %1 file", "Sync conflicts detected: %1 files", new_count), new_count), 5)
    end

    -- Broadcast only when the count changes
    if prev_count ~= new_count then
        self._last_notified_conflict_count = new_count
        UIManager:broadcastEvent(Event:new("SyncthingConflictDetected", conflicts))
    end

    return self:_cacheSet("conflicts", conflicts)
end

local function syncNow(self, on_ui_refresh, silent)
    local config = self:getConfig() or {}
    local requested, failed = 0, 0
    for _, folder in pairs(config["folders"] or {}) do
        if not folder["paused"] then
            local result = self:scanFolder(folder["id"] or "")
            if U.isOk(result) then
                requested = requested + 1
            else
                failed = failed + 1
            end
        end
    end
    self:_cacheInvalidate()
    self:_invalidateConflictCache()
    -- A sync can change which peers are connected; force a fresh device-
    -- connection read so the header refreshed below isn't stale.
    self._connections_cache_time = 0
	if not silent then
		if failed > 0 then
			self:showNotification(T(N_("Rescan: %1 folder scanned, %2 failed.", "Rescan: %1 folders scanned, %2 failed.", requested), requested, failed), 5)
		elseif requested > 0 then
			self:showNotification(T(N_("Rescan requested on %1 folder.", "Rescan requested on %1 folders.", requested), requested), 3)
		else
			self:showNotification(_("No active folders to rescan."), 3)
		end
	end
    if on_ui_refresh then on_ui_refresh() end
end
local LOW_DISK_THRESHOLD_BYTES = 100 * 1024 * 1024
local CRITICAL_DISK_THRESHOLD_BYTES = 50 * 1024 * 1024

local function _checkFreeSpaceForConfig(config, min_bytes)
	local seen_fs = {}
	local worst_path, worst_free
	local checked = 0

	for _, folder in pairs(config["folders"] or {}) do
		local p = folder["path"]
		if p and p ~= "" and not folder["paused"] then
			local mount_key = U.getMountPoint(p) or p:match("^(/[^/]+)") or p
			if not seen_fs[mount_key] then
				seen_fs[mount_key] = true
				local free = U.getFreeSpace(p)
                if free then
                    checked = checked + 1
                    if free < min_bytes
                       and (not worst_free or free < worst_free) then
                        worst_path = p
                        worst_free = free
                    end
                end
            end
        end
    end

    if worst_path then
        return false, { path = worst_path, free_bytes = worst_free }, checked
    end
    return true, nil, checked
end

-- Public quickSync: wraps _startQuickSync with seamless Wi‑Fi
local function quickSync(self, on_ui_refresh)
    if not self:binaryExists() then
        self:showFirstRunDialog()
        return
    end

    if self:isRunning() then
        self:syncNow(on_ui_refresh)
        return
    end

    local function do_sync()
        _startQuickSync(self, function()
            NetworkMgr:afterWifiAction()
        end, on_ui_refresh)
    end

    NetworkMgr:beforeWifiAction(do_sync)
end

-- Core of Quick Sync: starts Syncthing, scans, waits for idle, stops.
-- on_finish is called after everything is done (success, error, timeout).
-- on_ui_refresh is an optional zero-arg callback invoked at every point
-- where the caller's UI should redraw (e.g. menu label refresh).
_startQuickSync = function(self, on_finish, on_ui_refresh, opts)
    opts = opts or {}
    local silent = opts.silent == true
	
	local flow_id = (self._sync_flow_counter or 0) + 1
	self._sync_flow_counter = flow_id
	if not silent then
		self._active_flow_id = flow_id
	end
	
	
    local lease = Guard:acquire("quick_sync_runtime", {
        standby = true,
        wakelock = true,
    })
    logger.info("[Syncthing] Quick Sync started, acquired runtime lease.")

    local function releaseStartupWakelock(result)
        lease:release()
        logger.info("[Syncthing] Quick Sync ended, released runtime lease.")
        if on_finish then on_finish(result) end
    end

    local function finishAfterStop(result, after_fn)
        self:stop(function()
            if after_fn then after_fn() end
            releaseStartupWakelock(result)
        end, false, true)
    end

    self:start(function()
        if not self:isRunning() then
            if not silent then
                self:showNotification(_("Quick Sync: Could not start Syncthing."), 5)
            else
                self:showNotification(_("Periodic sync: Could not start Syncthing."), 5)
            end
            releaseStartupWakelock({ ok = false, reason = "start_failed" })
            return
        end
		if on_ui_refresh then on_ui_refresh() end

        local function _waitForApiThenScan(attempt)
            if not self:isRunning() then
                if not silent then
                    self:showNotification(_("Quick Sync: Syncthing stopped unexpectedly."), 5)
                else
                    self:showNotification(_("Periodic sync: Syncthing stopped unexpectedly."), 5)
                end
                releaseStartupWakelock({ ok = false, reason = "stopped_unexpectedly" })
                return
            end

            local config = self:getConfig()
            if config and config["folders"] then
                local space_ok, problem = _checkFreeSpaceForConfig(config, LOW_DISK_THRESHOLD_BYTES)
                if not space_ok then
                    if not silent then
                        self:showNotification(_("Quick Sync: Low disk space."), 5)
                    else
                        self:showNotification(_("Periodic sync aborted: Low disk space."), 5)
                    end
                    finishAfterStop({ ok = false, reason = "low_disk_space" })
                    return
                end

                local stats_before = self:getDeviceStats() or {}
                local sent_snap, recv_snap = 0, 0
                for _, ds in pairs(stats_before) do
                    sent_snap = sent_snap + (tonumber(ds.totalBytesSent) or 0)
                    recv_snap = recv_snap + (tonumber(ds.totalBytesReceived) or 0)
                end

                local count, failed = 0, 0
                for _, folder in pairs(config["folders"]) do
                    if not folder["paused"] then
                        local result = self:scanFolder(folder["id"] or "")
                        if U.isOk(result) then
                            count = count + 1
                        else
                            failed = failed + 1
                        end
                    end
                end
                if count == 0 then
                    if not silent then
                        if failed > 0 then
                            self:showNotification(_("Quick Sync: Could not request a folder scan."), 5)
                        else
                            self:showNotification(_("Quick Sync: No active folders to scan."), 5)
                        end
                    elseif failed > 0 then
                        self:showNotification(_("Periodic sync: Could not request a folder scan."), 5)
                    end
                    finishAfterStop({ ok = false, reason = "no_folders" })
                    return
                end
                if failed > 0 and not silent then
                    self:showNotification(T(N_("Quick Sync: %1 folder scan request failed.", "Quick Sync: %1 folder scan requests failed.", failed), failed), 5)
                end

                local prev_state = {
                    last_need_items = -1,
                    last_need_bytes = -1,
                    stale_ticks     = 0,
                    last_toast_at   = 0,
                    interval        = 5,
                    bytes_sent_snapshot = sent_snap,
                    bytes_recv_snapshot = recv_snap,
                }
				UIManager:scheduleIn(3, function()
					_waitForIdle(self, time.to_s(time.now()), on_ui_refresh, prev_state, on_finish, silent, flow_id, lease)
				end)
                return
            end

            if attempt >= 20 then
                if not silent then
                    self:showNotification(_("Quick Sync: Syncthing's API not responding."), 5)
                else
                    self:showNotification(_("Periodic sync: Syncthing's API not responding."), 5)
                end
                finishAfterStop({ ok = false, reason = "api_timeout" })
                return
            end
            UIManager:scheduleIn(0.5, function()
                _waitForApiThenScan(attempt + 1)
            end)
        end

        UIManager:nextTick(function()
            _waitForApiThenScan(1)
        end)
    end)
end

_waitForIdle = function(self, start_time, on_ui_refresh, prev_state, on_finish, silent, flow_id, lease)
    silent = silent == true
    prev_state = prev_state or {
        last_need_items = -1,
        last_need_bytes = -1,
        stale_ticks     = 0,
        last_toast_at   = 0,
        interval        = 5,
        -- Snapshot of cumulative device stats at first idle check
        bytes_sent_snapshot = nil,
        bytes_recv_snapshot = nil,
		last_space_check = nil,
    }

    -- Snapshot cumulative device stats on first entry.  Syncthing's
    -- stats/device returns lifetime totals; by subtracting the snapshot
    -- we show only what was transferred during this Quick Sync.
    -- The snapshot is taken in _waitForApiThenScan, just before db/scan.
    if prev_state.bytes_sent_snapshot == nil then
        local snap = self:getDeviceStats() or {}
        local sent_snap, recv_snap = 0, 0
        for _, ds in pairs(snap) do
            sent_snap = sent_snap + (tonumber(ds.totalBytesSent)     or 0)
            recv_snap = recv_snap + (tonumber(ds.totalBytesReceived) or 0)
        end
        prev_state.bytes_sent_snapshot = sent_snap
        prev_state.bytes_recv_snapshot = recv_snap
    end

    local function releaseWakelock(result)
        if self._active_flow_id == flow_id then
            self._last_sync_progress = nil
        end
        if lease then
            lease:release()
        else
            Guard:release("quick_sync_runtime")
        end
        logger.info("[Syncthing] Quick Sync ended, released runtime lease.")
        if on_finish then on_finish(result) end
    end

    local function finishWithoutStop(result)
        releaseWakelock(result)
    end

    local function finishAfterStop(result, after_fn)
        self:stop(function()
            if after_fn then after_fn() end
            releaseWakelock(result)
        end, false, true)
    end

    local elapsed = time.to_s(time.now()) - start_time
    local timeout = 1800
	if elapsed > timeout then
		if not silent then
			self:showNotification(_("Quick Sync timed out. Some files may not have been synced."), 5)
		else
			self:showNotification(_("Periodic sync timed out."), 5)
		end
		if self._active_flow_id == flow_id then
			self._last_sync_progress = nil
		end
		finishAfterStop({ ok = false, reason = "timeout" })
		return
	end

    if not self:isRunning() then
        if not silent then
            self:showNotification(_("Quick Sync: Syncthing stopped unexpectedly."), 5)
        else
            self:showNotification(_("Periodic sync: Syncthing stopped unexpectedly."), 5)
        end
        if self._active_flow_id == flow_id then
            self._last_sync_progress = nil
        end
        finishWithoutStop({ ok = false, reason = "stopped_unexpectedly" })
        return
    end

	if not hasNetwork() then
		if not silent then
			self:showNotification(_("Quick Sync stopped — network disconnected."), 5)
		else
			self:showNotification(_("Periodic sync: network disconnected."), 5)
		end
		if self._active_flow_id == flow_id then
			self._last_sync_progress = nil
		end
		finishAfterStop({ ok = false, reason = "wifi_disconnected" })
		return
	end

    local config = self:getConfig()
    if not config then
        UIManager:scheduleIn(2, function()
            _waitForIdle(self, start_time, on_ui_refresh, prev_state, on_finish, silent, flow_id, lease)
        end)
        return
    end

    if not prev_state.last_space_check or (time.to_s(time.now()) - prev_state.last_space_check) >= 30 then
        prev_state.last_space_check = time.to_s(time.now())
        local space_ok, problem = _checkFreeSpaceForConfig(config, CRITICAL_DISK_THRESHOLD_BYTES)
        if not space_ok then
            if not silent then
                UIManager:show(InfoMessage:new{
                    icon = "notice-warning",
                    text = T(_("Quick Sync aborted — disk almost full.\n\n"
                               .. "Folder \"%1\" is on a filesystem with only %2 free.\n\n"
                               .. "Free up space before trying again."),
                               problem.path,
                               util.getFriendlySize(problem.free_bytes)),
                    timeout = 5,
                })
            else
                self:showNotification(_("Periodic sync aborted: Disk almost full."), 5)
            end
            if self._active_flow_id == flow_id then
                self._last_sync_progress = nil
            end
            finishAfterStop({ ok = false, reason = "disk_almost_full" })
            return
        end
    end

    local need_items, need_bytes, folder_errors = 0, 0, 0
    local in_progress = false
    for _, folder in pairs(config["folders"] or {}) do
        local fid = folder["id"] or ""
        if fid ~= "" and not folder["paused"] then
            local st = self:getFolderStatus(fid) or {}
            local errors = tonumber(st["errors"]) or 0
            need_items = need_items + (tonumber(st["needTotalItems"]) or 0)
            need_bytes = need_bytes + (tonumber(st["needBytes"]) or 0)
            if errors > 0 or st["state"] == "error" then
                folder_errors = folder_errors + 1
            end
            if st["state"] ~= nil and st["state"] ~= "idle" and st["state"] ~= "error" then
                in_progress = true
            end
        end
    end

    -- Update Quick Sync progress for the smart header (manual sync only).
    if not silent and prev_state.bytes_sent_snapshot then
        local stats_now = self:getDeviceStats() or {}
        local sent_now, recv_now = 0, 0
        for _, ds in pairs(stats_now) do
            sent_now = sent_now + (tonumber(ds.totalBytesSent) or 0)
            recv_now = recv_now + (tonumber(ds.totalBytesReceived) or 0)
        end
        local transferred = (sent_now - prev_state.bytes_sent_snapshot)
                          + (recv_now - prev_state.bytes_recv_snapshot)
        local total_work = transferred + need_bytes
        local progress = total_work > 0 and (transferred / total_work) or 0
        local pct = math.floor(progress * 100)
        if self._active_flow_id == flow_id then
            self._last_sync_progress = {
                pct = pct,
                need_bytes = need_bytes,
            }
        end
    end

    local MIN_OBSERVE_SEC = 8

	if folder_errors > 0 and elapsed >= MIN_OBSERVE_SEC then
		if not silent then
			self:showNotification(T(N_("Quick Sync finished with %1 folder error.", "Quick Sync finished with %1 folder errors.", folder_errors), folder_errors), 5)
		else
			self:showNotification(_("Periodic sync finished with folder errors."), 5)
		end
		if self._active_flow_id == flow_id then
			self._last_sync_progress = nil
		end
		finishAfterStop({ ok = false, reason = "folder_errors" }, function()
			self:_invalidateFolders()
			if on_ui_refresh then on_ui_refresh() end
		end)
		return
	end

    if not in_progress and need_items == 0 and elapsed >= MIN_OBSERVE_SEC then
        local stats_after = self:getDeviceStats() or {}
        local bytes_sent_after = 0
        local bytes_recv_after = 0
        for _, ds in pairs(stats_after) do
            bytes_sent_after = bytes_sent_after + (tonumber(ds.totalBytesSent)     or 0)
            bytes_recv_after = bytes_recv_after + (tonumber(ds.totalBytesReceived) or 0)
        end
        -- Delta = current cumulative value minus the snapshot taken at start.
        -- Clamp to zero (should never go negative, but be safe).
        local sent = bytes_sent_after - prev_state.bytes_sent_snapshot
        local recv = bytes_recv_after - prev_state.bytes_recv_snapshot
        if sent < 0 then sent = 0 end
        if recv < 0 then recv = 0 end

        -- Build notification message
        local msg
        if sent > 0 or recv > 0 then
            msg = T(_("Sync done — ↑ %1 sent, ↓ %2 received"), util.getFriendlySize(sent), util.getFriendlySize(recv))
        else
            msg = _("Sync done — everything up to date")
        end

        if self._active_flow_id == flow_id then
            self._last_sync_progress = nil
        end
        finishAfterStop(
            { ok = true, reason = "synced", sent = sent, received = recv },
            function()
                self:_invalidateConflictCache()
                self:showNotification(msg, 5)
                UIManager:broadcastEvent(Event:new("SyncthingSyncCompleted", {
                    sent     = sent,
                    received = recv,
                    upToDate = (sent == 0 and recv == 0),
                }))
                if on_ui_refresh then on_ui_refresh() end
            end
        )
        return
    end

    local progressed = (need_items ~= prev_state.last_need_items)
                    or (need_bytes ~= prev_state.last_need_bytes)
    local new_state = {
        last_need_items = need_items,
        last_need_bytes = need_bytes,
        stale_ticks     = progressed and 0 or (prev_state.stale_ticks + 1),
        last_toast_at   = prev_state.last_toast_at,
        interval        = 2,
        bytes_sent_snapshot = prev_state.bytes_sent_snapshot, -- carry forward
        bytes_recv_snapshot = prev_state.bytes_recv_snapshot,
		last_space_check 	= prev_state.last_space_check,
    }
    if new_state.stale_ticks >= 3 then
        new_state.interval = 10
    end

    local now = time.to_s(time.now())
    -- Show progress only for manual Quick Sync (not periodic)
    if not silent and (progressed or (now - prev_state.last_toast_at) >= 30) then
        self:showNotification(T(N_("Syncing… %1 item (%2) remaining", "Syncing… %1 items (%2) remaining", need_items), need_items, util.getFriendlySize(need_bytes)), 3)
        new_state.last_toast_at = now
    end

    UIManager:scheduleIn(new_state.interval, function()
        _waitForIdle(self, start_time, on_ui_refresh, new_state, on_finish, silent, flow_id, lease)
    end)
end

local function setPauseAll(self, paused, on_ui_refresh)
    local folders = self:getFolders()
    if not folders then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Could not reach Syncthing.\n\nThe daemon may still be starting up — wait a moment and try again."),
        })
        return
    end

    if not next(folders) then
        UIManager:show(InfoMessage:new{
            text = _("No folders are configured yet.\n\nUse the Syncthing Web GUI to add folders before pausing or resuming."),
        })
        return
    end

    local count = 0
    local any_failed = false
    for _, folder in ipairs(folders) do
        local fid = folder.id or ""
        if fid ~= "" then
            local result = self:patchFolder(fid, { paused = paused })
            if U.isOk(result) then
                count = count + 1
            else
                any_failed = true
            end
        end
    end

    self:_cacheInvalidate()
	self:_invalidateConflictCache()

    if any_failed then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = paused
                and _("Pause request sent, but Syncthing did not confirm some folders.\n\nCheck the Web GUI to verify the folder state.")
                or  _("Resume request sent, but Syncthing did not confirm some folders.\n\nCheck the Web GUI to verify the folder state."),
        })
    else
        UIManager:show(InfoMessage:new{
            timeout = 3,
            text    = paused
                and T(N_("%1 folder paused.\n\nSyncthing will not transfer files until you resume it.", "All %1 folders paused.\n\nSyncthing will not transfer files until you resume them.", count), count)
                or  T(N_("%1 folder resumed.\n\nSyncthing will begin syncing shortly.", "All %1 folders resumed.\n\nSyncthing will begin syncing shortly.", count), count),
        })
    end

    if on_ui_refresh then on_ui_refresh() end
end

return {
    getFolderHealth   = getFolderHealth,
    anyFolderPaused   = anyFolderPaused,
    findConflicts     = findConflicts,
    syncNow           = syncNow,
    quickSync         = quickSync,
    setPauseAll       = setPauseAll,
    _startQuickSync   = _startQuickSync,
}
