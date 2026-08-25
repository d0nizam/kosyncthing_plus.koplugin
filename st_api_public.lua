-- st_api_public.lua — Public API for companion plugins
--
-- ## Why manual listeners instead of HookContainer?
--
-- HookContainer (ui/hook_container) is a general-purpose hook system
-- available in KOReader.  We deliberately keep a minimal custom listener
-- array inside buildPublicAPI() for three reasons:
--
--   1. Strong fault isolation.
--      We wrap every listener call in `pcall`.  A broken callback from a
--      companion plugin will never stop the remaining listeners from
--      running, and more importantly will never crash the Syncthing
--      plugin itself.  HookContainer does not provide automatic pcall
--      protection and would require the same wrapper to be safe.
--
--   2. No additional dependency.
--      The listener list and the two registration methods
--      (onStatusChange / offStatusChange) are a few lines of code with
--      zero module dependencies.  HookContainer would pull in an extra
--      module for functionality that is already fully covered.
--
-- This is a conscious design choice, not an oversight.
--
--
-- Provides three integration surfaces:
--   1. **IgnoreRegistry** – lets companion plugins exclude their own files'
--      conflict copies from the conflict scanner.  Each plugin may register
--   2. **_G.KOSyncthingPlusAPI** – global table (also available via
--      require("st_api_public").api) with status, control, info, events,
--      a proxied REST call, and utility functions.
--   3. **Proxied REST call** – `_G.KOSyncthingPlusAPI.apiCall(endpoint, method, body)`
--      lets companions talk to Syncthing without ever seeing the API key.
--
-- Full documentation, quick-start examples, and safety guarantees are in
-- the API.md file at the root of the repository.
--
-- ## Thread safety
--
-- KOReader is single‑threaded (LuaJIT).  All API calls are synchronous
-- and safe to invoke from any widget callback or timer.

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger      = require("logger")
local FS 		  = require("st_filesystem")
local util        = require("util")
local U           = require("st_utils")
local _rapidjson_ok, _rapidjson = pcall(require, "rapidjson")
local JSON = _rapidjson_ok and _rapidjson or require("json")

local API_VERSION = "1.1.1"
local REGISTRY_FILENAME = "kosyncthing_plus_ignore_registry.lua"
local REGISTRY_VERSION = 2

-- =========================================================================
--  IgnoreRegistry
-- =========================================================================
local IgnoreRegistry = {
    _store      = nil,
    _generation = 0,
}

local function _registry_path()
    local dir = DataStorage:getSettingsDir()
    if not dir then return nil end
    if dir:sub(-1) ~= "/" and dir:sub(-1) ~= "\\" then
        dir = dir .. "/"
    end
    return dir .. REGISTRY_FILENAME
end

local function _migrate(self, store)
    local v = store:readSetting("version") or 0
    if v >= REGISTRY_VERSION then return end

    if v < 1 then
        store:saveSetting("version", 1)
        store:flush()
        logger.info("[Syncthing] IgnoreRegistry: migrated to v1")
        v = 1
    end

    if v < 2 then
        -- v1 stored ONE pattern string per plugin; v2 stores a LIST.  Coerce
        -- any pre-v2 string value into a one-element list (drop malformed).
        local patterns = store:readSetting("patterns")
        if type(patterns) == "table" then
            local changed = false
            for id, val in pairs(patterns) do
                if type(val) == "string" then
                    patterns[id] = { val }; changed = true
                elseif type(val) ~= "table" then
                    patterns[id] = nil; changed = true
                end
            end
            if changed then store:saveSetting("patterns", patterns) end
        end
        store:saveSetting("version", 2)
        store:flush()
        logger.info("[Syncthing] IgnoreRegistry: migrated to v2 (per-plugin pattern lists)")
    end
end

local function _load(self)
    if self._store then return self._store end
    local path = _registry_path()
    if not path then
        logger.warn("[Syncthing] IgnoreRegistry: settings dir unavailable; "
                 .. "running with an in-memory store only.")
        self._store = LuaSettings:open("/tmp/kosyncthing_plus_ignore_registry.lua")
    else
        self._store = LuaSettings:open(path)
    end
	_migrate(self, self._store)
    return self._store
end

-- Compare two pattern lists for equality (order-sensitive).
local function _listEqual(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

-- Normalise the register() argument (a string or a list of strings) into a
-- de-duplicated list.  Returns the list, or nil + reason on the first invalid
-- entry: one bad pattern rejects the WHOLE call (all-or-nothing).
local function _normalizePatterns(patterns)
    if type(patterns) == "string" then patterns = { patterns } end
    if type(patterns) ~= "table" or #patterns == 0 then
        return nil, "patterns must be a non-empty string or list of strings"
    end
    local out, seen = {}, {}
    for _, p in ipairs(patterns) do
        if type(p) ~= "string" or p == "" then
            return nil, "list contains an empty or non-string pattern"
        end
        if not seen[p] then seen[p] = true; out[#out + 1] = p end
    end
    return out
end

-- register(plugin_id, patterns):
--   `patterns` may be a single glob string OR a list of glob strings.  The
--   call REPLACES the plugin's full pattern set (it does not append).  Each
--   glob is matched against the ORIGINAL basename; the registry matches a
--   conflict copy by de-mangling it first, so callers register plain names
--   (e.g. "state.lua", "*.sdr") without encoding the ".sync-conflict-…" form.
function IgnoreRegistry:register(plugin_id, patterns)
    if type(plugin_id) ~= "string" or plugin_id == "" then
        logger.warn("[Syncthing] IgnoreRegistry:register: invalid plugin_id")
        return false
    end
    local list, reason = _normalizePatterns(patterns)
    if not list then
        logger.warn("[Syncthing] IgnoreRegistry:register: " .. reason)
        return false
    end
    local store = _load(self)
    local all = store:readSetting("patterns") or {}
    if _listEqual(all[plugin_id], list) then
        return true  -- idempotent: identical set, no generation bump
    end
    all[plugin_id] = list
    store:saveSetting("patterns", all)
    store:flush()
    self._generation = self._generation + 1
    logger.info("[Syncthing] IgnoreRegistry: registered", plugin_id, "->",
                table.concat(list, ", "))
    return true
end

function IgnoreRegistry:unregister(plugin_id)
    if type(plugin_id) ~= "string" or plugin_id == "" then return false end
    local store = _load(self)
    local all = store:readSetting("patterns") or {}
    if all[plugin_id] == nil then return true end
    all[plugin_id] = nil
    store:saveSetting("patterns", all)
    store:flush()
    self._generation = self._generation + 1
    logger.info("[Syncthing] IgnoreRegistry: unregistered", plugin_id)
    return true
end

function IgnoreRegistry:isRegistered(plugin_id)
    if type(plugin_id) ~= "string" or plugin_id == "" then return false end
    local store = _load(self)
    local all = store:readSetting("patterns") or {}
    return all[plugin_id] ~= nil
end

-- Returns a copy of the registry: { plugin_id = { glob, glob, ... }, ... }.
function IgnoreRegistry:getAll()
    local store = _load(self)
    local all = store:readSetting("patterns") or {}
    local copy = {}
    for id, list in pairs(all) do
        if type(list) == "table" then
            local l = {}
            for i = 1, #list do l[i] = list[i] end
            copy[id] = l
        end
    end
    return copy
end

-- True if `basename` (a conflict-copy filename, e.g. "x.sync-conflict-….lua")
-- belongs to a registered companion: the name is de-mangled to its original
-- and matched against every registered glob.  Used by BOTH conflict scanners
-- (the Kindle/daemon find post-filter and the Android lfs scanner), so the
-- two paths share one matching rule.
function IgnoreRegistry:matchesConflictBasename(basename)
    if type(basename) ~= "string" or basename == "" then return false end
    -- Only genuine conflict copies are excludable.  Use the shared gate (the
    -- same "<sep>sync-conflict-" test the scanners apply) so a plain original
    -- name, or a user file that merely contains the substring without the
    -- "." / "~" separator, is never matched.
    if not U.isConflictBasename(basename) then return false end
    local store = _load(self)
    local all = store:readSetting("patterns") or {}
    if not next(all) then return false end
    local original = U.stripConflictInfix(basename)
    for _, list in pairs(all) do
        if type(list) == "table" then
            for _, glob in ipairs(list) do
                if type(glob) == "string" and glob ~= ""
                   and original:match(U.globToLuaPattern(glob)) then
                    return true
                end
            end
        end
    end
    return false
end

function IgnoreRegistry:getGeneration()
    return self._generation
end

function IgnoreRegistry.getApiVersion()
    return API_VERSION
end

-- =========================================================================
--  Public API builder (called once during plugin init)
-- =========================================================================
local function buildPublicAPI(self)
    local listeners = {}

    local function _notify(event_type, data)
        for _, cb in ipairs(listeners) do
            pcall(cb, event_type, data)
        end
    end
	
	-- Standard empty result for all conflict resolution strategies.
	-- All callers expect these five keys; never return a partial table.
	local function _emptyResult()
        return { kept_local = 0, kept_remote = 0, merged = 0, skipped = 0, failed = 0 }
    end

    _G.KOSyncthingPlusAPI = {
        version        = API_VERSION,
        IgnoreRegistry = IgnoreRegistry,

        status = {
            isRunning        = function() return self:isRunning() end,
            getConflicts     = function() return self:findConflicts() end,
            getFolderHealth  = function() return self:getFolderHealth() end,
            getStatusHeader  = function() return self:getStatusHeader() end,
            getDeviceId      = function() return self:getDeviceId() end,
            -- Periodic sync state
            isPeriodicSyncEnabled = function()
                return self.periodic_sync_enabled
            end,
            getPeriodicSyncInterval = function()
                return self.periodic_sync_interval_min
            end,
            getNextPeriodicSyncAt = function()
                return self._next_periodic_sync_at  -- os.time() epoch, or nil
            end,
        },

        control = {
            start            = function(callback) self:runManualStart(callback) end,
            stop             = function(callback) self:runManualStop(callback) end,
            quickSync        = function(on_complete) self:runQuickSync(nil, on_complete) end,
            toggle           = function(callback) self:runManualToggle(callback) end,
            pauseAllFolders  = function() self:setPauseAll(true, nil) end,
            resumeAllFolders = function() self:setPauseAll(false, nil) end,
            getDeviceId      = function() return self:getDeviceId() end,
            getConflicts     = function() return self:findConflicts() end,
			
            -- Conflict resolution helpers (programmatic, no UI)
            resolveAllConflicts = function(strategy)
                local conflicts = self:findConflicts()
				if #conflicts == 0 then
					return _emptyResult()
				end
					if strategy == "keep_local" then
						local result = _emptyResult()
						for _, cp in ipairs(conflicts) do
							local ok = FS.remove(cp)
							if ok then
								result.kept_local = result.kept_local + 1
							else
								result.failed = result.failed + 1
							end
						end
						if result.kept_local > 0 then
							self:_cacheInvalidate()
							self:_invalidateConflictCache()
							if self._notifiers then self._notifiers.notifyConflictsChanged(nil) end
						end
						return result
					elseif strategy == "use_remote" then
						local result = _emptyResult()
						for _, cp in ipairs(conflicts) do
							local orig = require("st_conflict").deriveOriginalPath(cp)
							if orig == cp then
								result.skipped = result.skipped + 1
							elseif FS.rename(cp, orig) then
								result.kept_remote = result.kept_remote + 1
							else
								result.failed = result.failed + 1
							end
						end
						if result.kept_remote > 0 then
							self:_cacheInvalidate()
							self:_invalidateConflictCache()
							if self._notifiers then self._notifiers.notifyConflictsChanged(nil) end
						end
						return result
                elseif strategy == "auto_merge" then
                    return self:autoMergeReadingProgress(conflicts)
                else
                    return nil, "Unknown strategy: " .. tostring(strategy)
                end
            end,

            resolveConflictByPath = function(path, strategy)
                local orig = require("st_conflict").deriveOriginalPath(path)
                if not orig or orig == path then
                    return nil, "Could not determine original path"
                end
				if strategy == "keep_local" then
					local ok, err = FS.remove(path)
					if not ok then return nil, err end
                    self:_cacheInvalidate()
                    self:_invalidateConflictCache()
                    if self._notifiers then self._notifiers.notifyConflictsChanged(nil) end
                    return true
				elseif strategy == "use_remote" then
					local ok, err = FS.rename(path, orig)
					if not ok then return nil, err end
					self:_cacheInvalidate()
					self:_invalidateConflictCache()
					if self._notifiers then self._notifiers.notifyConflictsChanged(nil) end
					return true
                else
                    return nil, "Unknown strategy: " .. tostring(strategy)
                end
            end,
			
			setFolderIgnore = function(folderId, patterns)
				if type(folderId) ~= "string" or folderId == "" then
					return nil, "Invalid folder ID"
				end
				if type(patterns) ~= "table" then
					return nil, "Patterns must be a table of strings"
				end
				local copy = {}
				for _, p in ipairs(patterns) do
					if type(p) ~= "string" then
						return nil, "Each ignore pattern must be a string"
					end
					table.insert(copy, p)
				end
				local result = self:setFolderIgnores(folderId, copy)
				if not U.isOk(result) then
					return nil, result.error or "Could not update folder ignore patterns"
				end
				return true
			end,

            -- Periodic sync management (programmatic control)
            setPeriodicSyncEnabled = function(enabled)
                if type(enabled) ~= "boolean" then
                    return nil, "Enabled must be a boolean"
                end
                self.periodic_sync_enabled = enabled
                G_reader_settings:saveSetting("syncthing_periodic_sync_enabled", enabled)
                if enabled then
                    self:_startPeriodicSyncTimer()
                else
                    self:_stopPeriodicSyncTimer()
                end
                return true
            end,

			setPeriodicSyncInterval = function(minutes)
				
				if type(minutes) ~= "number" then
					return nil, "Interval must be a number between 1 and 1440"
				end
				if math.floor(minutes) ~= minutes then
					return nil, "Interval must be a whole number (no decimals)"
				end
				if minutes < 1 or minutes > 1440 then
					return nil, "Interval must be a number between 1 and 1440"
				end
                self.periodic_sync_interval_min = minutes
                G_reader_settings:saveSetting("syncthing_periodic_sync_interval_min", minutes)
                if self.periodic_sync_enabled then
                    self:_stopPeriodicSyncTimer()
                    self:_startPeriodicSyncTimer()
                end
                return true
            end,

            runPeriodicSyncNow = function()
                if not self.periodic_sync_enabled then
                    return nil, "Periodic sync is not enabled"
                end
                self:runPeriodicSync()
                return true
            end,
        },

        -- Proxied Syncthing REST API call – companion plugins can talk
        -- to the daemon without ever seeing the API key.
        apiCall = function(endpoint, method, body)
            return self:apiCall(endpoint, method, body)
        end,

        -- Additional information about folders, devices, and configuration.
        info = {
            getFolders = function()
                local config = self:getConfig() or {}
                local folders = config["folders"] or {}
                local health = self:getFolderHealth()
                local result = {}
                for _, f in ipairs(folders) do
                    local fs = (health and health.folder_states and health.folder_states[f.id]) or {}
                    table.insert(result, {
                        id          = f.id,
                        label       = f.label or f.id,
                        path        = f.path,
                        paused      = f.paused or false,
                        needBytes   = fs.need_bytes or 0,
                        state       = fs.state or "unknown",
                        errors      = fs.errors or false,
                    })
                end
                return result
            end,

            getConflictsDetailed = function()
                return self:getConflictsDetailed()
            end,

			getFolderIgnore = function(folderId)
				if type(folderId) ~= "string" or folderId == "" then
					return nil, "Invalid folder ID"
				end
				local data = self:getFolderIgnores(folderId)
				if not data then
					return nil, "Could not read folder ignore patterns"
				end
				return data.ignore or {}
			end,

            getDevices = function()
                local config = self:getConfig() or {}
                local devices = config["devices"] or {}
                local conns = self:getConnections() or {}
                local connMap = conns.connections or {}
                local result = {}
                for _, d in ipairs(devices) do
                    local conn = connMap[d.deviceID] or {}
                    table.insert(result, {
                        id          = d.deviceID,
                        name        = d.name or d.deviceID,
                        paused      = d.paused or false,
                        connected   = conn.connected or false,
                        address     = conn.address,
                    })
                end
                return result
            end,

            getPendingDevices = function()
                return self:getPendingDevices() or {}
            end,

            getPendingFolders = function()
                return self:getPendingFolders() or {}
            end,

            getGUIPort         = function() return self.syncthing_port end,
            getResourceProfile = function() return self.resource_profile end,
            getNetworkAccess   = function() return self.network_access end,
        },

        onStatusChange = function(callback)
            if type(callback) == "function" then
                table.insert(listeners, callback)
            end
        end,
        offStatusChange = function(callback)
            for i = #listeners, 1, -1 do
                if listeners[i] == callback then
                    table.remove(listeners, i)
                    break
                end
            end
        end,

        util = {
            formatBytes     = U.formatBytes,
            formatTime      = U.formatTime,
            isValidDeviceID = U.isValidDeviceID,
        },
    }

    return {
        notifyProcessStarted   = function() _notify("process_started") end,
        notifyProcessStopped   = function() _notify("process_stopped") end,
        notifyConflictsChanged = function(conflicts) _notify("conflicts_changed", conflicts) end,
    }
end

-- =========================================================================
--  Module return – IgnoreRegistry + builder + the last built API table
-- =========================================================================
local PublicAPI = {
    IgnoreRegistry = IgnoreRegistry,
    buildPublicAPI = buildPublicAPI,
    api = nil,  -- set by buildPublicAPI
}

-- Wrap buildPublicAPI so it always updates PublicAPI.api
local _originalBuild = buildPublicAPI
PublicAPI.buildPublicAPI = function(self)
    local notifiers = _originalBuild(self)
    PublicAPI.api = _G.KOSyncthingPlusAPI
    return notifiers
end

return PublicAPI
