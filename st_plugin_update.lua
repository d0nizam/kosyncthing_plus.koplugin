-- st_plugin_update.lua — update the KOSyncthing+ plugin itself from GitHub.
--
-- This is distinct from st_update.lua, which downloads/updates the bundled
-- Syncthing *binary*.  Here we fetch the plugin's own latest GitHub release,
-- show the release notes, download the archive, unpack it in place over the
-- plugin directory, and offer to restart KOReader to load the new code.
--
-- In-place unpack preserves files that are NOT in the archive — the downloaded
-- `syncthing` binary, the on-disk config (which lives under settings/, not the
-- plugin dir), and anything else the archive does not overwrite.  A file that a
-- future version deletes will linger as a harmless orphan until a reinstall;
-- this is an accepted trade-off of unpack-over-in-place (KOReader only loads
-- main.lua plus the modules it requires).

local ConfirmBox  = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Device      = require("device")
local UIManager   = require("ui/uimanager")
local NetworkMgr  = require("ui/network/manager")
local ffiutil     = require("ffi/util")
local logger      = require("logger")
local U           = require("st_utils")
local _           = require("syncthing_i18n").gettext
local T           = ffiutil.template

local rapidjson_ok, rapidjson = pcall(require, "rapidjson")
local JSON = rapidjson_ok and rapidjson or require("json")

local REPO          = "d0nizam/kosyncthing_plus.koplugin"
local API_LATEST    = "https://api.github.com/repos/" .. REPO .. "/releases/latest"
local RELEASES_PAGE = "https://github.com/" .. REPO .. "/releases"
local TMP_JSON      = U.plugin_path .. "plugin_release.json"
local TMP_ZIP       = U.plugin_path .. "plugin_update.zip"
local MIN_ZIP_SIZE  = 4096   -- a real plugin zip is far larger; a stray error
                             -- body would be tiny.

local M = {}

---------------------------------------------------------------------------
-- Pure helpers (no I/O, no UI) — unit-tested directly.
---------------------------------------------------------------------------

-- Read the installed plugin version from _meta.lua.  Path is injectable so the
-- spec can point at a fixture; production uses the live plugin _meta.lua.
function M.getInstalledPluginVersion(meta_path)
    meta_path = meta_path or (U.plugin_path .. "_meta.lua")
    local ok, meta = pcall(dofile, meta_path)
    if ok and type(meta) == "table" and meta.version then
        return meta.version
    end
    return "unknown"
end

-- "v1.2.3" / "1.2.3" -> { 1, 2, 3 }.  Non-numeric components become 0.
function M.parseVersion(v)
    local parts = {}
    for part in tostring(v):gsub("^v", ""):gmatch("([^.]+)") do
        parts[#parts + 1] = tonumber(part) or 0
    end
    return parts
end

-- True iff candidate is strictly newer than installed (component-wise semver).
function M.isNewer(candidate, installed)
    local a, b = M.parseVersion(candidate), M.parseVersion(installed)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x > y then return true end
        if x < y then return false end
    end
    return false
end

-- Pick the download URL for a release.  Prefer a `.zip` asset (the flat install
-- zip produced by `make build` — unpacked WITHOUT root-stripping); fall back to
-- the source zipball (wrapped in a root folder — unpacked WITH root-stripping).
-- Returns (url, strip_root) or (nil, nil).
function M.selectAsset(release)
    for _, asset in ipairs(release.assets or {}) do
        if (asset.name or ""):match("%.zip$") and asset.browser_download_url then
            return asset.browser_download_url, false   -- flat asset: do not strip
        end
    end
    if release.zipball_url then
        return release.zipball_url, true               -- zipball: strip one level
    end
    return nil, nil
end

-- Strip the markdown most likely to appear in GitHub release notes so the
-- plain-text viewer reads cleanly.
function M.stripMarkdown(text)
    text = tostring(text or "")
    text = text:gsub("#+%s*", "")
    text = text:gsub("%*%*(.-)%*%*", "%1")
    text = text:gsub("%*(.-)%*", "%1")
    text = text:gsub("`(.-)`", "%1")
    return text
end

---------------------------------------------------------------------------
-- I/O + UI
---------------------------------------------------------------------------

local function offerReleasesPage(message)
    if Device:canOpenLink() then
        UIManager:show(ConfirmBox:new{
            text        = message .. "\n\n" .. _("Open the releases page in a browser?"),
            ok_text     = _("Open"),
            ok_callback = function() Device:openLink(RELEASES_PAGE) end,
        })
    else
        UIManager:show(InfoMessage:new{ text = message, timeout = 3 })
    end
end

local function upToDate(installed)
    UIManager:show(InfoMessage:new{
        text = T(_("KOSyncthing+ is up to date.\n\nInstalled version: %1"), installed),
    })
end

-- Download `zip_url` and unpack it over the plugin directory, then offer to
-- restart.  `strip_root` follows M.selectAsset (true for the zipball).
function M.install(zip_url, strip_root, new_version)
    local downloadFile = require("st_update").downloadFile

    UIManager:show(InfoMessage:new{ text = _("Downloading update…"), timeout = 1 })
    UIManager:scheduleIn(0.1, function()
        os.remove(TMP_ZIP)
        local ok_dl, err_dl = downloadFile(zip_url, TMP_ZIP)
        if not ok_dl then
            pcall(os.remove, TMP_ZIP)
            logger.warn("[KOSyncthing+] plugin update download failed: " .. tostring(err_dl))
            offerReleasesPage(_("Update failed."))
            return
        end

        local sz = U.fileSize(TMP_ZIP) or 0
        if sz < MIN_ZIP_SIZE or not U.isZip(TMP_ZIP) then
            pcall(os.remove, TMP_ZIP)
            offerReleasesPage(_("The downloaded file does not look like a plugin archive."))
            return
        end

        -- Device:unpackArchive removes the archive on success; remove it
        -- ourselves on the failure path too.
        local ok, err = U.unpackArchive(TMP_ZIP, U.plugin_path, strip_root)
        pcall(os.remove, TMP_ZIP)
        if not ok then
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = T(_("Installation failed: %1"), tostring(err)),
            })
            return
        end

        UIManager:show(ConfirmBox:new{
            text        = T(_("KOSyncthing+ updated to %1.\n\nRestart KOReader now to load it?"), new_version),
            ok_text     = _("Restart"),
            cancel_text = _("Later"),
            ok_callback = function() UIManager:restartKOReader() end,
        })
    end)
end

-- Entry point: check GitHub for a newer release and, if found, show notes with
-- an "Update & restart" action.  Brings Wi-Fi up per the user's prefs first.
function M.check()
    local downloadFile = require("st_update").downloadFile
    NetworkMgr:runWhenOnline(function()
        UIManager:show(InfoMessage:new{ text = _("Checking for plugin updates…"), timeout = 1 })
        UIManager:scheduleIn(0.1, function()
            local installed = M.getInstalledPluginVersion()

            os.remove(TMP_JSON)
            local ok = downloadFile(API_LATEST, TMP_JSON)
            local body
            if ok then
                local f = io.open(TMP_JSON, "r")
                if f then body = f:read("*a"); f:close() end
                os.remove(TMP_JSON)
            end
            if not body or body == "" then
                offerReleasesPage(_("Could not check for updates."))
                return
            end

            local parse_ok, release = pcall(JSON.decode, body)
            if not parse_ok or type(release) ~= "table" or not release.tag_name then
                offerReleasesPage(_("Could not read release information from GitHub."))
                return
            end
            -- releases/latest already excludes drafts/prereleases; guard anyway.
            if release.draft or release.prerelease or not M.isNewer(release.tag_name, installed) then
                upToDate(installed)
                return
            end

            local zip_url, strip_root = M.selectAsset(release)
            if not zip_url then
                offerReleasesPage(_("This release has no downloadable archive."))
                return
            end

            local latest = release.tag_name
            local notes  = M.stripMarkdown(release.body)
            local TextViewer = require("ui/widget/textviewer")
            local viewer
            viewer = TextViewer:new{
                title = _("Plugin update available"),
                text  = T(_("Installed: %1\nLatest: %2"), installed, latest)
                        .. "\n\n" .. notes,
                buttons_table = {{
                    {
                        text     = _("Later"),
                        callback = function() UIManager:close(viewer) end,
                    },
                    {
                        text     = _("Update & restart"),
                        callback = function()
                            UIManager:close(viewer)
                            M.install(zip_url, strip_root, latest)
                        end,
                    },
                }},
                add_default_buttons = false,
            }
            UIManager:show(viewer)
        end)
    end)
end

return M
