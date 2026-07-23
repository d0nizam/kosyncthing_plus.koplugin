-- st_legacy_spec.lua — comprehensive tests for legacy.lua (KOSyncthing+).
--
-- Busted-style (describe/it/assert), so it runs under either real `busted`
-- or the dependency-free spec/run_tests.lua. This spec is self-contained: it
-- installs its own narrow KOReader stubs (rather than spec.mock_koreader)
-- because the legacy download/kernel logic needs fine-grained control over
-- io.popen (uname), os.execute (download steps), and the st_utils surface.
--
-- Coverage: kernel→state, kernel→version, session caching, getVersion/
-- needsPatch, download URL across architectures, the full download/install
-- state machine and every error path, enable/disable cache invalidation, and
-- the v1.2.2 read-modify-write API shim. It cannot exercise a real old-kernel
-- device, a real download, or a real daemon — those need on-device testing.

-- ───────────────────────── controllable fakes ──────────────────────────
local FAKE = {
    uname_r = "3.0.35", uname_m = "armv7l",
    proc_osrelease = nil, proc_version = nil,   -- procfs kernel sources (nil = absent)
    find_result = "/tmp/extract/syncthing-linux-arm-v1.27.12/syncthing",
    cacert = true, curl = false, unpack = true, pathexists = true,
}
local EXEC_LOG, EXEC_FAIL = {}, {}
local function exec_should_fail(cmd)
    for _, s in ipairs(EXEC_FAIL) do if tostring(cmd):find(s, 1, true) then return true end end
    return false
end
local function reset_exec() EXEC_LOG, EXEC_FAIL = {}, {} end
local function find_log(sub)
    for _, c in ipairs(EXEC_LOG) do if c:find(sub, 1, true) then return c end end
    return nil
end

io.popen = function(cmd)
    local out
    if cmd:find("uname %-r") then out = FAKE.uname_r
    elseif cmd:find("uname %-m") then out = FAKE.uname_m
    elseif cmd:find("find ")     then out = FAKE.find_result
    else out = nil end
    return { read = function() return out end, close = function() end }
end
os.execute = function(cmd) EXEC_LOG[#EXEC_LOG+1] = cmd; return cmd end

-- Control the procfs kernel sources that kernelState() consults when uname is
-- unparseable; every other path falls through to the real io.open.
local _real_io_open = io.open
io.open = function(path, mode)
    if path == "/proc/sys/kernel/osrelease" then
        if FAKE.proc_osrelease == nil then return nil end
        return { read = function() return FAKE.proc_osrelease end, close = function() end }
    elseif path == "/proc/version" then
        if FAKE.proc_version == nil then return nil end
        return { read = function() return FAKE.proc_version end, close = function() end }
    end
    return _real_io_open(path, mode)
end

local SETTINGS = {}
G_reader_settings = {
    readSetting = function(_, k) return SETTINGS[k] end,
    saveSetting = function(_, k, v) SETTINGS[k] = v end,
    delSetting  = function(_, k) SETTINGS[k] = nil end,
    isTrue      = function(_, k) return SETTINGS[k] == true end,
}
local function reset_settings() for k in pairs(SETTINGS) do SETTINGS[k] = nil end end

local noop = function() end
package.loaded["logger"] = setmetatable({}, { __index = function() return noop end })
package.loaded["ui/uimanager"] = {
    show = noop, close = noop, preventStandby = noop, allowStandby = noop,
    scheduleIn = function(_, _, fn) fn() end,
}
package.loaded["ui/widget/infomessage"]  = { new = function(_, t) return t end }
package.loaded["ui/widget/confirmbox"]    = { new = function(_, t) return t end }
package.loaded["ui/widget/buttondialog"]  = { new = function(_, t) return t end }
package.loaded["device"] = { unpackArchive = function(_, _, _, _) return FAKE.unpack ~= false end }
package.loaded["util"]   = { pathExists = function(_) return FAKE.pathexists ~= false end }
package.loaded["ffi/util"] = {
    template = function(s, ...)
        local a = { ... }
        return (s:gsub("%%(%d)", function(d) return tostring(a[tonumber(d)]) end))
    end,
}
package.loaded["syncthing_i18n"] = { gettext = function(s) return s end }
package.loaded["st_disabled"] = {
    helpHold = function() return noop end,
    gatedHold = function() return noop end,
    enabled = function() return function() return true end end,
}
-- st_guard is required by legacy.lua as a module-level object (Guard:acquire).
-- Provide a minimal stub that satisfies both the acquire/release contract and
-- the ui/network/manager dependency that the real st_guard pulls in.
package.loaded["ui/network/manager"] = {
    isWifiOn   = function() return false end,
    enableWifi = function() end,
    disableWifi = function() end,
}
package.loaded["st_guard"] = {
    acquire = function(_, _name, _opts)
        return { release = function() end }
    end,
}

local U = {
    plugin_path = "/PLUG/",
    cacert_path = "/PLUG/cacert.pem",
    NO_CACERT_MSG = "no-cacert",
    cacertExists  = function() return FAKE.cacert ~= false end,
    curlAvailable = function() return FAKE.curl == true end,
    execOk = function(v) return not exec_should_fail(v) end,
    isOk   = function(r) return type(r) == "table" and r.ok == true end,
    shellEscape = function(s) return s end,
    getBinaryPath = function()
        return SETTINGS["syncthing_use_legacy"] and "/PLUG/syncthing-legacy" or "/PLUG/syncthing"
    end,
    getConfigDir = function() return "/cfg" end,
    invalidateDataDirCache = function() FAKE.data_dir_invalidated = true end,
    isLegacy = function() return SETTINGS["syncthing_use_legacy"] == true end,
    -- Shared arch helper added in v1.1.1. The spec drives arch via withPopen
    -- (mocked uname), so we provide the same uname-based implementation here.
    detectArch = function()
        local p = io.popen("uname -m 2>/dev/null")
        if not p then return "arm", true, "unknown" end
        local m = p:read("*l"); p:close()
        if not m then return "arm", true, "unknown" end
        m = m:gsub("^%s+", ""):gsub("%s+$", "")
        if m == "aarch64" or m == "arm64" then return "arm64", false, m end
        if m == "x86_64"                  then return "amd64", false, m end
        if m:match("^i[3-6]86$")          then return "386",   false, m end
        return "arm", m:match("^armv%d") == nil, m
    end,
    -- fileSize / isGzip: used by downloadBinary to validate the downloaded
    -- archive. Default to a valid 2 MB gzip so existing tests that don't
    -- care about this check continue to pass.  Override via FAKE.file_size /
    -- FAKE.is_gzip when testing those specific failure paths.
    fileSize = function(_path) return FAKE.file_size or (2 * 1024 * 1024) end,
    isGzip   = function(_path) return FAKE.is_gzip ~= false end,
    isELF    = function(_path) return FAKE.is_elf  ~= false end,
    unpackArchive = function(_, _, _, _) return FAKE.unpack ~= false end,
    -- Selective single-entry extraction used by downloadBinary.  FAKE.unpack
    -- keeps driving the failure path so existing tests read the same way.
    extractBinaryFromArchive = function(_archive, _dest)
        if FAKE.unpack == false then return false, "extraction failed" end
        return true
    end,
}
package.loaded["st_utils"] = U

package.path = "./?.lua;" .. package.path

-- Re-install mocks before every fresh_legacy() call so the module always
-- sees current globals, even when Busted runs describe blocks in a fresh scope.
-- G_reader_settings must be written to _G explicitly because Busted uses
-- setfenv() which makes spec-level globals invisible to modules loaded via
-- require()/loadfile() unless they share the same environment table.
local function reinstall_mocks()
    _G.G_reader_settings = {
        readSetting = function(_, k) return SETTINGS[k] end,
        saveSetting = function(_, k, v) SETTINGS[k] = v end,
        delSetting  = function(_, k) SETTINGS[k] = nil end,
        isTrue      = function(_, k) return SETTINGS[k] == true end,
    }
    package.loaded["st_utils"]   = U
    package.loaded["st_guard"]   = {
        acquire = function(_, _name, _opts)
            return { release = function() end }
        end,
    }
    package.loaded["ui/network/manager"] = {
        isWifiOn    = function() return false end,
        enableWifi  = function() end,
        disableWifi = function() end,
    }
end

local function fresh_legacy()
    reinstall_mocks()
    package.loaded["legacy"] = nil
    return require("legacy")
end

-- ════════════════════════════════════════════════════════════════════════

describe("Legacy.kernelState (kernel classification)", function()
    before_each(function() FAKE.proc_osrelease = nil; FAKE.proc_version = nil; reinstall_mocks() end)
    local cases = {
        { "2.6.18", "old" }, { "2.6.31", "old" }, { "2.6.32", "old" },
        { "2.6.35", "old" }, { "3.0.35", "old" }, { "3.0.101", "old" },
        { "3.1.10", "old" }, { "3.2.0", "modern" }, { "3.2", "modern" },
        { "3.4.0", "modern" }, { "4.9.0", "modern" }, { "5.4.0", "modern" },
        { "10.2.0", "modern" }, { "2.5.0", "old" }, { "1.0.0", "old" },
        { "", "unknown" }, { "garbage", "unknown" }, { "linux", "unknown" },
        { "3", "unknown" },
    }
    for _, c in ipairs(cases) do
        it("classifies '" .. c[1] .. "' as " .. c[2], function()
            FAKE.uname_r = c[1]
            assert.are.equal(c[2], fresh_legacy().kernelState())
        end)
    end
    it("needsLegacy() is true only for an old kernel", function()
        for _, c in ipairs(cases) do
            FAKE.uname_r = c[1]
            assert.are.equal(c[2] == "old", fresh_legacy().needsLegacy())
        end
    end)

    -- procfs fallbacks: uname stays the first source, but a stripped firmware
    -- with no `uname` binary is still classified via the kernel's own files.
    it("falls back to /proc/sys/kernel/osrelease when uname is unparseable", function()
        FAKE.uname_r = ""                 -- uname yields nothing
        FAKE.proc_osrelease = "3.0.35"    -- procfs reports an old kernel
        assert.are.equal("old", fresh_legacy().kernelState())
    end)
    it("falls back to /proc/version when uname and osrelease are absent", function()
        FAKE.uname_r = "garbage"
        FAKE.proc_osrelease = nil
        FAKE.proc_version = "Linux version 5.4.0 (builder@host) (gcc 9) #1 SMP"
        assert.are.equal("modern", fresh_legacy().kernelState())
    end)
    it("uname wins when parseable (procfs not consulted)", function()
        FAKE.uname_r = "3.0.35"           -- old
        FAKE.proc_osrelease = "5.4.0"     -- would say modern, must be ignored
        assert.are.equal("old", fresh_legacy().kernelState())
    end)
    it("is 'unknown' only when all three sources fail", function()
        FAKE.uname_r = "linux"
        FAKE.proc_osrelease = nil
        FAKE.proc_version = nil
        assert.are.equal("unknown", fresh_legacy().kernelState())
    end)
end)

describe("Legacy.recommendedVersion (<2.6.32 -> v1.2.2, else v1.27.12)", function()
    before_each(reinstall_mocks)
    local cases = {
        { "2.6.18", "v1.2.2" }, { "2.6.31", "v1.2.2" }, { "2.5.0", "v1.2.2" },
        { "2.6", "v1.2.2" }, { "1.0.0", "v1.2.2" }, { "0.9.0", "v1.2.2" },
        { "2.6.32", "v1.27.12" }, { "2.6.35", "v1.27.12" }, { "3.0.35", "v1.27.12" },
        { "3.1.10", "v1.27.12" }, { "3.2.0", "v1.27.12" }, { "5.4.0", "v1.27.12" },
        { "", "v1.27.12" }, { "garbage", "v1.27.12" }, { "3", "v1.27.12" },
    }
    for _, c in ipairs(cases) do
        it("recommends " .. c[2] .. " for kernel '" .. c[1] .. "'", function()
            FAKE.uname_r = c[1]
            assert.are.equal(c[2], fresh_legacy().recommendedVersion())
        end)
    end
end)

describe("session caching", function()
    before_each(reinstall_mocks)
    it("reads uname once: a later change is not observed", function()
        FAKE.uname_r = "3.0.0"
        local L = fresh_legacy()
        assert.are.equal("old", L.kernelState())
        FAKE.uname_r = "5.0.0"
        assert.are.equal("old", L.kernelState())   -- cached, not re-read
        FAKE.uname_r = "3.0.35"
    end)
end)

describe("Legacy.getVersion / needsPatch (shim gate)", function()
    before_each(reinstall_mocks)
    it("getVersion defaults to v1.27.12 when unset", function()
        reset_settings()
        assert.are.equal("v1.27.12", fresh_legacy().getVersion())
    end)
    it("getVersion reflects the setting", function()
        reset_settings(); SETTINGS["syncthing_legacy_version"] = "v1.2.2"
        assert.are.equal("v1.2.2", fresh_legacy().getVersion())
    end)
    it("v1.2.2 needs the patch", function()
        reset_settings(); SETTINGS["syncthing_legacy_version"] = "v1.2.2"
        assert.is_true(fresh_legacy().needsPatch())
    end)
    it("v1.27.12 does not need the patch", function()
        reset_settings(); SETTINGS["syncthing_legacy_version"] = "v1.27.12"
        assert.is_false(fresh_legacy().needsPatch())
    end)
    it("an unknown version is treated as not needing the patch", function()
        reset_settings(); SETTINGS["syncthing_legacy_version"] = "v9.9.9"
        assert.is_false(fresh_legacy().needsPatch())
    end)
end)

describe("Legacy.downloadBinary URL/asset construction", function()
    before_each(reinstall_mocks)
    local arch_cases = {
        { "aarch64", "arm64" }, { "arm64", "arm64" }, { "x86_64", "amd64" },
        { "i686", "386" }, { "i386", "386" }, { "armv7l", "arm" },
        { "armv6l", "arm" }, { "totally-unknown", "arm" },
    }
    for _, c in ipairs(arch_cases) do
        it("arch " .. c[1] .. " -> syncthing-linux-" .. c[2], function()
            reset_exec(); FAKE.uname_m = c[1]; FAKE.cacert = true; FAKE.curl = false
            fresh_legacy().downloadBinary({ _invalidateBinaryCache = noop }, "v1.27.12", noop)
            local want = ("https://github.com/syncthing/syncthing/releases/download/"
                       .. "v1.27.12/syncthing-linux-%s-v1.27.12.tar.gz"):format(c[2])
            assert.is_truthy(find_log(want))
        end)
    end
    it("embeds the version verbatim as tag and in the filename (v1.2.2)", function()
        reset_exec(); FAKE.uname_m = "armv7l"
        fresh_legacy().downloadBinary({ _invalidateBinaryCache = noop }, "v1.2.2", noop)
        assert.is_truthy(find_log("/releases/download/v1.2.2/syncthing-linux-arm-v1.2.2.tar.gz"))
    end)
end)

describe("Legacy.downloadBinary state machine + error handling", function()
    before_each(reinstall_mocks)
    local function self_obj() return { _invalidateBinaryCache = function() FAKE.bin_invalidated = true end } end

    it("success: records installed version, invalidates cache, callback(true)", function()
        reset_exec(); reset_settings()
        FAKE.cacert = true; FAKE.curl = false; FAKE.unpack = true
        FAKE.find_result = "/tmp/x/syncthing"; FAKE.bin_invalidated = false
        local cb_ok, cb_err
        fresh_legacy().downloadBinary(self_obj(), "v1.27.12", function(o, e) cb_ok, cb_err = o, e end)
        assert.is_true(cb_ok)
        assert.is_nil(cb_err)
        assert.are.equal("v1.27.12", SETTINGS["syncthing_legacy_installed_version"])
        assert.is_truthy(find_log("mv "))
        assert.is_truthy(find_log("chmod +x"))
        assert.is_true(FAKE.bin_invalidated)
    end)
    it("cacert missing: refuses before any download, nothing installed", function()
        reset_exec(); reset_settings(); FAKE.cacert = true
        local L = fresh_legacy(); FAKE.cacert = false
        local cb_ok = "unset"
        L.downloadBinary(self_obj(), "v1.27.12", function(o) cb_ok = o end)
        assert.is_false(cb_ok)
        assert.is_nil(find_log("wget"))
        assert.is_nil(SETTINGS["syncthing_legacy_installed_version"])
        FAKE.cacert = true
    end)
    it("download fails (wget fails, no curl): callback(false), nothing installed", function()
        reset_exec(); reset_settings(); EXEC_FAIL = { "wget" }; FAKE.curl = false
        local cb_ok = "unset"
        fresh_legacy().downloadBinary(self_obj(), "v1.27.12", function(o) cb_ok = o end)
        assert.is_false(cb_ok)
        assert.is_nil(SETTINGS["syncthing_legacy_installed_version"])
        EXEC_FAIL = {}
    end)
    it("extraction fails (both archiver and tar): callback(false), nothing installed", function()
        -- Extraction now has two stages: selective extraction via ffi/archiver,
        -- then system tar as a fallback.  "Extraction failed" therefore means
        -- both of them failed.
        reset_exec(); reset_settings(); FAKE.unpack = false; EXEC_FAIL = { "tar" }
        local cb_ok = "unset"
        fresh_legacy().downloadBinary(self_obj(), "v1.27.12", function(o) cb_ok = o end)
        assert.is_false(cb_ok)
        assert.is_nil(SETTINGS["syncthing_legacy_installed_version"])
        FAKE.unpack = true; EXEC_FAIL = {}
    end)

    it("archiver unavailable: falls back to system tar and installs", function()
        -- Old KOReader builds may lack ffi/archiver; legacy mode runs on the
        -- oldest devices, so the tar fallback must carry the install through.
        reset_exec(); reset_settings(); FAKE.unpack = false
        local cb_ok, cb_err
        fresh_legacy().downloadBinary(self_obj(), "v1.27.12", function(o, e) cb_ok, cb_err = o, e end)
        assert.is_true(cb_ok)
        assert.is_nil(cb_err)
        assert.are.equal("v1.27.12", SETTINGS["syncthing_legacy_installed_version"])
        -- The fallback must unpack with --strip-components=1 and no member
        -- pattern: GNU tar rejects a pattern without --wildcards, and busybox
        -- tar has no --wildcards at all.
        local tar_cmd = find_log("tar -xzf")
        assert.is_truthy(tar_cmd)
        assert.is_truthy(tar_cmd:find("--strip-components=1", 1, true))
        assert.is_nil(tar_cmd:find("*/syncthing", 1, true))
        FAKE.unpack = true
    end)
    it("extracted file is not an ELF: callback(false), nothing installed", function()
        -- Was "binary not found in archive" back when the binary was located
        -- with `find` after unpacking the whole tree.  Extraction is now
        -- selective, so the equivalent failure is: something was extracted but
        -- it is not a Linux executable.
        reset_exec(); reset_settings(); FAKE.is_elf = false
        local cb_ok = "unset"
        fresh_legacy().downloadBinary(self_obj(), "v1.27.12", function(o) cb_ok = o end)
        assert.is_false(cb_ok)
        assert.is_nil(SETTINGS["syncthing_legacy_installed_version"])
        FAKE.is_elf = nil
    end)
    it("install (mv) fails on read-only fs: callback(false), nothing installed", function()
        -- The first mv is to a .new staging file; fail only that one.
        reset_exec(); reset_settings(); EXEC_FAIL = { "syncthing-legacy.new'" }
        local cb_ok = "unset"
        fresh_legacy().downloadBinary(self_obj(), "v1.27.12", function(o) cb_ok = o end)
        assert.is_false(cb_ok)
        assert.is_nil(SETTINGS["syncthing_legacy_installed_version"])
        EXEC_FAIL = {}
    end)
    it("chmod fails (noexec): removes staging file, records nothing", function()
        reset_exec(); reset_settings(); EXEC_FAIL = { "chmod" }
        local cb_ok = "unset"
        fresh_legacy().downloadBinary(self_obj(), "v1.27.12", function(o) cb_ok = o end)
        assert.is_false(cb_ok)
        assert.is_nil(SETTINGS["syncthing_legacy_installed_version"])
        -- cleanup() removes the staging file (.new), not the live binary
        assert.is_truthy(find_log("rm -f '/PLUG/syncthing-legacy.new'"))
        EXEC_FAIL = {}
    end)
    it("curl fallback succeeds when wget is missing", function()
        reset_exec(); reset_settings(); EXEC_FAIL = { "wget" }; FAKE.curl = true; FAKE.cacert = true
        local cb_ok = "unset"
        fresh_legacy().downloadBinary(self_obj(), "v1.27.12", function(o) cb_ok = o end)
        assert.is_true(cb_ok)
        assert.is_truthy(find_log("curl"))
        EXEC_FAIL = {}; FAKE.curl = false
    end)
end)

describe("Legacy.enable / disable (settings + cache invalidation)", function()
    before_each(reinstall_mocks)
    it("enable(): sets use_legacy + version, clears api_key, invalidates caches", function()
        reset_settings()
        local calls = {}
        local self = {
            api_key = "STALE",
            _invalidateDeviceIdCache = function() calls.devid = true end,
            _invalidateBinaryCache   = function() calls.bin = true end,
        }
        FAKE.data_dir_invalidated = false
        fresh_legacy().enable(self, "v1.2.2")
        assert.is_true(SETTINGS["syncthing_use_legacy"])
        assert.are.equal("v1.2.2", SETTINGS["syncthing_legacy_version"])
        assert.is_nil(self.api_key)
        assert.is_true(calls.devid)
        assert.is_true(calls.bin)
        assert.is_true(FAKE.data_dir_invalidated)
    end)
    it("enable(nil) defaults to v1.27.12", function()
        reset_settings()
        fresh_legacy().enable({ _invalidateDeviceIdCache = noop, _invalidateBinaryCache = noop }, nil)
        assert.are.equal("v1.27.12", SETTINGS["syncthing_legacy_version"])
    end)
    it("disable(): clears use_legacy but KEEPS the version setting", function()
        reset_settings()
        SETTINGS["syncthing_use_legacy"] = true
        SETTINGS["syncthing_legacy_version"] = "v1.2.2"
        local calls = {}; FAKE.data_dir_invalidated = false
        local self = {
            api_key = "STALE",
            _invalidateDeviceIdCache = function() calls.devid = true end,
            _invalidateBinaryCache   = function() calls.bin = true end,
        }
        fresh_legacy().disable(self)
        assert.is_nil(SETTINGS["syncthing_use_legacy"])
        assert.are.equal("v1.2.2", SETTINGS["syncthing_legacy_version"])
        assert.is_nil(self.api_key)
        assert.is_true(calls.devid and calls.bin and FAKE.data_dir_invalidated)
    end)
end)

describe("Legacy.patchSyncthingObject (v1.2.2 read-modify-write shim)", function()
    before_each(function()
        reinstall_mocks()
        reset_settings()
        reset_exec()
    end)
    -- a fresh fake Syncthing CLASS: recording originals + GET/PUT stubs
    local function make_class()
        local rec_orig = {}
        local function orig(name) return function() rec_orig[name] = true; return "ORIG:" .. name end end
        local last_put, get_calls = nil, {}
        local C = {
            getConfig = orig("getConfig"), getFolders = orig("getFolders"),
            getDevices = orig("getDevices"), getOptions = orig("getOptions"),
            patchFolder = orig("patchFolder"), patchDevice = orig("patchDevice"),
            patchOptions = orig("patchOptions"), addDevice = orig("addDevice"),
            addFolder = orig("addFolder"), deleteFolder = orig("deleteFolder"),
        }
        C.GET = function(_, ep)
            get_calls[#get_calls + 1] = ep
            if ep == "system/config" then
                return { ok = true, data = {
                    folders = { { id = "f1", copiers = 0 }, { id = "f2" } },
                    devices = { { deviceID = "DEV1" } },
                    options = { globalAnnounceEnabled = true },
                } }
            end
            return { ok = false, error = "404" }
        end
        C.PUT = function(_, ep, body) last_put = { ep = ep, body = body }; return { ok = true } end
        return C, rec_orig, function() return last_put end, get_calls
    end

    it("is idempotent: a second patch does not re-wrap", function()
        local C = make_class()
        local L = fresh_legacy()
        L.patchSyncthingObject(C)
        local first = C.getConfig
        L.patchSyncthingObject(C)
        assert.are.equal(first, C.getConfig)
    end)
    it("standard mode (legacy off): wrappers fall through to originals", function()
        reset_settings()
        local C, ro = make_class()
        fresh_legacy().patchSyncthingObject(C)
        C:getConfig(); C:getFolders(); C:patchOptions({})
        assert.is_truthy(ro.getConfig and ro.getFolders and ro.patchOptions)
    end)
    it("v1.27.12 (modern API): wrappers fall through to originals", function()
        reset_settings()
        SETTINGS["syncthing_use_legacy"] = true
        SETTINGS["syncthing_legacy_version"] = "v1.27.12"
        local C, ro = make_class()
        fresh_legacy().patchSyncthingObject(C)
        C:getConfig(); C:patchFolder("f1", { copiers = 2 })
        assert.is_truthy(ro.getConfig and ro.patchFolder)
    end)
    it("v1.2.2: getConfig/getFolders/getOptions read via system/config", function()
        reset_settings()
        SETTINGS["syncthing_use_legacy"] = true
        SETTINGS["syncthing_legacy_version"] = "v1.2.2"
        local C, ro, _, getcalls = make_class()
        fresh_legacy().patchSyncthingObject(C)
        local cfg = C:getConfig()
        assert.is_falsy(ro.getConfig)
        assert.is_not_nil(cfg and cfg.folders)
        assert.are.equal("system/config", getcalls[#getcalls])
        assert.are.equal("f1", C:getFolders()[1].id)
        assert.is_true(C:getOptions().globalAnnounceEnabled)
    end)
    it("v1.2.2 patchFolder: read-modify-write PUTs the change to system/config", function()
        reset_settings()
        SETTINGS["syncthing_use_legacy"] = true
        SETTINGS["syncthing_legacy_version"] = "v1.2.2"
        local C, _, getput = make_class()
        fresh_legacy().patchSyncthingObject(C)
        assert.is_true(U.isOk(C:patchFolder("f1", { copiers = 7 })))
        local put = getput()
        assert.are.equal("system/config", put.ep)
        local applied = false
        for _, f in ipairs(put.body.folders) do
            if f.id == "f1" and f.copiers == 7 then applied = true end
        end
        assert.is_true(applied)
    end)
    it("v1.2.2 addDevice: de-duplicates and appends", function()
        reset_settings()
        SETTINGS["syncthing_use_legacy"] = true
        SETTINGS["syncthing_legacy_version"] = "v1.2.2"
        local C, _, getput = make_class()
        fresh_legacy().patchSyncthingObject(C)
        C:addDevice({ deviceID = "DEV1" })            -- already present
        assert.are.equal(1, #getput().body.devices)
        C:addDevice({ deviceID = "DEV2" })            -- new
        assert.are.equal(2, #getput().body.devices)
    end)
    it("v1.2.2 deleteFolder: removes the matching folder", function()
        reset_settings()
        SETTINGS["syncthing_use_legacy"] = true
        SETTINGS["syncthing_legacy_version"] = "v1.2.2"
        local C, _, getput = make_class()
        fresh_legacy().patchSyncthingObject(C)
        C:deleteFolder("f1")
        local present = false
        for _, f in ipairs(getput().body.folders) do if f.id == "f1" then present = true end end
        assert.is_false(present)
    end)
    it("v1.2.2: graceful nil/error when the GET fails", function()
        reset_settings()
        SETTINGS["syncthing_use_legacy"] = true
        SETTINGS["syncthing_legacy_version"] = "v1.2.2"
        local C = make_class()
        fresh_legacy().patchSyncthingObject(C)
        C.GET = function() return { ok = false, error = "boom" } end
        assert.is_nil(C:getConfig())
        assert.is_false(U.isOk(C:patchFolder("f1", { x = 1 })))
    end)
end)
