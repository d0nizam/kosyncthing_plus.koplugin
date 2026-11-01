-- st_api.lua -	Low‑level REST API client (manual TCP with wall‑clock budget, rapidjson fallback)
local DataStorage = require("datastorage")
local socket      = require("socket")
local logger      = require("logger")
local util        = require("util")
local time 		  = require("ui/time")
local U           = require("st_utils")

-- Use rapidjson if available (2-3x faster), fallback to pure Lua JSON
local rapidjson_ok, rapidjson = pcall(require, "rapidjson")
local JSON = rapidjson_ok and rapidjson or require("json")

-- Config and device-ID paths are computed at call time so reset/migration
-- operations cannot leave this module holding stale path state.

local _cached_device_id = nil

-- Per-chunk timeout: any single socket read or write blocks at most this long.
-- LuaSocket settimeout applies per-operation, not per-request.
local API_TIMEOUT = 1.5

-- Total wall-clock budget for the entire request (connect + send + read all).
-- Without this cap, a slow-drip server could keep us blocked for many seconds
-- without any single chunk tripping API_TIMEOUT — bad on a synchronous UI
-- thread.  5 seconds is generous for localhost calls.
local API_TOTAL_BUDGET_SEC = 5

-- ## Why manual TCP instead of socketutil?
--
-- socketutil (set_timeout / file_sink) is the recommended KOReader module for
-- HTTP requests to *external* servers -- it is used in st_update.lua for
-- downloads from GitHub.  For the local Syncthing REST API on 127.0.0.1 we
-- deliberately keep a hand-rolled TCP implementation for three reasons:
--
--   1. Predictable wall-clock budget.
--      socketutil.set_timeout resets its counter between chunks, which means
--      a slow-drip daemon could keep the UI thread blocked far longer than
--      expected.  Our over_budget() guard checks elapsed time on every
--      socket operation and aborts the entire request after
--      API_TOTAL_BUDGET_SEC seconds, no matter how small the chunks are.
--
--   2. Fine-grained partial-body handling.
--      tcp:receive() returns (nil, "timeout", partial_data).  We stitch
--      partial_data into last_body so that even a truncated response can
--      be inspected in the "View last API error" debug menu.
--      socketutil.file_sink simply signals a timeout error and discards
--      whatever arrived.
--
--   3. Zero global side-effects.
--      socketutil.set_timeout affects all subsequent LuaSocket operations
--      until reset_timeout() is called.  The local API is called frequently
--      from menu renders and background polling; keeping it self-contained
--      avoids accidental interference with other parts of KOReader that may
--      be using LuaSocket concurrently.
--
-- This is a conscious design choice, not an oversight.

local function getAPIKey(self)
    if self.api_key then return self.api_key end
    -- Compute the config path at call time rather than caching path state at
    -- module load.
    local cfg_path = U.getConfigDir() .. "/config.xml"
    local f = io.open(cfg_path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    if not content then return nil end
    local key = content:match("<apikey>%s*(.-)%s*</apikey>")
    -- Treat an empty <apikey></apikey> the same as a missing element.
    -- match() returns "" on an empty capture, which is truthy in Lua —
    -- without this check the empty key would propagate and every API
    -- request would 401, with the failure surfaced only in
    -- _last_api_error rather than being clearly diagnosable here.
    if not key or key == "" then return nil end
    self.api_key = key
    return self.api_key
end

local function getDeviceId(self)
    if _cached_device_id then return _cached_device_id end
    -- Same rationale as getAPIKey: compute the path at call time.
    local dev_id_path = U.getConfigDir() .. "/device-id"
    local f = io.open(dev_id_path, "r")
    if f then
        local line = f:read("*l")
        f:close()
        local did = line and line:match("^%s*(.-)%s*$")
        -- Trust the cache only when it holds a syntactically valid device ID.
        -- A non-empty but malformed value (truncated file, partial write,
        -- on-disk corruption) was previously accepted as-is (AD-16); now it is
        -- ignored and we fall through to the authoritative REST API below,
        -- which also rewrites the cache file with a correct value.
        if did and did ~= "" and U.isValidDeviceID(did) then
            _cached_device_id = did
            return did
        end
    end

    if not self:isRunning() then return nil end
    local status = self:apiCall("system/status")
    if status and status.myID then
        local dir = U.getConfigDir()
        if not util.pathExists(dir) then
            util.makePath(dir)
        end
        f = io.open(dev_id_path, "w")
        if f then
            -- io.write can fail on full filesystems; if it does we still
            -- want the in-memory cache so the user can read their device
            -- ID, but we don't want to leave a truncated or empty file
            -- on disk that the read path above would later trust.
            local ok_w = pcall(function()
                f:write(status.myID .. "\n")
            end)
			pcall(function() f:close() end)
            if not ok_w then
                -- best effort: remove any partial file
                pcall(os.remove, dev_id_path)
            end
        end
        _cached_device_id = status.myID
        return status.myID
    end
    return nil
end

local function apiCall(self, api_path, method, body_str)
    local api_key = self:getAPIKey()
    if not api_key then return nil end

    method = method or "GET"
    local tcp = socket.tcp()
    tcp:settimeout(API_TIMEOUT)

    -- Wall-clock guard: even if no individual read trips API_TIMEOUT, refuse
    -- to spend more than API_TOTAL_BUDGET_SEC on this entire call.  This
    -- closes a gap where a slow-drip server (or one that keeps the
    -- connection open while sending data byte-by-byte) could block the UI
    -- for far longer than API_TIMEOUT suggests.
    local started = time.now()
    local function over_budget()
        return time.to_s(time.now() - started) > API_TOTAL_BUDGET_SEC
    end

    local result = nil
    local last_status = nil
    local last_body = nil
    local ok, err = pcall(function()
        local port = tonumber(self.syncthing_port)
        if not tcp:connect("127.0.0.1", port) then
            last_status = string.format("connect failed (127.0.0.1:%s)", port)
            return
        end

        local req = string.format(
            "%s /rest/%s HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\nX-API-Key: %s\r\n",
            method, api_path, api_key)

        if body_str then
            req = req .. string.format(
                "Content-Type: application/json\r\nContent-Length: %d\r\n\r\n%s",
                #body_str, body_str)
        else
            req = req .. "\r\n"
        end

        -- Check send success; if it fails, abort with diagnostic
        local sent, send_err = tcp:send(req)
        if not sent then
            last_status = "send failed: " .. tostring(send_err)
            return
        end

        if over_budget() then last_status = "timeout (send)"; return end

        -- Read status line.
        local status_line = tcp:receive("*l")
        if not status_line then
            last_status = "no response"
            return
        end
        last_status = status_line
        -- Parse the numeric status code once.  We need it again below to
        -- decide whether an empty/zero-length body should be treated as
        -- success.  Syncthing v2 returns "HTTP/1.0 200 OK\r\nContent-Length: 0"
        -- for most write endpoints (PATCH config/folders/{id}, PATCH
        -- config/devices/{id}, PATCH config/options, POST db/scan, POST
        -- system/pause, etc.) — see the REST API docs: "Returns status 200
        -- and no content upon success".  Treating only 204 as empty-body
        -- success caused every config-mutation PATCH to be reported as
        -- failure even though Syncthing applied it.
        local status_code = tonumber(status_line:match("^HTTP/1%.[01]%s+(%d+)"))
        if status_code == 204 then
            result = true
            return
        end
        if over_budget() then last_status = "timeout (after status)"; return end

        -- Read headers.
        local content_length = nil
        while true do
            local line = tcp:receive("*l")
            -- HTTP/1.1 headers end with a blank line (CRLF).  LuaSocket's
            -- receive("*l") strips the trailing \n but leaves \r intact, so
            -- the empty separator line arrives as "\r", not "".  We must
            -- check both to avoid reading the response body as a header line.
            if not line or line == "" or line == "\r" then break end
            local key, val = line:match("^(.-):%s*(.-)$")
            if key and key:lower() == "content-length" then
                content_length = tonumber(val)
            end
            if over_budget() then last_status = "timeout (headers)"; return end
        end

        if over_budget() then last_status = "timeout (before body)"; return end

        -- 2xx with declared zero-length body is success (Syncthing v2 path).
        if status_code and status_code >= 200 and status_code < 300
                and content_length == 0 then
            result = true
            return
        end

        -- Read body.  The Content-Length path is the fast path and almost
        -- always taken.  The "*a" path is the fallback for HTTP/1.0
        -- close-delimited responses (Go's net/http uses this when serving
        -- HTTP/1.0 clients without a precomputed length).
        local function _is_2xx() return status_code and status_code >= 200 and status_code < 300 end
        if content_length then
            local body, err, partial = tcp:receive(content_length)
            body = body or partial
            if body then
                last_body = body
                if body == "" then
                    -- Belt-and-suspenders for the case above (some servers
                    -- send Content-Length: 0 in unusual ways): an empty
                    -- body on a 2xx is success, on anything else stays nil.
                    if _is_2xx() then result = true end
                else
					if _is_2xx() then
						local ok_decode, decoded = pcall(JSON.decode, body)
						if ok_decode then
							if type(decoded) == "table" then
								result = decoded
							else
								result = true
							end
						end
					end
                end
			end					
        else
            local body, err, partial = tcp:receive("*a")
            body = body or partial
            -- A slow-drip server could keep this path alive indefinitely by
            -- sending one byte just inside each 1.5 s per-chunk timeout.  The
            -- wall-clock guard catches that; every other receive stage already
            -- checks it, this branch did not (BUG-24).  In practice Syncthing
            -- on 127.0.0.1 always sends Content-Length, so this is defence in
            -- depth rather than a hot path.
            if over_budget() then last_status = "timeout (body, no CL)"; return end
            if body and body ~= "" then
                last_body = body
				local ok_decode, decoded = pcall(JSON.decode, body)
				if _is_2xx() then
					if ok_decode and type(decoded) == "table" then
						result = decoded
					elseif ok_decode then
						result = true
					end
				end
            elseif _is_2xx() then
                result = true
            end
        end
    end)

    if not ok then
        logger.err("[Syncthing] API call error: " .. tostring(err))
    end

    pcall(function() tcp:close() end)

    -- Record the error only when it is actionable — i.e. the daemon is
    -- supposed to be running but something went wrong at the HTTP level.
    -- A plain "connect failed" while the daemon is stopped or starting is
    -- expected and would only confuse inexperienced users who see the
    -- "API errors" badge light up for no apparent reason.
    if result == nil then
        local is_connect_fail = last_status and last_status:find("connect failed", 1, true)
        local cached_running  = self._cacheGet and self:_cacheGet("is_running")
        local daemon_down     = self._starting or self._stopping
                                or (cached_running == false)
        if not (is_connect_fail and daemon_down) then
            self:_addApiError({
                path   = api_path,
                status = last_status or "no response",
                body   = last_body,
                time   = os.time(),
            })
        end
    end

    return result
end

-- Circular buffer for the last 8 API errors
local MAX_API_ERRORS = 8

local function addApiError(self, err)
	if self._suppress_api_errors then return end
    if not self._api_errors then
        self._api_errors = {}
    end
    table.insert(self._api_errors, err)
    if #self._api_errors > MAX_API_ERRORS then
        table.remove(self._api_errors, 1)
    end
    
    self._last_api_error = err
end

local function clearApiErrors(self)
    self._api_errors = {}
    self._last_api_error = nil
end


local function getApiErrors(self)
    return self._api_errors or {}
end

local function invalidateDeviceIdCache()
    _cached_device_id = nil
end

-- =======================================================================
--  Safe API Client Layer
--
--  Return value contract:
--    Read helpers  (getX):  data, err  — data is nil on failure, err is a string
--    Write helpers (patch/add/delete/scan/set): {ok, error} table
--
--  All existing callers use `or {}` on reads and `result.ok` on writes,
--  so both contracts are stable.  New callers on reads can use:
--    local data, err = self:getFolders()
--    if not data then logger.warn(err) end
-- =======================================================================

local SafeClient = {}

local function _safeResult(self, api_path, method, raw)
    if raw == nil then
        local err = self._last_api_error
        local status = (err and err.status) or "no response"
        local msg = string.format("%s %s: %s", method, api_path, status)
        return { ok = false, error = msg }
    end
    if type(raw) == "table" then
        return { ok = true, data = raw }
    end
    return { ok = true }
end

function SafeClient.GET(self, api_path)
    return _safeResult(self, api_path, "GET", self:apiCall(api_path, "GET"))
end

function SafeClient.POST(self, api_path, body)
    local json_body = body and JSON.encode(body) or nil
    return _safeResult(self, api_path, "POST", self:apiCall(api_path, "POST", json_body))
end

function SafeClient.PATCH(self, api_path, body)
    local json_body = body and JSON.encode(body) or nil
    return _safeResult(self, api_path, "PATCH", self:apiCall(api_path, "PATCH", json_body))
end

function SafeClient.DELETE(self, api_path)
    return _safeResult(self, api_path, "DELETE", self:apiCall(api_path, "DELETE"))
end

function SafeClient.PUT(self, api_path, body)
    local json_body = body and JSON.encode(body) or nil
    return _safeResult(self, api_path, "PUT", self:apiCall(api_path, "PUT", json_body))
end

-- Config
function SafeClient.getConfig(self)
    local r = SafeClient.GET(self, "config")
    if r.ok then return r.data end
    return nil, r.error
end

function SafeClient.getFolders(self)
    local r = SafeClient.GET(self, "config/folders")
    if r.ok then return r.data end
    return nil, r.error
end

function SafeClient.getDevices(self)
    local r = SafeClient.GET(self, "config/devices")
    if r.ok then return r.data end
    return nil, r.error
end

function SafeClient.getOptions(self)
    local r = SafeClient.GET(self, "config/options")
    if r.ok then return r.data end
    return nil, r.error
end

function SafeClient.patchFolder(self, folder_id, patch)
    local ep = "config/folders/" .. util.urlEncode(folder_id)
    return SafeClient.PATCH(self, ep, patch)
end

function SafeClient.patchDevice(self, device_id, patch)
    local ep = "config/devices/" .. util.urlEncode(device_id)
    return SafeClient.PATCH(self, ep, patch)
end

function SafeClient.patchOptions(self, options)
    return SafeClient.PATCH(self, "config/options", options)
end

function SafeClient.addDevice(self, device)
    return SafeClient.POST(self, "config/devices", device)
end

function SafeClient.addFolder(self, folder)
    return SafeClient.POST(self, "config/folders", folder)
end

function SafeClient.deleteFolder(self, folder_id)
    local ep = "config/folders/" .. util.urlEncode(folder_id)
    return SafeClient.DELETE(self, ep)
end

-- Status & Stats
function SafeClient.getSystemStatus(self)
    local r = SafeClient.GET(self, "system/status")
    if r.ok then return r.data end
    return nil, r.error
end

function SafeClient.getConnections(self)
    local r = SafeClient.GET(self, "system/connections")
    if r.ok then return r.data end
    return nil, r.error
end

function SafeClient.getDeviceStats(self)
    local r = SafeClient.GET(self, "stats/device")
    if r.ok then return r.data end
    return nil, r.error
end

function SafeClient.getFolderStats(self)
    local r = SafeClient.GET(self, "stats/folder")
    if r.ok then return r.data end
    return nil, r.error
end

-- DB
function SafeClient.getFolderStatus(self, folder_id)
    local ep = "db/status?folder=" .. util.urlEncode(folder_id)
    local r = SafeClient.GET(self, ep)
    if r.ok then return r.data end
    return nil, r.error
end

-- Returns { folder, errors = {{path, error}, ...}, page, perpage } or nil.
-- Used to read the actual scan/pull error text so the UI can tell a transient,
-- rescan-fixable error apart from one that needs the user to act.
function SafeClient.getFolderErrors(self, folder_id)
    local ep = "folder/errors?folder=" .. util.urlEncode(folder_id)
    local r = SafeClient.GET(self, ep)
    if r.ok then return r.data end
    return nil, r.error
end

function SafeClient.scanFolder(self, folder_id)
    local ep = "db/scan?folder=" .. util.urlEncode(folder_id)
    return SafeClient.POST(self, ep)
end

function SafeClient.setFolderIgnores(self, folder_id, patterns)
    local ep = "db/ignores?folder=" .. util.urlEncode(folder_id)
    return SafeClient.POST(self, ep, { ignore = patterns })
end

function SafeClient.getFolderIgnores(self, folder_id)
    local ep = "db/ignores?folder=" .. util.urlEncode(folder_id)
    local r = SafeClient.GET(self, ep)
    if r.ok then return r.data end
    return nil, r.error
end

-- Cluster (pending)
function SafeClient.getPendingDevices(self)
    local r = SafeClient.GET(self, "cluster/pending/devices")
    if r.ok then return r.data end
    return nil, r.error
end

function SafeClient.getPendingFolders(self)
    local r = SafeClient.GET(self, "cluster/pending/folders")
    if r.ok then return r.data end
    return nil, r.error
end

function SafeClient.ignorePendingDevice(self, device_id)
    local ep = "cluster/pending/devices?device=" .. util.urlEncode(device_id)
    return SafeClient.DELETE(self, ep)
end

function SafeClient.ignorePendingFolder(self, folder_id, device_id)
    local ep = "cluster/pending/folders?folder=" .. util.urlEncode(folder_id)
        .. "&device=" .. util.urlEncode(device_id)
    return SafeClient.DELETE(self, ep)
end

function SafeClient.setPause(self, device_id, paused)
    return SafeClient.patchDevice(self, device_id, { paused = paused })
end



-- The non-SafeClient module-level helpers are listed explicitly.  Every
-- SafeClient method is then exported automatically, so adding a method to
-- SafeClient can never silently miss this table again — the class of bug that
-- once hid getFolderErrors (defined here but not exported, so self:getFolderErrors
-- was nil and the background health check crashed).  Names starting with "_" are
-- treated as private and are not auto-exported.
local exports = {
    -- Low-level client
    getAPIKey    = getAPIKey,
    getDeviceId  = getDeviceId,
    apiCall      = apiCall,

    -- Error buffer
    _addApiError = addApiError,
    _clearApiErrors = clearApiErrors,
    getApiErrors = getApiErrors,
    _invalidateDeviceIdCache = invalidateDeviceIdCache,
}

for name, func in pairs(SafeClient) do
    if type(func) == "function" and name:sub(1, 1) ~= "_" then
        exports[name] = func
    end
end

return exports
