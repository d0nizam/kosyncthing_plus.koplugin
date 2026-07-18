-- st_plugin_update_spec.lua — unit tests for the pure logic of the plugin
-- self-updater (version parsing/compare, asset selection, markdown stripping,
-- installed-version read).  The I/O + UI flow (check/install) needs a live
-- device, GitHub and a restart, so it is not exercised here.

-- ───────────────────── stub the KOReader runtime ──────────────────────
local noop = function() end
package.loaded["ui/widget/confirmbox"]  = { new = function(_, t) return t end }
package.loaded["ui/widget/infomessage"] = { new = function(_, t) return t end }
package.loaded["ui/widget/textviewer"]  = { new = function(_, t) return t end }
package.loaded["device"] = {
    canOpenLink  = function() return false end,
    openLink     = noop,
    unpackArchive = function() return true end,
    restartKOReader = noop,
}
package.loaded["ui/uimanager"] = { show = noop, close = noop, scheduleIn = function() end }
package.loaded["ui/network/manager"] = { runWhenOnline = function() end }
package.loaded["ffi/util"] = { template = function(s) return s end }
package.loaded["logger"] = setmetatable({}, { __index = function() return noop end })
package.loaded["syncthing_i18n"] = { gettext = function(s) return s end }
package.loaded["json"] = { decode = function() return nil end }
package.loaded["st_utils"] = {
    plugin_path = "/tmp/",
    fileSize    = function() return 0 end,
    isZip       = function() return true end,
    unpackArchive = function() return true end,
}
package.loaded["st_update"] = { downloadFile = function() return true end }

local M = require("st_plugin_update")

local function same_list(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

-- ───────────────────────────── parseVersion ─────────────────────────────
describe("parseVersion", function()
    it("strips a leading v and splits on dots", function()
        assert.is_true(same_list({ 1, 2, 3 }, M.parseVersion("v1.2.3")))
        assert.is_true(same_list({ 1, 2, 3 }, M.parseVersion("1.2.3")))
        assert.is_true(same_list({ 2 },       M.parseVersion("v2")))
        assert.is_true(same_list({ 1, 0 },    M.parseVersion("1.0")))
    end)
    it("treats non-numeric components as 0", function()
        assert.is_true(same_list({ 0 }, M.parseVersion("garbage")))
        assert.is_true(same_list({ 1, 0, 4 }, M.parseVersion("1.x.4")))
    end)
end)

-- ─────────────────────────────── isNewer ────────────────────────────────
describe("isNewer", function()
    it("is true only for a strictly higher version", function()
        assert.is_true (M.isNewer("v1.2.0", "v1.1.6"))
        assert.is_true (M.isNewer("v2.0.0", "v1.9.9"))
        assert.is_false(M.isNewer("v1.1.6", "v1.1.6"))
        assert.is_false(M.isNewer("v1.1.5", "v1.1.6"))
        assert.is_false(M.isNewer("v1.1.6", "v1.2.0"))
    end)
    it("compares components numerically, not lexically", function()
        assert.is_true (M.isNewer("v1.10.0", "v1.9.0"))   -- 10 > 9
        assert.is_false(M.isNewer("v1.9.0",  "v1.10.0"))
    end)
    it("handles differing component counts", function()
        assert.is_true (M.isNewer("v1.2.1", "v1.2"))      -- 1.2.1 > 1.2
        assert.is_false(M.isNewer("v1.2.0", "v1.2"))      -- 1.2.0 == 1.2
    end)
end)

-- ────────────────────────────── selectAsset ─────────────────────────────
describe("selectAsset", function()
    it("prefers a .zip asset and does NOT strip the root (flat zip)", function()
        local url, strip = M.selectAsset({
            assets = { { name = "kosyncthing_plus_koplugin.zip",
                         browser_download_url = "https://x/asset.zip" } },
            zipball_url = "https://x/zipball",
        })
        assert.are.equal("https://x/asset.zip", url)
        assert.is_false(strip)
    end)
    it("falls back to the zipball and strips the root (wrapped)", function()
        local url, strip = M.selectAsset({
            assets = { { name = "notes.txt", browser_download_url = "https://x/notes" } },
            zipball_url = "https://x/zipball",
        })
        assert.are.equal("https://x/zipball", url)
        assert.is_true(strip)
    end)
    it("returns nil when there is neither a zip asset nor a zipball", function()
        local url, strip = M.selectAsset({ assets = {} })
        assert.is_nil(url)
        assert.is_nil(strip)
    end)
end)

-- ───────────────────────────── stripMarkdown ────────────────────────────
describe("stripMarkdown", function()
    it("removes headings, bold, italic and inline code markers", function()
        assert.are.equal("Head\nbold it code",
            M.stripMarkdown("# Head\n**bold** *it* `code`"))
    end)
    it("is safe on nil", function()
        assert.are.equal("", M.stripMarkdown(nil))
    end)
end)

-- ─────────────────────── getInstalledPluginVersion ──────────────────────
describe("getInstalledPluginVersion", function()
    local fixture = "/tmp/kosyncthing_plus_meta_fixture.lua"
    it("reads version from a _meta.lua", function()
        local f = io.open(fixture, "w")
        f:write('return { version = "v9.9.9" }')
        f:close()
        assert.are.equal("v9.9.9", M.getInstalledPluginVersion(fixture))
        os.remove(fixture)
    end)
    it("returns 'unknown' when the file is missing or malformed", function()
        assert.are.equal("unknown", M.getInstalledPluginVersion("/tmp/does_not_exist_meta.lua"))
    end)
end)

-- ───────────────────────────── temp paths ───────────────────────────────
-- /tmp does not exist on Android; the release-JSON temp must derive from the
-- plugin folder (U.plugin_path) instead.  Guards against re-introducing the
-- hardcoded path that made the Android updater fail with "No such file".
describe("temp paths", function()
    it("uses no hardcoded /tmp path", function()
        local f = io.open("st_plugin_update.lua", "r")
        if not f then return end   -- source not locatable in this runner; skip
        local src = f:read("*a"); f:close()
        assert.is_nil(src:find('"/tmp/', 1, true))
    end)
end)
