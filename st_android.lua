-- st_android.lua — Android remote mode for kosyncthing_plus.koplugin
--
-- On Kindle/Kobo the plugin owns a local Syncthing daemon (binary it manages).
-- On Android that is impossible (app sandbox): a separate Syncthing-Fork /
-- BasicSync app already runs the daemon and exposes the REST API on
-- 127.0.0.1.  This module makes the plugin a *remote-mode client* of that app.
--
-- Design:
--   * The proven raw-socket apiCall() in st_api.lua is NOT touched.  Instead
--     patchSyncthingObject() swaps self.apiCall for an Android implementation
--     built on ssl.https.request — the same high-level path Syncery uses and
--     has confirmed (200 OK) against a real BasicSync daemon.  The reason
--     apiCall avoids ssl.https (its global socketutil timeout) does not apply
--     on Android: the Android apiCall is the ONLY socket path there, so there
--     is no concurrent raw-socket call whose timeout it could clobber.
--   * The Android apiCall honours the EXACT return contract of the original
--     (decoded table | true | nil, and self:_addApiError on nil) so every
--     downstream caller — getFolders/getConflicts/status, and the public
--     _G.KOSyncthingPlusAPI (which delegates to self:apiCall) — is unchanged.
--   * findConflicts is replaced with an lfs scan: the normal path shells out
--     to `find`, which is not reliable in the Android sandbox, and the daemon
--     is the app's, not ours.  The conflict *list* feeds the same, unchanged
--     merge/resolution code.
--
-- Code/comments English; user-facing strings via syncthing_i18n.

local logger      = require("logger")
local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local Event       = require("ui/event")
local T           = require("ffi/util").template
local U           = require("st_utils")

-- lfs path differs on-device (KOReader bundles it as libs/libkoreader-lfs)
-- vs a plain luarocks "lfs" in the test sandbox.  Try both.
local _lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
if not _lfs_ok then lfs = require("lfs") end

-- JSON: rapidjson on-device; cjson in the test sandbox; never the phantom
-- "json" module (KOReader does not ship one).  decode is all we need.
local JSON
do
    local ok_r, r = pcall(require, "rapidjson")
    if ok_r then
        JSON = r
    else
        local ok_c, c = pcall(require, "cjson")
        if ok_c then JSON = c else JSON = { decode = function() return nil end } end
    end
end

local _ = require("syncthing_i18n").gettext
local N_ = require("syncthing_i18n").ngettext

-- IgnoreRegistry lets companion plugins (e.g. Syncery) exclude their own
-- conflict files from the badge.  The Kindle scanner passes these to `find`
-- as `! -name 'PATTERN'`; the Android lfs scanner must apply the same
-- exclusions or those files would be miscounted in remote mode.  Guarded so a
-- load-order or storage hiccup degrades to "no exclusions" rather than erroring.
local IgnoreRegistry
do
    local ok, mod = pcall(require, "st_api_public")
    if ok then IgnoreRegistry = mod.IgnoreRegistry end
end

local Android = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- §1  Constants
-- ─────────────────────────────────────────────────────────────────────────────

local DEFAULT_PORT          = "8384"
-- isRunning() is read on every menu render; in remote mode each probe is a REST
-- call to the companion app, so cache it long enough that quick re-opens are
-- instant (actions invalidate the cache, so post-action state stays fresh).
local IS_RUNNING_CACHE_TTL  = 10
-- Bounded timeouts.  These exist because a status probe sits on the menu hot
-- path: a slow/absent daemon must not freeze the UI for the LuaSec default
-- (60s).  Normal calls get a slightly larger budget than the status probe.
local CALL_BLOCK_TIMEOUT    = 4
local CALL_TOTAL_TIMEOUT    = 8
local PROBE_BLOCK_TIMEOUT   = 2
local PROBE_TOTAL_TIMEOUT   = 3
-- Guard the recursive conflict scan against symlink cycles.  Real sync trees
-- are never this deep.
local SCAN_MAX_DEPTH        = 20
-- findConflicts is called from the menu's text_func on every render; the lfs
-- walk must not run each time.  The original (st_sync) caches with a TTL +
-- IgnoreRegistry generation; we mirror the TTL part (the registry is normally
-- empty in remote mode).  Short enough that a just-resolved conflict clears
-- from the badge within a few seconds.
local CONFLICT_CACHE_TTL    = 8

-- ─────────────────────────────────────────────────────────────────────────────
-- §2  HTTP plumbing (request fn + timeout), kept injectable for tests
-- ─────────────────────────────────────────────────────────────────────────────

-- Resolve the LuaSocket/LuaSec request function for a scheme.
--   "https" -> ssl.https.request   (TLS; BasicSync + Syncthing-generated cert)
--   else    -> socket.http.request (plain)
-- Returns nil when the needed library is absent (fail-closed, see apiCall).
local function resolve_request_fn(scheme)
    if scheme == "https" then
        local ok, https = pcall(require, "ssl.https")
        if ok and https and https.request then return https.request end
        return nil
    end
    local ok, http = pcall(require, "socket.http")
    if ok and http and http.request then return http.request end
    return nil
end

-- Apply a bounded timeout for one request and return a restore function.
-- Uses KOReader's socketutil when present (the same mechanism Syncery uses);
-- a no-op restore otherwise.  Global, but on Android this is the only socket
-- path, so there is nothing else to disturb.
local function apply_timeout(block, total)
    local ok, socketutil = pcall(require, "socketutil")
    if ok and socketutil and socketutil.set_timeout then
        socketutil:set_timeout(block, total)
        return function()
            if socketutil.reset_timeout then socketutil:reset_timeout() end
        end
    end
    return function() end
end

-- ltn12-style sink/source as plain closures, so this module needs neither
-- ltn12 nor luasocket loaded to be unit-tested (the request fn is injected).
local function table_sink(t)
    return function(chunk) if chunk then t[#t + 1] = chunk end return 1 end
end
local function string_source(s)
    local done = false
    return function() if done then return nil end done = true; return s end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §3  androidApiCall — drop-in replacement honouring apiCall's exact contract
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Contract (verified against st_api.lua apiCall):
--   * 204                                  -> true
--   * 2xx, empty body                      -> true
--   * 2xx, body decodes to a table         -> the table
--   * 2xx, body decodes to a non-table     -> true
--   * 2xx, body fails to decode            -> nil   (matches original)
--   * non-2xx / transport failure          -> nil
--   * on nil: self:_addApiError{...}       (which itself honours
--                                           self._suppress_api_errors)
--
-- opts (internal only; the public self.apiCall wrapper never passes it):
--   opts.block_timeout / opts.total_timeout  override the defaults (probe).
--   opts.request_fn                          inject a fake (tests).
local function androidApiCall(self, api_path, method, body_str, opts)
    opts = opts or {}
    local api_key = self:getAPIKey()
    if not api_key then return nil end

    method = (method or "GET"):upper()
    local scheme = self._api_scheme or "https"
    local port   = tonumber(self.syncthing_port) or tonumber(DEFAULT_PORT)
    local url    = string.format("%s://127.0.0.1:%s/rest/%s", scheme, port, api_path)

    local chunks  = {}
    local headers = { ["X-API-Key"] = api_key }
    local source
    if body_str then
        headers["Content-Type"]   = "application/json"
        headers["Content-Length"] = tostring(#body_str)
        source = string_source(body_str)
    end

    local req = {
        url     = url,
        method  = method,
        headers = headers,
        sink    = table_sink(chunks),
        source  = source,
    }
    -- TLS posture for HTTPS: Syncthing uses a self-signed / self-generated
    -- cert by design; we authenticate with the API key, not the cert (the
    -- documented `curl -k` case).  socket.http ignores these on the http path.
    if scheme == "https" then
        req.protocol = "any"
        req.verify   = "none"
        req.options  = "all"
    end

    local request_fn = opts.request_fn or self._android_request_fn or resolve_request_fn(scheme)
    if not request_fn then
        -- Fail CLOSED and VISIBLY: the user sees a recorded error rather than a
        -- silent nothing.  Only reachable if LuaSec is missing from the build.
        self:_addApiError({
            path   = api_path,
            status = (scheme == "https")
                and "HTTPS requested but LuaSec (ssl.https) is unavailable"
                or  "socket.http unavailable",
            time   = os.time(),
        })
        return nil
    end

    local restore = apply_timeout(
        opts.block_timeout or CALL_BLOCK_TIMEOUT,
        opts.total_timeout or CALL_TOTAL_TIMEOUT)
    local ok, r1, code, _resp_headers, status = pcall(request_fn, req)
    restore()

    local result      = nil
    local last_status = nil
    local last_body   = nil

    if not ok then
        last_status = "request error: " .. tostring(r1)
    elseif r1 == nil then
        -- LuaSocket generic form returns (nil, err) on transport failure.
        last_status = "request failed: " .. tostring(code)
    else
        -- success path: r1 == 1, code == numeric HTTP status
        local status_code = tonumber(code)
        last_body   = table.concat(chunks)
        last_status = status and tostring(status) or ("HTTP " .. tostring(code))
        local function is_2xx()
            return status_code and status_code >= 200 and status_code < 300
        end
        if status_code == 204 then
            result = true
        elseif is_2xx() then
            if last_body == "" then
                result = true
            else
                local ok_decode, decoded = pcall(JSON.decode, last_body)
                if ok_decode and type(decoded) == "table" then
                    result = decoded
                elseif ok_decode then
                    result = true
                end
                -- decode failure on 2xx -> result stays nil (matches original)
            end
        end
        -- non-2xx -> result stays nil
    end

    if result == nil then
        self:_addApiError({
            path   = api_path,
            status = last_status or "no response",
            body   = last_body,
            time   = os.time(),
        })
    end
    return result
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §4  Silent connectivity probe
-- ─────────────────────────────────────────────────────────────────────────────
-- GET /rest/system/ping with the current key/port/scheme.  Suppresses the
-- error ring (we probe speculatively) and uses the short probe budget.
-- Uses androidApiCall directly so it works regardless of whether
-- patchSyncthingObject() has already swapped self.apiCall.
local function probe(self)
    local saved = self._suppress_api_errors
    self._suppress_api_errors = true
    local r = androidApiCall(self, "system/ping", "GET", nil, {
        block_timeout = PROBE_BLOCK_TIMEOUT,
        total_timeout = PROBE_TOTAL_TIMEOUT,
    })
    self._suppress_api_errors = saved
    return r ~= nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §5  lfs-based conflict scanner
-- ─────────────────────────────────────────────────────────────────────────────

-- True if `name` (a conflict-copy basename) is excluded by a registered
-- companion pattern.  Delegates to the IgnoreRegistry de-mangle matcher so the
-- Android lfs scanner and the Kindle/daemon find post-filter share ONE rule.
-- Test-injectable via `self._android_excluded_fn`.
local function isExcludedConflict(self, name)
    if self._android_excluded_fn then return self._android_excluded_fn(name) end
    if not IgnoreRegistry or not IgnoreRegistry.matchesConflictBasename then
        return false
    end
    local ok, hit = pcall(function() return IgnoreRegistry:matchesConflictBasename(name) end)
    return (ok and hit) or false
end
local function get_generation(self)
    if not IgnoreRegistry then return 0 end
    local ok, g = pcall(function() return IgnoreRegistry:getGeneration() end)
    return (ok and g) or 0
end

-- Recursively collect files matching Syncthing's conflict pattern
-- (*.sync-conflict-*).  Skips dot-directories (.stfolder/.stversions/etc.),
-- skips names matching a companion exclusion (parity with `find ! -name`),
-- and bounds depth against symlink cycles.
local function scanForConflicts(self, dir, results, depth)
    depth = depth or 0
    if depth > SCAN_MAX_DEPTH then return end

    local attr = lfs.attributes(dir)
    if not attr or attr.mode ~= "directory" then return end

    -- lfs.dir raises on unreadable dirs; never let one bad folder abort the scan.
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok then return end
    for entry in iter, dir_obj do
        if entry ~= "." and entry ~= ".." then
            local path = dir .. "/" .. entry
            local a    = lfs.attributes(path)
            if a then
                if a.mode == "directory" then
                    if entry:sub(1, 1) ~= "." then
                        scanForConflicts(self, path, results, depth + 1)
                    end
                elseif a.mode == "file" then
                    if U.isConflictBasename(entry)
                        and not isExcludedConflict(self, entry) then
                        results[#results + 1] = path
                    end
                end
            end
        end
    end
end

-- Public: list conflict-file paths across all configured folders.
-- TTL-cached (see CONFLICT_CACHE_TTL): the menu calls this on every render.
-- The cache also keys on the IgnoreRegistry generation, so a companion
-- registering/removing a pattern invalidates it immediately (parity with the
-- Kindle scanner's generation tracking).
function Android.findConflictsLfs(self)
    local now = os.time()
    local gen = get_generation(self)
    if self._android_conflicts_cache
        and self._android_conflicts_cache_gen == gen
        and (now - (self._android_conflicts_cache_at or 0)) < CONFLICT_CACHE_TTL then
        return self._android_conflicts_cache
    end
    local folders = self:getFolders() or {}
    local results = {}
    for _, f in ipairs(folders) do
        if type(f.path) == "string" and f.path ~= "" then
            scanForConflicts(self, f.path, results, 0)
        end
    end
    self._android_conflicts_cache     = results
    self._android_conflicts_cache_at  = now
    self._android_conflicts_cache_gen = gen

    -- Mirror the daemon-path findConflicts (st_sync.lua) so Android gets the
    -- same user notification and SyncthingConflictDetected event for companion
    -- plugins.  The lfs scanner replaces st_sync's findConflicts on Android, so
    -- without this the 0->N notification and the broadcast never fire here.
    -- Runs on the scan path only (cache hits return early above), and the
    -- 0->N transition guard prevents repeat notifications on every re-scan.
    if self._notifiers then self._notifiers.notifyConflictsChanged(results) end

    local prev_count = self._last_notified_conflict_count
    local new_count  = #results
    if new_count > 0 and (prev_count == nil or prev_count == 0) then
        self:showNotification(T(N_("Sync conflict detected: %1 file", "Sync conflicts detected: %1 files", new_count), new_count), 5)
    end
    if prev_count ~= new_count then
        self._last_notified_conflict_count = new_count
        UIManager:broadcastEvent(Event:new("SyncthingConflictDetected", results))
    end

    return results
end

-- Drop the conflict cache so the next findConflicts re-scans immediately
-- (used after a resolve/merge so the badge updates without waiting for TTL).
function Android.invalidateConflictsCache(self)
    self._android_conflicts_cache    = nil
    self._android_conflicts_cache_at = 0
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §6  API-key dialog (used by the menu, NOT by init)
-- ─────────────────────────────────────────────────────────────────────────────
-- Shown only from a menu callback, i.e. inside the running event loop — never
-- synchronously during init() (UIManager:show does not block, so an init-time
-- dialog cannot return an answer in time).  Calls cb(key, port) on Connect,
-- cb(nil) on cancel.
local function showApiKeyDialog(self, cb)
    local saved_key  = G_reader_settings:readSetting("syncthing_android_apikey") or ""
    local saved_port = G_reader_settings:readSetting("syncthing_android_port") or DEFAULT_PORT
    local dialog
    dialog = MultiInputDialog:new{
        title  = _("Connect to Syncthing app"),
        fields = {
            {
                text        = saved_key,
                hint        = _("Paste the Syncthing API key"),
                description = _(
                    "Open the Syncthing app, then Settings (or the Web GUI at "
                    .. "127.0.0.1:8384) and copy the API Key."),
            },
            {
                text        = tostring(saved_port),
                hint        = _("Port (default 8384)"),
                input_type  = "number",
                description = _("Change this only if you set a non-default Web GUI port in the Syncthing app."),
            },
        },
        buttons = {{
            {
                text = _("Cancel"),
                id   = "close",
                callback = function() UIManager:close(dialog); cb(nil) end,
            },
            {
                text = _("Connect"),
                is_enter_default = true,
                callback = function()
                    local fields = dialog:getFields()
                    local key    = fields[1]
                    local port   = tostring(fields[2] or ""):gsub("%s+", "")
                    if not key or key == "" then
                        UIManager:close(dialog)
                        cb(nil)
                        return
                    end
                    if port == "" then port = DEFAULT_PORT end
                    local pnum = tonumber(port)
                    if not pnum or pnum < 1024 or pnum > 65535 then
                        -- Keep the dialog open so the user can correct the port.
                        UIManager:show(InfoMessage:new{
                            text    = _("Port must be a number between 1024 and 65535."),
                            timeout = 3,
                        })
                        return
                    end
                    UIManager:close(dialog)
                    cb(key, tostring(pnum))
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Probe a candidate (key, port): https first, then http.  Mutates only the
-- in-memory self fields (no persistent settings) and restores them; safe
-- because KOReader is single-threaded so nothing else calls apiCall mid-probe.
-- `preferred` (a previously-working scheme) is tried first; this is what makes
-- the http-vs-https default question a one-time cost — after the first success
-- the scheme is persisted and tried directly.  Returns the scheme or nil.
local function probe_candidate(self, key, port, preferred)
    local old_key, old_port, old_scheme = self.api_key, self.syncthing_port, self._api_scheme
    self.api_key        = key
    self.syncthing_port = port or DEFAULT_PORT
    local order = (preferred == "http") and { "http", "https" } or { "https", "http" }
    local found
    for _, sch in ipairs(order) do
        self._api_scheme = sch
        if probe(self) then found = sch; break end
    end
    if not found then
        self.api_key, self.syncthing_port, self._api_scheme = old_key, old_port, old_scheme
    end
    return found
end

-- Public menu item: re-enter / change the connection (key + scheme).
function Android.connectionSettingsMenuItem(self)
    return {
        id        = "android_connection_settings",
        text      = _("Connection settings…"),
        help_text = _("Set the Syncthing API key used to reach the app's REST API."),
        keep_menu_open = true,
        callback  = function(tmi)
            showApiKeyDialog(self, function(key, port)
                if not key then return end
                local preferred = G_reader_settings:readSetting("syncthing_android_scheme")
                local scheme = probe_candidate(self, key, port, preferred)
                if scheme then
                    G_reader_settings:saveSetting("syncthing_android_apikey", key)
                    G_reader_settings:saveSetting("syncthing_android_port", self.syncthing_port)
                    G_reader_settings:saveSetting("syncthing_android_scheme", scheme)
                    if not self._android_mode then Android.patchSyncthingObject(self) end
                    self._android_unavailable = false
                    self._android_is_running_cache = nil
                    Android.invalidateConflictsCache(self)
                    if self._cacheInvalidate then self:_cacheInvalidate() end
                    UIManager:show(InfoMessage:new{ text = _("Connected."), timeout = 2 })
                    if tmi and tmi.updateItems then tmi:updateItems() end
                else
                    UIManager:show(InfoMessage:new{
                        text = _("Could not connect. Check the key and that the app is running."),
                        timeout = 4,
                    })
                end
            end)
        end,
    }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §7  patchSyncthingObject — swap daemon-management methods for remote ones
-- ─────────────────────────────────────────────────────────────────────────────
function Android.patchSyncthingObject(self)
    self._android_mode = true
    self._api_scheme   = self._api_scheme or "https"
    self._android_is_running_cache    = nil
    self._android_is_running_cache_at = 0

    -- The whole point: route every REST call through the TLS-capable Android
    -- implementation.  The public API delegates to self:apiCall, so companions
    -- (Syncery) transparently use this too.
    self.apiCall = function(plugin, path, method, body)
        return androidApiCall(plugin, path, method, body)
    end

    -- The daemon belongs to the Android app; we can neither start nor stop it.
    self.start = function(plugin, callback, ...)
        plugin._starting = false
        if not plugin._silentStart then
            UIManager:show(InfoMessage:new{
                text    = _("Syncthing is managed by the Syncthing app.\nOpen it to start syncing."),
                timeout = 4,
            })
        end
        plugin._silentStart = false
        if callback then callback() end
    end

    self.stop = function(plugin, callback, is_suspend, is_silent, ...)
        plugin._stopping = false
        if not is_silent then
            UIManager:show(InfoMessage:new{
                text    = _("Syncthing is managed by the Syncthing app."),
                timeout = 3,
            })
        end
        if callback then callback() end
    end

    -- Status indicator.  Hot path (menu renders): return the cached value
    -- immediately when fresh; otherwise do ONE bounded probe (≤ PROBE_TOTAL).
    -- A fully non-blocking design would need async networking KOReader does not
    -- expose; the short timeout + TTL keeps the worst case small.
    self.isRunning = function(plugin)
        local now = os.time()
        local cached = plugin._android_is_running_cache
        if cached ~= nil and (now - (plugin._android_is_running_cache_at or 0)) < IS_RUNNING_CACHE_TTL then
            return cached
        end
        local r = probe(plugin)
        plugin._android_is_running_cache    = r
        plugin._android_is_running_cache_at = now
        if plugin._cacheSet then plugin:_cacheSet("is_running", r) end
        return r
    end

    -- No local binary / PID / config dir on Android.
    self.binaryExists  = function() return true end
    self.getPid        = function() return nil end

    -- Read the key from settings (no config.xml exists on Android).
    self.getAPIKey = function(plugin)
        if plugin.api_key and plugin.api_key ~= "" then return plugin.api_key end
        local k = G_reader_settings:readSetting("syncthing_android_apikey")
        if k and k ~= "" then plugin.api_key = k; return k end
        return nil
    end

    -- `find` is unreliable in the sandbox; scan with lfs instead.
    self.findConflicts = function(plugin) return Android.findConflictsLfs(plugin) end

    logger.info("[Syncthing] Android remote mode active (scheme=" .. tostring(self._api_scheme) .. ")")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §8  init / isEnabled
-- ─────────────────────────────────────────────────────────────────────────────
-- Called from main.lua's Android branch.  Tries the saved key (https→http).
-- On success: patches and returns true.  On no-saved-key or failed probe:
-- returns false WITHOUT showing a dialog — the menu's "connect" row drives
-- first-run setup inside the event loop (see connectionSettingsMenuItem).
function Android.init(self)
    local saved_key    = G_reader_settings:readSetting("syncthing_android_apikey")
    local saved_port   = G_reader_settings:readSetting("syncthing_android_port") or DEFAULT_PORT
    local saved_scheme = G_reader_settings:readSetting("syncthing_android_scheme")  -- nil on first run
    if not (saved_key and saved_key ~= "") then
        return false
    end
    local scheme = probe_candidate(self, saved_key, saved_port, saved_scheme)
    if scheme then
        G_reader_settings:saveSetting("syncthing_android_scheme", scheme)
        Android.patchSyncthingObject(self)
        return true
    end
    -- Saved key present but the app is not reachable right now (e.g. not
    -- started yet).  Stay inactive; the menu offers a retry.
    self.api_key        = saved_key
    self.syncthing_port = saved_port
    return false
end

function Android.isEnabled(self)
    return self._android_mode == true
end

-- Expose internals for the test harness (executable differential).
Android._androidApiCall   = androidApiCall
Android._scanForConflicts = scanForConflicts
Android._probe            = probe

return Android
