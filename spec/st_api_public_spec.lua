-- st_api_public_spec.lua – tests for the IgnoreRegistry companion API.
--
-- IgnoreRegistry lets a companion plugin register a LIST of filename globs so
-- the conflict scanner skips that plugin's own conflict copies.  A conflict
-- file is matched by DE-MANGLING it to its original name first, so a companion
-- registers plain names/globs ("state.lua", "*.sdr") and need not encode
-- Syncthing's ".sync-conflict-…"/"~sync-conflict-…" mangling.  Both conflict
-- scanners (st_sync find post-filter and st_android lfs) call the same
-- matchesConflictBasename, so this one spec covers the shared rule.

local Mock = require("spec.spec_helper")

-- We test the REAL module.  mock_koreader preloads a lightweight fake for
-- OTHER specs, so clear it and load the real file.  The module selects JSON
-- via rapidjson → json; the registry methods never touch JSON, so a tiny stub
-- satisfies the require.
package.preload["json"] = package.preload["json"]
    or function() return { encode = function() return "" end,
                           decode = function() return {} end } end
package.loaded["st_api_public"]  = nil
package.preload["st_api_public"] = nil
local PublicAPI      = require("st_api_public")
local IgnoreRegistry = PublicAPI.IgnoreRegistry

-- In-memory store, injected so _load() returns it directly (no LuaSettings,
-- no filesystem, no migration).
local function fakeStore()
    local data = {}
    return {
        readSetting = function(_, k) return data[k] end,
        saveSetting = function(_, k, v) data[k] = v end,
        flush       = function() end,
        _data       = data,
    }
end

local function fresh()
    IgnoreRegistry._store      = fakeStore()
    IgnoreRegistry._generation = 0
    return IgnoreRegistry
end

-- This runner's assert.are.same is REFERENCE equality, so compare lists by hand.
local function same_list(expected, actual)
    assert.is_not_nil(actual)
    assert.are.equal(#expected, #actual)
    for i = 1, #expected do assert.are.equal(expected[i], actual[i]) end
end

-- Build a realistic Syncthing conflict basename from an original name.
--   conflict("state.lua")        -> "state.sync-conflict-20260101-120000-ABCDEFG.lua"
--   conflict("state.lua", "~")   -> "state~sync-conflict-20260101-120000-ABCDEFG.lua"
--   conflict("metadata.epub.lua")-> "metadata.epub.sync-conflict-…-ABCDEFG.lua"
local function conflict(original, sep)
    sep = sep or "."
    local stamp = sep .. "sync-conflict-20260101-120000-ABCDEFG"
    local stem, ext = original:match("^(.*)(%.[^.]+)$")
    if stem then return stem .. stamp .. ext end
    return original .. stamp
end

describe("IgnoreRegistry.register", function()
    it("accepts a single string and stores it as a one-element list", function()
        local R = fresh()
        assert.is_true(R:register("syncery", "state.lua"))
        same_list({ "state.lua" }, R:getAll().syncery)
    end)

    it("accepts a list and de-duplicates it", function()
        local R = fresh()
        assert.is_true(R:register("syncery", { "*.sdr", "state.lua", "*.sdr" }))
        same_list({ "*.sdr", "state.lua" }, R:getAll().syncery)
    end)

    it("REPLACES the plugin's set (does not append)", function()
        local R = fresh()
        R:register("syncery", { "a.lua", "b.lua" })
        R:register("syncery", { "c.lua" })
        same_list({ "c.lua" }, R:getAll().syncery)
    end)

    it("keeps plugins independent", function()
        local R = fresh()
        R:register("syncery", { "*.sdr" })
        R:register("bookends", { "*.bem" })
        same_list({ "*.sdr" }, R:getAll().syncery)
        same_list({ "*.bem" }, R:getAll().bookends)
    end)

    it("is idempotent: re-registering an identical set does not bump generation", function()
        local R = fresh()
        R:register("syncery", { "a.lua", "b.lua" })
        local g1 = R:getGeneration()
        R:register("syncery", { "a.lua", "b.lua" })
        assert.are.equal(g1, R:getGeneration())
        R:register("syncery", { "a.lua", "c.lua" })          -- different -> bump
        assert.are.equal(g1 + 1, R:getGeneration())
    end)

    it("rejects an empty list, an empty entry, a non-string entry, and an empty id", function()
        local R = fresh()
        assert.is_false(R:register("syncery", {}))
        assert.is_false(R:register("syncery", { "ok.lua", "" }))
        assert.is_false(R:register("syncery", { "ok.lua", 5 }))
        assert.is_false(R:register("", { "x" }))
        assert.is_nil(next(R:getAll()))                      -- nothing was stored
    end)

    it("accepts a glob containing an apostrophe (matching is pure Lua; globs never reach a shell)", function()
        local R = fresh()
        assert.is_true(R:register("music", { "Rock'n'Roll.epub.sdr" }))
        assert.is_true(R:matchesConflictBasename(conflict("Rock'n'Roll.epub.sdr")))
    end)
end)

describe("IgnoreRegistry.unregister / isRegistered", function()
    it("removes a plugin and reports membership", function()
        local R = fresh()
        R:register("syncery", { "*.sdr" })
        assert.is_true(R:isRegistered("syncery"))
        assert.is_false(R:isRegistered("ghost"))
        assert.is_true(R:unregister("syncery"))
        assert.is_false(R:isRegistered("syncery"))
        assert.is_nil(next(R:getAll()))
    end)
end)

describe("IgnoreRegistry.getAll", function()
    it("returns a copy; mutating it does not change the registry", function()
        local R = fresh()
        R:register("syncery", { "*.sdr" })
        local snap = R:getAll()
        snap.syncery[#snap.syncery + 1] = "injected"
        snap.intruder = { "x" }
        same_list({ "*.sdr" }, R:getAll().syncery)
        assert.is_nil(R:getAll().intruder)
    end)
end)

describe("IgnoreRegistry:matchesConflictBasename", function()
    it("matches an exact-name pattern's conflict copy", function()
        local R = fresh()
        R:register("syncery", { "state.lua" })
        assert.is_true(R:matchesConflictBasename(conflict("state.lua")))
        assert.is_false(R:matchesConflictBasename(conflict("other.lua")))
    end)

    it("matches a glob pattern's conflict copy", function()
        local R = fresh()
        R:register("syncery", { "*.sdr" })
        assert.is_true(R:matchesConflictBasename(conflict("book.sdr")))
        assert.is_false(R:matchesConflictBasename(conflict("book.epub")))
    end)

    it("matches BOTH the '.' and '~' conflict separators", function()
        local R = fresh()
        R:register("syncery", { "state.lua" })
        assert.is_true(R:matchesConflictBasename(conflict("state.lua", ".")))
        assert.is_true(R:matchesConflictBasename(conflict("state.lua", "~")))
    end)

    it("handles a multi-dot original (metadata.epub.lua)", function()
        local R = fresh()
        R:register("syncery", { "metadata.epub.lua" })
        assert.is_true(R:matchesConflictBasename(conflict("metadata.epub.lua")))
    end)

    it("returns false for a non-conflict name and when nothing is registered", function()
        local R = fresh()
        assert.is_false(R:matchesConflictBasename("state.lua"))       -- empty registry
        R:register("syncery", { "state.lua" })
        assert.is_false(R:matchesConflictBasename("state.lua"))       -- not a conflict copy
        assert.is_false(R:matchesConflictBasename(""))
        assert.is_false(R:matchesConflictBasename(nil))
    end)

    it("ignores a name with the substring but no '.'/'~' separator (not a real conflict copy)", function()
        local R = fresh()
        R:register("companion", { "*.json" })
        -- "sync-conflict-" is present as a substring, but there is no "." / "~"
        -- separator, so this is a user file, not a Syncthing conflict copy.
        assert.is_false(R:matchesConflictBasename("notes-sync-conflict-draft.json"))
        -- a genuine conflict copy of a *.json original is still matched:
        assert.is_true(R:matchesConflictBasename(conflict("notes.json")))
    end)

    it("does not crash on a stray pre-v2 string value in the store", function()
        local R = fresh()
        -- A pre-v2 value that somehow bypassed migration must be skipped, not error.
        R._store:saveSetting("patterns", { stale = "string-not-a-list", syncery = { "*.sdr" } })
        assert.is_true(R:matchesConflictBasename(conflict("book.sdr")))
        same_list({ "*.sdr" }, R:getAll().syncery)                   -- string value dropped from copy
    end)
end)

describe("Public API 1.1.1 surface", function()
    it("reports 1.1.1 and omits the removed mode-selection methods", function()
        PublicAPI.buildPublicAPI({})
        assert.are.equal("1.1.1", PublicAPI.api.version)
        assert.are.equal("1.1.1", IgnoreRegistry.getApiVersion())
        assert.is_nil(PublicAPI.api.info.isLegacyMode)
        assert.is_nil(PublicAPI.api.info.getLegacyVersion)
    end)
end)
