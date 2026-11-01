-- st_datadir_spec.lua – tests for the database-directory resolver (AD-19).
--
-- The hard_remove FUSE failure that motivates this code cannot be reproduced
-- in a plain unit test (it needs a real libfuse mount), so resolveDataDir
-- exposes `probe` and `free_space` injection seams.  These specs drive the
-- decision logic through those seams; the REAL behavioural probe is validated
-- end-to-end against a libfuse `hard_remove` mount outside the unit suite.

local Mock = require("spec.spec_helper")

-- Load the REAL st_utils, not the mock that spec_helper preloads.  We save and
-- restore the mock's preload/loaded entries so that sibling specs sharing this
-- Lua state keep getting the mock; only this spec holds the real module.
local function realUtils()
    local saved_loaded  = package.loaded["st_utils"]
    local saved_preload = package.preload["st_utils"]
    package.loaded["st_utils"]  = nil
    package.preload["st_utils"] = nil
    local real = require("st_utils")
    package.loaded["st_utils"]  = saved_loaded
    package.preload["st_utils"] = saved_preload
    return real
end

-- A real, writable temp directory (resolveDataDir's _ensureWritableDir does a
-- real io.open, so candidate parents must exist on disk).
local function mktempdir()
    local p = os.tmpname()
    os.remove(p)
    os.execute("mkdir -p '" .. p .. "'")
    return p
end

local CFG = "/tmp/koreader/settings/syncthing"   -- stand-in config dir

describe("resolveDataDir (AD-19)", function()
    local U
    before_each(function()
        Mock.reset()
        U = realUtils()
    end)

    it("stays on the config dir when the filesystem is healthy", function()
        local dir, reason = U.resolveDataDir(CFG, {
            probe = function() return false end,           -- nothing is broken
            candidates = { "/var/local/kosyncthing_plus" },
        })
        assert.are.equal(CFG, dir)
        assert.are.equal("clean", reason)
    end)

    it("relocates to a roomy candidate when the config dir is broken", function()
        local parent = mktempdir()
        local cand   = parent .. "/kosyncthing_plus"
        local dir, reason, note = U.resolveDataDir(CFG, {
            probe = function(d) return d == CFG end,       -- only config dir broken
            free_space = function() return 400 * 1024 * 1024 end,
            candidates = { cand },
        })
        assert.are.equal(cand, dir)
        assert.are.equal("redirected", reason)
        assert.is_nil(note)
    end)

    it("accepts a tight candidate (>= minimum, < comfort) with a note", function()
        local parent = mktempdir()
        local cand   = parent .. "/kosyncthing_plus"
        local dir, reason, note = U.resolveDataDir(CFG, {
            probe = function(d) return d == CFG end,
            free_space = function() return 40 * 1024 * 1024 end,   -- 40 MB
            candidates = { cand },
        })
        assert.are.equal(cand, dir)
        assert.are.equal("redirected_tight", reason)
        assert.is_truthy(note)
    end)

    it("rejects a candidate below the minimum and warns", function()
        local parent = mktempdir()
        local cand   = parent .. "/kosyncthing_plus"
        local dir, reason = U.resolveDataDir(CFG, {
            probe = function(d) return d == CFG end,
            free_space = function() return 5 * 1024 * 1024 end,    -- 5 MB
            candidates = { cand },
        })
        assert.are.equal(CFG, dir)
        assert.are.equal("fallback_warn", reason)
    end)

    it("warns when broken and no candidate exists (e.g. non-Kindle)", function()
        local dir, reason = U.resolveDataDir(CFG, {
            probe = function() return true end,
            candidates = {},
        })
        assert.are.equal(CFG, dir)
        assert.are.equal("fallback_warn", reason)
    end)

    it("reuses a valid sticky directory without consulting candidates", function()
        local sticky = mktempdir()
        local dir, reason = U.resolveDataDir(CFG, {
            sticky = sticky,
            probe = function(d) return d == CFG end,       -- config broken, sticky clean
            candidates = {},                               -- must not be needed
        })
        assert.are.equal(sticky, dir)
        assert.are.equal("sticky", reason)
    end)

    it("ignores a sticky directory that is itself broken", function()
        local sticky = mktempdir()
        local parent = mktempdir()
        local cand   = parent .. "/kosyncthing_plus"
        local dir, reason = U.resolveDataDir(CFG, {
            sticky = sticky,
            probe = function(d) return d == CFG or d == sticky end,  -- sticky broken too
            free_space = function() return 400 * 1024 * 1024 end,
            candidates = { cand },
        })
        assert.are.equal(cand, dir)
        assert.are.equal("redirected", reason)
    end)
end)

describe("unlinkWriteBroken (real probe, healthy fs)", function()
    local U
    before_each(function() Mock.reset(); U = realUtils() end)

    it("returns false on a normal writable directory", function()
        local d = mktempdir()
        assert.is_false(U.unlinkWriteBroken(d))
    end)

    it("returns false (not an error) when the directory is unwritable/absent", function()
        -- Cannot create the probe file → this is NOT the hard_remove failure,
        -- so the function must report 'not broken' rather than a false positive.
        assert.is_false(U.unlinkWriteBroken("/nonexistent/path/xyz"))
    end)
end)

describe("getDataDir cache + invalidateDataDirCache (AD-19)", function()
    local U
    before_each(function() Mock.reset(); U = realUtils() end)

    it("ignores an obsolete mode setting left by an older plugin version", function()
        -- The config dir does not exist on disk, so the real probe cannot
        -- create its test file and correctly reports 'not broken'.
        local d1 = U.getDataDir()

        -- A stale setting must not switch paths, either before or after the
        -- session cache is invalidated.
        G_reader_settings:saveSetting("syncthing_use_legacy", true)
        local d2 = U.getDataDir()
        assert.are.equal(d1, d2)

        U.invalidateDataDirCache()
        local d3 = U.getDataDir()
        assert.is_nil(d3:find("syncthing%-legacy", 1))
        assert.are.equal(d1, d3)
    end)
end)
