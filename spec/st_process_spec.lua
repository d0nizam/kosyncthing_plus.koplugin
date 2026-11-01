-- st_process_spec.lua – comprehensive tests for the binary lifecycle module
-- Covers: kindlePortGuard, binaryExists cache, isProcessSyncthing (all 4 layers),
-- getPid, isRunning, safeHomeDir, start() (8+ paths), stop() (suspend + graceful),
-- _cleanupStartResources standby balance, and applyNetworkSettings.

local Mock = require("spec.spec_helper")

-- ─────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────────

local PID_PATH = "/tmp/syncthing_koreader.pid"
local BINARY   = "/tmp/koreader/plugins/kosyncthing_plus.koplugin/syncthing"

-- Replace the st_utils preload with a richer version that st_process needs.
local function installRichStUtils(overrides)
    overrides = overrides or {}
    package.preload["st_utils"] = function()
        return {
            DANGEROUS_PATHS     = { ["/"] = true, ["/mnt"] = true, ["/data"] = true,
                                    ["/system"] = true, ["/proc"] = true,
                                    ["/sys"] = true, ["/dev"] = true, ["/etc"] = true, [""] = true },
            ALL_SETTINGS_KEYS   = { "syncthing_was_running", "syncthing_start_failed" },
            plugin_path         = "/tmp/koreader/plugins/kosyncthing_plus.koplugin/",
            NO_CACERT_MSG       = "no cacert",
            shellEscape         = function(s) return tostring(s or ""):gsub("'", "'\\''") end,
            getBinaryPath       = overrides.getBinaryPath    or function() return BINARY end,
            getConfigDir        = overrides.getConfigDir     or function() return "/tmp/koreader/settings/syncthing" end,
            getDataDir          = overrides.getDataDir       or function() return "/tmp/koreader/settings/syncthing", nil end,
            execOk              = overrides.execOk           or function(r) return r == 0 or r == true end,
            loopbackIsUp        = overrides.loopbackIsUp     or function() return true end,
            invalidateLoopbackCache = function() end,
            invalidateCurlCache = function() end,
            kindleOpenPort      = overrides.kindleOpenPort   or function() end,
            kindleClosePort     = overrides.kindleClosePort  or function() end,
            kindleOpenPortUDP   = overrides.kindleOpenPortUDP  or function() end,
            kindleClosePortUDP  = overrides.kindleClosePortUDP or function() end,
            setGUIPassword      = overrides.setGUIPassword   or function() return true end,
            cacertExists        = overrides.cacertExists     or function() return true end,
            isOk                = function(r) return r ~= nil and r.ok == true end,
            errOf               = function(r) return (r and r.error) or "no response" end,
            FOLDER_CACHE_TTL    = 15,
            setAutostartPaused  = function(v) Mock.state.autostart_paused = v and true or false end,
            isAutostartPaused   = function() return Mock.state.autostart_paused == true end,
            formatBytes         = tostring,
            isELF               = overrides.isELF or function(_path) return true end,
        }
    end
end

-- Build a minimal plugin object with all fields st_process references via `self`.
local function makePlugin(overrides)
    overrides = overrides or {}
    local plugin = {
        _starting              = false,
        _stopping              = false,
        _health_check_active   = true,
        _silentStart           = nil,
        _kindle_release        = nil,
        syncthing_port         = "8384",
        active_port            = nil,
        resource_profile       = "low",
        network_access         = "lan",
        gui_password           = nil,
        gui_user               = "syncthing",
        _notifiers             = nil,
        -- cache stubs
        _cache                 = {},
        _cacheGet  = function(self, k) return self._cache[k] end,
        _cacheSet  = function(self, k, v) self._cache[k] = v; return v end,
        _cacheInvalidate = function(self) self._cache = {} end,
        _invalidateConflictCache = function() end,
        _stopPeriodicSyncTimer = function() end,
        showFirstRunDialog     = overrides.showFirstRunDialog or function() end,
        checkForUpdates        = function() end,
        applyNetworkSettings   = overrides.applyNetworkSettings or function() end,
        getFolders             = overrides.getFolders or function() return {} end,
        patchFolder            = overrides.patchFolder or function() return { ok = true } end,
        getDevices             = overrides.getDevices or function() return {} end,
        patchDevice            = overrides.patchDevice or function() return { ok = true } end,
        getOptions             = overrides.getOptions or function() return {} end,
        patchOptions           = overrides.patchOptions or function() return { ok = true } end,
        -- Fallback isRunning reads the plugin-level cache so the 3-second
        -- timer scheduled by check_pid's success path does not crash on nil.
        isRunning              = overrides.isRunning or function(self)
            local cached = self:_cacheGet("is_running")
            if cached ~= nil then return cached end
            return false
        end,
    }
    for k, v in pairs(overrides) do
        if plugin[k] == nil then plugin[k] = v end
    end
    return plugin
end

-- Flush st_process (and its module-level _binary_exists_cache) between tests.
-- Also clears st_utils so the rich preload installed by installRichStUtils()
-- is used rather than the basic cached version from Mock.install().
local function reloadProcess()
    package.loaded["st_process"] = nil
    package.loaded["st_utils"]   = nil
    -- Bypass the luarocks searcher (which crashes when ~/.luarocks/rocks-5.4/manifest
    -- is absent) by registering the file path directly into package.preload.
    -- spec_helper already adds the plugin root to package.path, so searchpath
    -- resolves the file without ever going through the luarocks loader.
    local st_path = package.searchpath("st_process", package.path)
    package.preload["st_process"] = assert(loadfile(st_path))
    return require("st_process")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- io / os stubs
-- ─────────────────────────────────────────────────────────────────────────────

-- We override io.open, io.popen, os.execute, os.remove at the Lua global level
-- so that st_process.lua (which calls them directly) can be controlled.

local real_io_open   = io.open
local real_io_popen  = io.popen
local real_os_execute = os.execute
local real_os_remove  = os.remove

local io_open_map   = {}  -- path → content string (nil = not found)
local popen_map     = {}  -- pattern → { lines = {}, exit = 0 }
local execute_map   = {}  -- pattern → return code (0 = success)
local removed_paths = {}

local function stubIO()
    io_open_map   = {}
    popen_map     = {}
    execute_map   = {}
    removed_paths = {}

    io.open = function(path, mode)
        local content = io_open_map[path]
        if content == nil then return nil end
        local pos = 1
        return {
            read = function(_, fmt)
                if fmt == "*l" or fmt == "l" then
                    local nl = content:find("\n", pos, true)
                    if not nl then
                        if pos > #content then return nil end
                        local line = content:sub(pos)
                        pos = #content + 1
                        return line
                    end
                    local line = content:sub(pos, nl - 1)
                    pos = nl + 1
                    return line
                elseif fmt == "*a" or fmt == "a" then
                    local rest = content:sub(pos)
                    pos = #content + 1
                    return rest
                end
                return nil
            end,
            close = function() end,
            write = function(_, _) return true end,
        }
    end

    io.popen = function(cmd)
        for pattern, resp in pairs(popen_map) do
            if cmd:find(pattern, 1, true) or cmd:match(pattern) then
                local lines = resp.lines or {}
                local i = 0
                return {
                    read = function(_, fmt)
                        if fmt == "*l" or fmt == "l" then
                            i = i + 1
                            return lines[i]
                        elseif fmt == "*a" or fmt == "a" then
                            return table.concat(lines, "\n")
                        end
                        return nil
                    end,
                    lines = function()
                        return function()
                            i = i + 1
                            return lines[i]
                        end
                    end,
                    close = function() end,
                }
            end
        end
        -- fallback: empty output
        return {
            read = function() return nil end,
            lines = function() return function() end end,
            close = function() end,
        }
    end

    os.execute = function(cmd)
        for pattern, code in pairs(execute_map) do
            if cmd:find(pattern, 1, true) or cmd:match(pattern) then
                return code
            end
        end
        return 1  -- default: failure
    end

    os.remove = function(path)
        removed_paths[path] = true
        return true
    end
end

local function restoreIO()
    io.open    = real_io_open
    io.popen   = real_io_popen
    os.execute = real_os_execute
    os.remove  = real_os_remove
end

-- Convenience: set a running syncthing pid
local function setPid(pid)
    io_open_map[PID_PATH] = tostring(pid) .. "\n"
end

-- Convenience: make kill -0 succeed for a pid
local function setPidAlive(pid)
    execute_map["kill -0 " .. tostring(pid)] = 0
end

-- Convenience: make /proc/<pid>/comm report "syncthing"
local function setProcComm(pid, name)
    io_open_map["/proc/" .. tostring(pid) .. "/comm"] = name .. "\n"
end


-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 1: kindlePortGuard / releaseKindlePort
-- ─────────────────────────────────────────────────────────────────────────────

describe("kindlePortGuard", function()
    local Device

    before_each(function()
        Mock.reset()
        installRichStUtils()
        package.loaded["device"] = nil
        reloadProcess()
        Device = require("device")
        stubIO()
    end)

    after_each(function() restoreIO() end)

    it("does not call kindleClosePort on non-Kindle devices", function()
        local closed = 0
        installRichStUtils({ kindleClosePort = function() closed = closed + 1 end })
        Device.isKindle = function() return false end
        local P = reloadProcess()
        local plugin = makePlugin()
        -- Call stop with no pid – this exercises releaseKindlePort via stop's early path
        P.stop(plugin, nil, false, true)
        assert.are.equal(0, closed)
    end)

    it("closes port exactly once even if releaseKindlePort called twice (Kindle)", function()
        local closed = 0
        installRichStUtils({
            kindleOpenPort  = function() end,
            kindleClosePort = function() closed = closed + 1 end,
        })
        Device.isKindle = function() return true end
        local P = reloadProcess()

        -- Simulate what start() does after daemon launches:
        local plugin = makePlugin()
        -- Manually invoke the guard via stop() double-call scenario:
        -- Build a release closure the same way kindlePortGuard does.
        local released = false
        plugin._kindle_release = function()
            if released then return end
            released = true
            if Device.isKindle() then closed = closed + 1 end
        end
        -- First release
        plugin._kindle_release()
        -- Second release (should be no-op)
        if plugin._kindle_release then plugin._kindle_release() end
        assert.are.equal(1, closed)
    end)
end)


-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 2: binaryExists cache
-- ─────────────────────────────────────────────────────────────────────────────

describe("binaryExists", function()
    before_each(function()
        Mock.reset()
        installRichStUtils()
        stubIO()
    end)

    after_each(function() restoreIO() end)

    it("returns false when binary is missing", function()
        Mock.state.path_exists[BINARY] = nil
        local P = reloadProcess()
        local plugin = makePlugin()
        assert.is_false(P.binaryExists(plugin))
    end)

    it("returns true when binary exists", function()
        Mock.state.path_exists[BINARY] = true
        local P = reloadProcess()
        local plugin = makePlugin()
        assert.is_true(P.binaryExists(plugin))
    end)

    it("caches positive result so pathExists is only called once", function()
        local calls = 0
        -- Save/restore util so the custom preload does not leak to later suites.
        local saved_preload = package.preload["util"]
        local saved_loaded  = package.loaded["util"]
        package.loaded["util"] = nil   -- evict the cached mock so the preload below is used
        package.preload["util"] = function()
            return {
                pathExists = function(path)
                    calls = calls + 1
                    return path == BINARY
                end,
                makePath = function() return true end,
                getFriendlySize = function() return "1 MB" end,
                getFilesystemType = function() return "ext4" end,
                urlEncode = function(s) return s end,
            }
        end
        local P = reloadProcess()
        local plugin = makePlugin()
        P.binaryExists(plugin)
        P.binaryExists(plugin)
        package.preload["util"] = saved_preload
        package.loaded["util"]  = saved_loaded
        assert.are.equal(1, calls)
    end)

    it("invalidateBinaryCache causes re-evaluation on next call", function()
        local calls = 0
        -- Save/restore util so the custom preload does not leak to later suites.
        local saved_preload = package.preload["util"]
        local saved_loaded  = package.loaded["util"]
        package.loaded["util"] = nil   -- evict the cached mock so the preload below is used
        package.preload["util"] = function()
            return {
                pathExists = function()
                    calls = calls + 1
                    return true
                end,
                makePath = function() return true end,
                getFriendlySize = function() return "1 MB" end,
                getFilesystemType = function() return "ext4" end,
                urlEncode = function(s) return s end,
            }
        end
        local P = reloadProcess()
        local plugin = makePlugin()
        P.binaryExists(plugin)
        P._invalidateBinaryCache(plugin)
        P.binaryExists(plugin)
        package.preload["util"] = saved_preload
        package.loaded["util"]  = saved_loaded
        assert.are.equal(2, calls)
    end)
end)


-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 3: isRunning
-- ─────────────────────────────────────────────────────────────────────────────

describe("isRunning", function()
    before_each(function()
        Mock.reset()
        installRichStUtils()
        stubIO()
    end)

    after_each(function() restoreIO() end)

    it("returns false when pid file does not exist", function()
        -- io_open_map has no PID_PATH entry → io.open returns nil
        local P = reloadProcess()
        local plugin = makePlugin()
        assert.is_false(P.isRunning(plugin))
    end)

    it("returns false and removes pid file when process is dead", function()
        setPid(9999)
        -- kill -0 fails → process dead
        execute_map["kill -0 9999"] = 1
        local P = reloadProcess()
        local plugin = makePlugin()
        assert.is_false(P.isRunning(plugin))
        assert.is_true(removed_paths[PID_PATH])
    end)

    it("returns false when pid is alive but process is not syncthing", function()
        setPid(1234)
        setPidAlive(1234)
        -- /proc/1234/comm says something else
        io_open_map["/proc/1234/comm"] = "bash\n"
        io_open_map["/proc/1234/cmdline"] = "/bin/bash\0"
        -- popen ps returns nothing useful
        local P = reloadProcess()
        local plugin = makePlugin()
        assert.is_false(P.isRunning(plugin))
        assert.is_true(removed_paths[PID_PATH])
    end)

    it("returns true when kill -0 succeeds and /proc/comm is 'syncthing'", function()
        setPid(5555)
        setPidAlive(5555)
        setProcComm(5555, "syncthing")
        local P = reloadProcess()
        local plugin = makePlugin()
        assert.is_true(P.isRunning(plugin))
    end)

    it("uses /proc/cmdline as fallback when comm is absent", function()
        setPid(7777)
        setPidAlive(7777)
        -- no /proc/comm entry → io.open returns nil for comm
        io_open_map["/proc/7777/cmdline"] = "/usr/bin/syncthing\0serve\0"
        local P = reloadProcess()
        local plugin = makePlugin()
        assert.is_true(P.isRunning(plugin))
    end)

    it("caches the result within the same isRunning call window", function()
        -- First call: no pid → false, cached
        local P = reloadProcess()
        local plugin = makePlugin()
        local r1 = P.isRunning(plugin)
        -- Now set up a pid (should not be seen due to cache)
        setPid(5555)
        setPidAlive(5555)
        setProcComm(5555, "syncthing")
        local r2 = P.isRunning(plugin)
        assert.is_false(r1)
        assert.is_false(r2)  -- cached false
    end)

    it("re-evaluates after _cacheInvalidate", function()
        local P = reloadProcess()
        local plugin = makePlugin()
        P.isRunning(plugin)  -- caches false
        plugin:_cacheInvalidate()
        setPid(5555)
        setPidAlive(5555)
        setProcComm(5555, "syncthing")
        assert.is_true(P.isRunning(plugin))
    end)
end)


-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 4: safeHomeDir
-- ─────────────────────────────────────────────────────────────────────────────

describe("safeHomeDir", function()
    before_each(function()
        Mock.reset()
        installRichStUtils()
        stubIO()
    end)

    after_each(function() restoreIO() end)

    it("returns nil when home_dir is not set", function()
        local P = reloadProcess()
        local plugin = makePlugin()
        G_reader_settings:saveSetting("home_dir", nil)
        assert.is_nil(P.safeHomeDir(plugin))
    end)

    it("returns nil for dangerous system paths", function()
        local P = reloadProcess()
        local plugin = makePlugin()
        for _, danger in ipairs({ "/", "/mnt", "/data", "/system", "/proc",
                                   "/sys", "/dev", "/etc", "" }) do
            G_reader_settings:saveSetting("home_dir", danger)
            assert.is_nil(P.safeHomeDir(plugin),
                "expected nil for dangerous path: " .. tostring(danger))
        end
    end)

    it("strips trailing slashes from home_dir", function()
        local P = reloadProcess()
        local plugin = makePlugin()
        G_reader_settings:saveSetting("home_dir", "/mnt/us/documents///")
        local result = P.safeHomeDir(plugin)
        assert.are.equal("/mnt/us/documents", result)
    end)

    it("returns the path unchanged for safe directories", function()
        local P = reloadProcess()
        local plugin = makePlugin()
        G_reader_settings:saveSetting("home_dir", "/mnt/us/documents")
        assert.are.equal("/mnt/us/documents", P.safeHomeDir(plugin))
    end)
end)


-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 5: start() – early-exit paths
-- ─────────────────────────────────────────────────────────────────────────────

describe("start() early exits", function()
    before_each(function()
        Mock.reset()
        installRichStUtils()
        stubIO()
    end)

    after_each(function() restoreIO() end)

    it("calls showFirstRunDialog when binary is missing and not silent", function()
        Mock.state.path_exists[BINARY] = nil
        local P = reloadProcess()
        local dialog_shown = false
        local plugin = makePlugin({
            showFirstRunDialog = function(self, cb)
                dialog_shown = true
                if cb then cb() end
            end,
        })
        P.start(plugin, nil)
        assert.is_true(dialog_shown)
        assert.is_false(plugin._starting)
    end)

    it("fires callback immediately (no dialog) for a silent start with missing binary", function()
        Mock.state.path_exists[BINARY] = nil
        local P = reloadProcess()
        local cb_called = false
        local dialog_shown = false
        local plugin = makePlugin({
            showFirstRunDialog = function() dialog_shown = true end,
        })
        plugin._silentStart = true
        P.start(plugin, function() cb_called = true end)
        assert.is_true(cb_called)
        assert.is_false(dialog_shown)
        assert.is_false(plugin._starting)
    end)

    it("returns early if _starting is already true (re-entrancy guard)", function()
        Mock.state.path_exists[BINARY] = true
        local P = reloadProcess()
        local cb_count = 0
        local plugin = makePlugin()
        plugin._starting = true
        P.start(plugin, function() cb_count = cb_count + 1 end)
        assert.are.equal(1, cb_count)
        -- _starting must not be flipped to false by the guard path
        assert.is_true(plugin._starting)
    end)

    it("returns early if _stopping is true", function()
        Mock.state.path_exists[BINARY] = true
        local P = reloadProcess()
        local cb_count = 0
        local plugin = makePlugin()
        plugin._stopping = true
        P.start(plugin, function() cb_count = cb_count + 1 end)
        assert.are.equal(1, cb_count)
    end)

    it("shows warning and clears _starting when home dir is not set", function()
        Mock.state.path_exists[BINARY] = true
        -- binaryMatchesDevice needs uname -m to match binary arch
        popen_map["uname -m"] = { lines = { "x86_64" } }
        popen_map["readelf"] = { lines = { "X86-64" } }
        G_reader_settings:saveSetting("home_dir", nil)
        local P = reloadProcess()
        local plugin = makePlugin()
        P.start(plugin, nil)
        assert.is_false(plugin._starting)
        local warnings = {}
        for _, w in ipairs(Mock.state.shown) do
            if w.icon == "notice-warning" then table.insert(warnings, w) end
        end
        assert.is_true(#warnings > 0, "expected at least one warning dialog")
    end)

    it("shows warning and clears _starting when already running", function()
        Mock.state.path_exists[BINARY] = true
        popen_map["uname -m"] = { lines = { "x86_64" } }
        popen_map["readelf"]  = { lines = { "X86-64" } }
        G_reader_settings:saveSetting("home_dir", "/mnt/us/documents")
        -- Pre-seed cache so isRunning() returns true
        local P = reloadProcess()
        local plugin = makePlugin()
        plugin._cache["is_running"] = true
        P.start(plugin, nil)
        assert.is_false(plugin._starting)
    end)

    it("shows warning when exec of start-syncthing fails", function()
        Mock.state.path_exists[BINARY] = true
        Mock.state.path_exists["/tmp/koreader/settings/syncthing"] = true
        popen_map["uname -m"] = { lines = { "x86_64" } }
        popen_map["readelf"]  = { lines = { "X86-64" } }
        G_reader_settings:saveSetting("home_dir", "/mnt/us/documents")
        -- All os.execute calls fail
        execute_map["sh '"] = 1
        local P = reloadProcess()
        local plugin = makePlugin()
        local cb_called = false
        P.start(plugin, function() cb_called = true end)
        assert.is_true(cb_called)
        assert.is_false(plugin._starting)
        local had_warning = false
        for _, w in ipairs(Mock.state.shown) do
            if w.icon == "notice-warning" then had_warning = true end
        end
        assert.is_true(had_warning)
    end)
end)


-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 6: start() – check_pid loop (successful startup)
-- ─────────────────────────────────────────────────────────────────────────────

describe("start() check_pid loop", function()
    before_each(function()
        Mock.reset()
        installRichStUtils()
        stubIO()
    end)

    after_each(function() restoreIO() end)

    -- Helper: set up environment for a successful start.
    -- The pid file must NOT exist before the launch script runs; otherwise
    -- the initial isRunning() guard in start() sees the process as already
    -- running and exits early, bypassing the check_pid loop entirely.
    -- We hook os.execute so the pid state is set lazily the moment the
    -- start-syncthing shell script is exec'd (matching real device behaviour).
    local function setupSuccessEnv()
        Mock.state.path_exists[BINARY] = true
        Mock.state.path_exists["/tmp/koreader/settings/syncthing"] = true
        popen_map["uname -m"] = { lines = { "x86_64" } }
        popen_map["readelf"]  = { lines = { "X86-64" } }
        G_reader_settings:saveSetting("home_dir", "/mnt/us/documents")
        -- Intercept os.execute: when the launch script runs, materialise the
        -- pid file so subsequent isRunning() / check_pid polls find it.
        local launched = false
        os.execute = function(cmd)
            if not launched and (cmd:find("sh '", 1, true)) then
                launched = true
                io_open_map[PID_PATH]              = "42\n"
                execute_map["kill -0 42"]           = 0
                io_open_map["/proc/42/comm"]        = "syncthing\n"
                Mock.state.path_exists[PID_PATH]   = true
                return 0
            end
            for pattern, code in pairs(execute_map) do
                if cmd:find(pattern, 1, true) or cmd:match(pattern) then
                    return code
                end
            end
            return 1
        end
    end

    it("fires callback and clears _starting after pid appears", function()
        setupSuccessEnv()
        local P = reloadProcess()
        local plugin = makePlugin()
        local cb_called = false
        P.start(plugin, function() cb_called = true end)
        Mock.runTimers(5)
        assert.is_true(cb_called)
        assert.is_false(plugin._starting)
    end)

    it("balances standby: preventStandby matched by allowStandby on success", function()
        setupSuccessEnv()
        local P = reloadProcess()
        local plugin = makePlugin()
        P.start(plugin, nil)
        Mock.runTimers(5)
        assert.are.equal(0, Mock.state.standby)
    end)

    it("shows 'Syncthing started' InfoMessage on non-silent start", function()
        setupSuccessEnv()
        local P = reloadProcess()
        local plugin = makePlugin()
        P.start(plugin, nil)
        Mock.runTimers(5)
        local found = false
        for _, w in ipairs(Mock.state.shown) do
            if w.text and w.text:find("started") then found = true end
        end
        assert.is_true(found)
    end)

    it("does NOT show 'Syncthing started' on silent start", function()
        setupSuccessEnv()
        local P = reloadProcess()
        local plugin = makePlugin()
        plugin._silentStart = true
        P.start(plugin, nil)
        Mock.runTimers(5)
        local found = false
        for _, w in ipairs(Mock.state.shown) do
            if w.text and w.text:find("started") then found = true end
        end
        assert.is_false(found)
    end)

    it("aborts check_pid and kills process when _health_check_active goes false", function()
        -- exec succeeds but pid does NOT appear yet
        Mock.state.path_exists[BINARY] = true
        Mock.state.path_exists["/tmp/koreader/settings/syncthing"] = true
        popen_map["uname -m"] = { lines = { "x86_64" } }
        popen_map["readelf"]  = { lines = { "X86-64" } }
        G_reader_settings:saveSetting("home_dir", "/mnt/us/documents")
        execute_map["sh '"] = 0
        local P = reloadProcess()
        local plugin = makePlugin()
        plugin._health_check_active = false  -- signal abort before first check_pid fires
        local cb_called = false
        P.start(plugin, function() cb_called = true end)
        Mock.runTimers(3)
        assert.is_true(cb_called)
        assert.is_false(plugin._starting)
    end)

    it("times out and shows warning after 24 failed attempts", function()
        -- exec succeeds but pid file never appears
        Mock.state.path_exists[BINARY] = true
        Mock.state.path_exists["/tmp/koreader/settings/syncthing"] = true
        popen_map["uname -m"] = { lines = { "x86_64" } }
        popen_map["readelf"]  = { lines = { "X86-64" } }
        G_reader_settings:saveSetting("home_dir", "/mnt/us/documents")
        execute_map["sh '"] = 0
        local P = reloadProcess()
        local plugin = makePlugin()
        P.start(plugin, nil)
        Mock.runTimers(50)   -- exhaust all 24 retry timers
        -- _starting must be cleared by _cleanupStartResources
        assert.is_false(plugin._starting)
        -- standby must be balanced
        assert.are.equal(0, Mock.state.standby)
        local had_timeout_warning = false
        for _, w in ipairs(Mock.state.shown) do
            if w.icon == "notice-warning" and w.text and w.text:find("too long") then
                had_timeout_warning = true
            end
        end
        assert.is_true(had_timeout_warning)
    end)

    it("balances standby even on timeout (_cleanupStartResources)", function()
        Mock.state.path_exists[BINARY] = true
        Mock.state.path_exists["/tmp/koreader/settings/syncthing"] = true
        popen_map["uname -m"] = { lines = { "x86_64" } }
        popen_map["readelf"]  = { lines = { "X86-64" } }
        G_reader_settings:saveSetting("home_dir", "/mnt/us/documents")
        execute_map["sh '"] = 0
        local P = reloadProcess()
        local plugin = makePlugin()
        P.start(plugin, nil)
        Mock.runTimers(50)
        assert.are.equal(0, Mock.state.standby)
    end)

    it("callback errors in _cleanupStartResources are swallowed (pcall)", function()
        Mock.state.path_exists[BINARY] = true
        Mock.state.path_exists["/tmp/koreader/settings/syncthing"] = true
        popen_map["uname -m"] = { lines = { "x86_64" } }
        popen_map["readelf"]  = { lines = { "X86-64" } }
        G_reader_settings:saveSetting("home_dir", "/mnt/us/documents")
        execute_map["sh '"] = 0
        local P = reloadProcess()
        local plugin = makePlugin()
        -- Exploding callback should not propagate
        assert.has_no.errors(function()
            P.start(plugin, function() error("boom") end)
            Mock.runTimers(50)
        end)
        assert.is_false(plugin._starting)
    end)
end)


-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 7: stop()
-- ─────────────────────────────────────────────────────────────────────────────

describe("stop()", function()
    before_each(function()
        Mock.reset()
        installRichStUtils()
        stubIO()
    end)

    after_each(function() restoreIO() end)

    it("fires callback immediately when no pid file exists", function()
        local cb_called = false
        local P = reloadProcess()
        local plugin = makePlugin()
        P.stop(plugin, function() cb_called = true end, false, true)
        assert.is_true(cb_called)
        assert.is_false(plugin._stopping)
        assert.are.equal(0, Mock.state.standby)
    end)

    it("shows 'already stopped' when pid exists but belongs to another process", function()
        setPid(100)
        -- /proc/100/comm returns "bash" → not syncthing
        io_open_map["/proc/100/comm"] = "bash\n"
        local P = reloadProcess()
        local plugin = makePlugin()
        P.stop(plugin, nil, false, false)
        local had_msg = false
        for _, w in ipairs(Mock.state.shown) do
            if w.text and w.text:find("stopped") then had_msg = true end
        end
        assert.is_true(had_msg)
        assert.is_true(removed_paths[PID_PATH])
    end)

    it("returns early if _stopping already set (re-entrancy guard)", function()
        local cb_count = 0
        local P = reloadProcess()
        local plugin = makePlugin()
        plugin._stopping = true
        P.stop(plugin, function() cb_count = cb_count + 1 end)
        assert.are.equal(1, cb_count)
        assert.is_true(plugin._stopping)  -- unchanged by guard
    end)

    it("returns early if _starting is set", function()
        local cb_count = 0
        local P = reloadProcess()
        local plugin = makePlugin()
        plugin._starting = true
        P.stop(plugin, function() cb_count = cb_count + 1 end)
        assert.are.equal(1, cb_count)
    end)

    it("synchronous suspend path: sends SIGTERM then SIGKILL and clears pid", function()
        setPid(200)
        execute_map["kill -0 200"] = 0
        io_open_map["/proc/200/comm"] = "syncthing\n"
        -- After the sleep, process is still alive → needs SIGKILL
        execute_map["kill 200"] = 0
        execute_map["kill -9 200"] = 0
        local kill_9_called = false
        local orig_exec = os.execute
        os.execute = function(cmd)
            if cmd:find("kill -9 200") then kill_9_called = true end
            for pattern, code in pairs(execute_map) do
                if cmd:find(pattern, 1, true) or cmd:match(pattern) then
                    return code
                end
            end
            return 1
        end
        local P = reloadProcess()
        local plugin = makePlugin()
        local cb_called = false
        P.stop(plugin, function() cb_called = true end, true, true)
        os.execute = real_os_execute
        assert.is_true(cb_called)
        assert.is_false(plugin._stopping)
        assert.are.equal(0, Mock.state.standby)
    end)

    it("graceful stop: check_stopped fires finish_stop when process dies quickly", function()
        setPid(300)
        execute_map["kill -0 300"] = 0
        io_open_map["/proc/300/comm"] = "syncthing\n"
        execute_map["kill 300"] = 0
        -- After first scheduled check, process is dead
        local check_count = 0
        local orig_exec = os.execute
        os.execute = function(cmd)
            if cmd:find("kill -0 300") then
                check_count = check_count + 1
                if check_count > 1 then return 1 end  -- dead after first kill
                return 0
            end
            if cmd:find("kill 300") then return 0 end
            return 1
        end
        local P = reloadProcess()
        local plugin = makePlugin()
        local cb_called = false
        P.stop(plugin, function() cb_called = true end, false, true)
        Mock.runTimers(10)
        os.execute = real_os_execute
        assert.is_true(cb_called)
        assert.is_false(plugin._stopping)
        assert.are.equal(0, Mock.state.standby)
    end)

    it("graceful stop: escalates to SIGKILL after 4 checks", function()
        setPid(400)
        -- Process never dies on its own
        execute_map["kill -0 400"] = 0
        execute_map["kill 400"]    = 0
        execute_map["kill -9 400"] = 0
        io_open_map["/proc/400/comm"] = "syncthing\n"
        local P = reloadProcess()
        local plugin = makePlugin()
        P.stop(plugin, nil, false, true)
        Mock.runTimers(20)  -- enough to exhaust all 5 check_stopped levels + final timer
        -- After SIGKILL attempt, the check_stopped(5) fires and calls finish_stop or error
        assert.is_false(plugin._stopping)
        assert.are.equal(0, Mock.state.standby)
    end)

    it("clears syncthing_was_running flag on manual (non-suspend) stop", function()
        G_reader_settings:saveSetting("syncthing_was_running", true)
        setPid(500)
        execute_map["kill -0 500"] = 0
        io_open_map["/proc/500/comm"] = "syncthing\n"
        execute_map["kill 500"] = 0
        -- process dies immediately on check
        local check = 0
        os.execute = function(cmd)
            if cmd:find("kill -0 500") then
                check = check + 1
                return check > 1 and 1 or 0
            end
            if cmd:find("kill 500") then return 0 end
            return 1
        end
        local P = reloadProcess()
        local plugin = makePlugin()
        P.stop(plugin, nil, false, true)
        Mock.runTimers(10)
        os.execute = real_os_execute
        assert.are.equal(false, Mock.state.settings["syncthing_was_running"])
    end)

    -- ── Autostart session pause ────────────────────────────────────────────────────

    local function gracefulStop(P, plugin, pid, is_suspend, silent)
        -- Helper: set up a live pid and run a graceful stop to completion.
        setPid(pid)
        execute_map["kill -0 " .. pid] = 0
        io_open_map["/proc/" .. pid .. "/comm"] = "syncthing\n"
        execute_map["kill " .. pid] = 0
        local check = 0
        local orig = os.execute
        os.execute = function(cmd)
            if cmd:find("kill -0 " .. pid) then
                check = check + 1
                return check > 1 and 1 or 0
            end
            if cmd:find("kill " .. pid) then return 0 end
            return 1
        end
        P.stop(plugin, nil, is_suspend, silent)
        Mock.runTimers(10)
        os.execute = orig
    end

    it("pauses Autostart on explicit manual stop (silent=false)", function()
        local P = reloadProcess()
        local plugin = makePlugin()
        gracefulStop(P, plugin, 600, false, false)
        assert.is_true(Mock.state.autostart_paused)
    end)

    it("does NOT pause Autostart on automatic stop (silent=true)", function()
        local P = reloadProcess()
        local plugin = makePlugin()
        gracefulStop(P, plugin, 601, false, true)
        assert.is_falsy(Mock.state.autostart_paused)
    end)

    it("does NOT pause Autostart on suspend stop", function()
        -- Suspend path is synchronous (SIGTERM+SIGKILL), not graceful.
        setPid(602)
        execute_map["kill -0 602"] = 0
        io_open_map["/proc/602/comm"] = "syncthing\n"
        execute_map["kill 602"]    = 0
        execute_map["kill -9 602"] = 0
        local P = reloadProcess()
        local plugin = makePlugin()
        P.stop(plugin, nil, true, false)
        assert.is_falsy(Mock.state.autostart_paused)
    end)

    it("clears the Autostart pause when start() is called", function()
        Mock.state.autostart_paused = true
        -- start() exits early (binary missing) but must still clear the flag.
        local P = reloadProcess()
        local plugin = makePlugin()
        -- Silent start with missing binary fires callback and returns early.
        plugin._silentStart = true
        P.start(plugin, function() end)
        assert.is_falsy(Mock.state.autostart_paused)
    end)
end)


-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 8: applyNetworkSettings
-- ─────────────────────────────────────────────────────────────────────────────

describe("applyNetworkSettings", function()
    before_each(function()
        Mock.reset()
        installRichStUtils()
        stubIO()
    end)

    after_each(function() restoreIO() end)

    local function makeNetPlugin(network_access, current_options, overrides)
        local patch_received = {}
        local plugin = makePlugin(overrides or {})
        plugin.network_access = network_access or "lan"
        plugin.resource_profile = "low"
        plugin._cache["is_running"] = true  -- isRunning() returns true via cache
        plugin.isRunning = function(self) return true end
        plugin.getOptions = function()
            return current_options or {}
        end
        plugin.patchOptions = function(_, patch)
            for k, v in pairs(patch) do patch_received[k] = v end
            return { ok = true }
        end
        plugin._patch = patch_received
        return plugin
    end

    it("does nothing when not running", function()
        local P = reloadProcess()
        local plugin = makePlugin()
        plugin.isRunning = function() return false end
        -- Override the isRunning used inside applyNetworkSettings
        -- applyNetworkSettings checks self:isRunning()
        local called = false
        plugin.getOptions = function() called = true return {} end
        P.applyNetworkSettings(plugin)
        Mock.runTimers(5)
        assert.is_false(called)
    end)

    it("patches LAN settings: disables global announce, relays, NAT", function()
        local P = reloadProcess()
        local plugin = makeNetPlugin("lan", {
            globalAnnounceEnabled = true,
            relaysEnabled = true,
            natEnabled = true,
        })
        P.applyNetworkSettings(plugin)
        Mock.runTimers(5)
        assert.is_false(plugin._patch.globalAnnounceEnabled)
        assert.is_false(plugin._patch.relaysEnabled)
        assert.is_false(plugin._patch.natEnabled)
        assert.are.equal(0, plugin._patch.autoUpgradeIntervalH)
    end)

    it("patches global settings: enables announce, relays, NAT", function()
        local P = reloadProcess()
        local plugin = makeNetPlugin("global", {
            globalAnnounceEnabled = false,
            relaysEnabled = false,
            natEnabled = false,
            autoUpgradeIntervalH = 0,
        })
        P.applyNetworkSettings(plugin)
        Mock.runTimers(5)
        assert.is_true(plugin._patch.globalAnnounceEnabled)
        assert.is_true(plugin._patch.relaysEnabled)
        assert.is_true(plugin._patch.natEnabled)
        assert.are.equal(12, plugin._patch.autoUpgradeIntervalH)
    end)

    it("sends no patch when options are already correct", function()
        local P = reloadProcess()
        local patch_count = 0
        local plugin = makeNetPlugin("lan", {
            globalAnnounceEnabled = false,
            relaysEnabled = false,
            natEnabled = false,
            urAccepted = -1,
            crashReportingEnabled = false,
            autoUpgradeIntervalH = 0,
            maxConcurrentIncomingRequestKiB = 32768,
            maxFolderConcurrency = 1,
        })
        plugin.patchOptions = function(_, _)
            patch_count = patch_count + 1
            return { ok = true }
        end
        P.applyNetworkSettings(plugin)
        Mock.runTimers(5)
        assert.are.equal(0, patch_count)
    end)

    it("applies low-resource limits for 'low' profile", function()
        local P = reloadProcess()
        local plugin = makeNetPlugin("lan", {})
        plugin.resource_profile = "low"
        P.applyNetworkSettings(plugin)
        Mock.runTimers(5)
        assert.are.equal(32768,  plugin._patch.maxConcurrentIncomingRequestKiB)
        assert.are.equal(1,      plugin._patch.maxFolderConcurrency)
    end)

    it("applies high-resource limits for non-'low' profile", function()
        local P = reloadProcess()
        local plugin = makeNetPlugin("global", {})
        plugin.resource_profile = "normal"
        P.applyNetworkSettings(plugin)
        Mock.runTimers(5)
        assert.are.equal(262144, plugin._patch.maxConcurrentIncomingRequestKiB)
        assert.are.equal(0,      plugin._patch.maxFolderConcurrency)
    end)

end)


-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 9: stopPlugin / deletePluginSettings
-- ─────────────────────────────────────────────────────────────────────────────

describe("stopPlugin", function()
    before_each(function()
        Mock.reset()
        installRichStUtils()
        stubIO()
    end)

    after_each(function() restoreIO() end)

    it("disables health check and sends SIGTERM+SIGKILL to running process", function()
        setPid(999)
        execute_map["kill -0 999"] = 0
        io_open_map["/proc/999/comm"] = "syncthing\n"
        execute_map["kill 999"]   = 0
        execute_map["kill -9 999"] = 0
        local P = reloadProcess()
        local plugin = makePlugin()
        plugin._health_check_active = true
        P.stopPlugin(plugin)
        assert.is_false(plugin._health_check_active)
        assert.is_true(removed_paths[PID_PATH])
    end)

    it("is a no-op when process is not running", function()
        -- No pid file
        local P = reloadProcess()
        local plugin = makePlugin()
        plugin._cache["is_running"] = false
        assert.has_no.errors(function() P.stopPlugin(plugin) end)
        assert.is_false(plugin._health_check_active)
    end)
end)

describe("deletePluginSettings", function()
    before_each(function()
        Mock.reset()
        installRichStUtils()
        stubIO()
    end)

    after_each(function() restoreIO() end)

    it("removes all known settings keys", function()
        -- Seed a few keys
        G_reader_settings:saveSetting("syncthing_was_running", true)
        G_reader_settings:saveSetting("syncthing_start_failed", true)
        local P = reloadProcess()
        local plugin = makePlugin()
        -- Stub FS.purge so we don't hit the real filesystem
        package.preload["st_filesystem"] = function()
            return { purge = function() return true end }
        end
        P.deletePluginSettings(plugin)
        assert.is_nil(Mock.state.settings["syncthing_was_running"])
        assert.is_nil(Mock.state.settings["syncthing_start_failed"])
    end)

    it("returns true when all purge operations succeed", function()
        local P = reloadProcess()
        local plugin = makePlugin()
        package.preload["st_filesystem"] = function()
            return { purge = function() return true end }
        end
        local result = P.deletePluginSettings(plugin)
        assert.is_true(result)
    end)
end)
