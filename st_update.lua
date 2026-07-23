-- st_update.lua – Binary download and update logic for KOSyncthing+
local ConfirmBox  = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Device      = require("device")
local UIManager   = require("ui/uimanager")
local NetworkMgr  = require("ui/network/manager")
local ffiutil     = require("ffi/util")
local logger      = require("logger")
local socketutil  = require("socketutil")
local U           = require("st_utils")
local util        = require("util")
local _           = require("syncthing_i18n").gettext
local T           = ffiutil.template
local Guard       = require("st_guard")

local rapidjson_ok, rapidjson = pcall(require, "rapidjson")
local JSON = rapidjson_ok and rapidjson or require("json")

local tmp_tar_path     = U.plugin_path .. "syncthing_update.tar.gz"
local tmp_extract_path = U.plugin_path .. "syncthing_extract"
local MIN_ARCHIVE_SIZE = 1024 * 1024

---------------------------------------------------------------------------
-- Transport helpers
---------------------------------------------------------------------------

-- Download via KOReader's built-in LuaSocket / LuaSec stack.
-- Works for both http:// and https:// URLs and follows redirects.
local function _downloadViaLua(url, save_path)
    local http   = require("socket.http")
    local socket = require("socket")

    local f, err = io.open(save_path, "wb")
    if not f then
        return false, "Cannot write to file: " .. (err or "unknown")
    end

    -- Wrap http.request in pcall so that socketutil:reset_timeout() always
    -- runs, even when LuaSocket raises a Lua error (DNS failure, malformed
    -- URL, etc.).
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local req_ok, code, _, status = pcall(function()
        return socket.skip(1, http.request{
            url  = url,
            sink = socketutil.file_sink(f),
        })
    end)
    socketutil:reset_timeout()  -- always reset, even if http.request raised
    -- socketutil.file_sink closes the handle itself when the request
    -- terminates (success, HTTP error, or timeout); only a Lua error raised
    -- before the terminal chunk can leave it open. Close defensively and
    -- ignore an already-closed handle — LuaJIT raises "attempt to use a
    -- closed file" on a double close, which was the actual crash (not a leak).
    pcall(function() f:close() end)

    if not req_ok then
        -- pcall caught a Lua error — remove the partial file
        os.remove(save_path)
        return false, "Download error: " .. tostring(code)
    end
    if code ~= 200 then
        os.remove(save_path)
        return false, "Request failed: " .. tostring(status or code)
    end
    return true
end

-- Download a file using the best available transport on the device.
-- Prefer curl because it handles GitHub redirects and certificate validation
-- reliably.  Keep wget and KOReader's Lua stack as fallbacks for lean images.
local function _downloadFile(url, save_path)
    -- 1. curl - reliable GitHub redirects and TLS with our bundled CA store
    if U.curlAvailable() and U.cacertExists() then
        local dl_cmd = string.format(
            "curl -f -L -s --connect-timeout 30 --max-time 600 --retry 2 --retry-delay 2 --cacert '%s' '%s' -o '%s'",
            U.shellEscape(U.cacert_path),
            U.shellEscape(url),
            U.shellEscape(save_path))
        if U.execOk(os.execute(dl_cmd)) then
            return true
        end
    end

    -- 2. wget - widely available, but some BusyBox builds are weak on HTTPS.
    local wget_cmd = string.format(
        "wget -qO '%s' '%s' 2>/dev/null",
        U.shellEscape(save_path),
        U.shellEscape(url))
    if U.execOk(os.execute(wget_cmd)) then
        return true
    end

    -- 3. KOReader built-in LuaSocket / LuaSec
    return _downloadViaLua(url, save_path)
end

---------------------------------------------------------------------------
-- Version & architecture helpers
---------------------------------------------------------------------------
local _version_cache = nil

local function getCurrentVersion(self)
    if _version_cache ~= nil then return _version_cache end
    if not util.pathExists(U.plugin_path .. "syncthing") then return nil end
    local p = io.popen("'" .. U.shellEscape(U.plugin_path .. "syncthing") .. "' --version 2>/dev/null")
    if not p then return nil end
    local out = p:read("*a"); p:close()
    if not out then return nil end
    _version_cache = out:match("syncthing v(%d+%.%d+%.%d+)")
    return _version_cache
end

local function invalidateVersionCache(self)
    _version_cache = nil
end

local detectArch = U.detectArch

---------------------------------------------------------------------------
-- _finishInstallation: extract the archive, locate the syncthing binary,
-- atomically move it into the plugin folder, and announce the result.
---------------------------------------------------------------------------
local function _finishInstallation(self, version, post_install_callback, lease)
    local function cleanup()
        os.execute("rm -rf '" .. U.shellEscape(tmp_extract_path) .. "'")
        os.execute("rm -f '"  .. U.shellEscape(tmp_tar_path)     .. "'")
        os.execute("rm -f '"  .. U.shellEscape(U.plugin_path .. "syncthing.new") .. "'")
    end

    local function fail_install(text)
        cleanup()
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = text,
        })
        lease:release()
        if post_install_callback then post_install_callback() end
    end

    os.execute("rm -rf '" .. U.shellEscape(tmp_extract_path) .. "'")
    os.execute("mkdir -p '" .. U.shellEscape(tmp_extract_path) .. "'")

    -- Extract just the executable.  A release archive contains three entries
    -- named `syncthing`: the ELF binary at the archive root plus helper scripts
    -- under etc/.  Selecting the entry inside the archive is unambiguous; see
    -- U.extractBinaryFromArchive for why searching the unpacked tree by name
    -- was not.
    --
    -- Measured on a FUSE mount: extractToPath closes the destination file
    -- before it returns, and the file is complete and readable immediately —
    -- so this path needs no special flush handling of its own.
    local binary_path = tmp_extract_path .. "/syncthing"
    local extract_ok, extract_err = U.extractBinaryFromArchive(tmp_tar_path, binary_path)
    if not extract_ok then
        -- Fall back to system tar (present on all supported devices) in case
        -- ffi/archiver is missing or fails.  Unpack the whole tree with
        -- --strip-components=1, which lands the executable at <dir>/syncthing:
        -- a fixed path, so no scanning and no ambiguity with the etc/ scripts.
        -- Do NOT pass a '*/syncthing' member pattern here: GNU tar rejects it
        -- without --wildcards, and busybox tar has no --wildcards at all.
        os.execute("rm -rf '" .. U.shellEscape(tmp_extract_path) .. "'")
        os.execute("mkdir -p '" .. U.shellEscape(tmp_extract_path) .. "'")
        local tar_ok = U.execOk(os.execute(
            "tar -xzf '" .. U.shellEscape(tmp_tar_path) .. "' -C '"
            .. U.shellEscape(tmp_extract_path) .. "' --strip-components=1"))
        os.execute("sync")
        if not tar_ok or not U.isELF(binary_path) then
            fail_install(_("The downloaded archive is corrupt or extraction failed.\n\nPlease try again.") ..
                         (extract_err and "\n\nDetails: " .. tostring(extract_err) or ""))
            return
        end
    end

    -- Ensure all writes are flushed before use (belt and suspenders for FUSE)
    os.execute("sync")

    if not U.isELF(binary_path) then
        fail_install(_("The downloaded archive did not contain a valid Linux Syncthing binary.\n\nPlease try again."))
        return
    end

    local should_restart = self:isRunning()

    local function do_install()
        if not util.pathExists(U.plugin_path) then
            if not util.makePath(U.plugin_path) then
                UIManager:show(InfoMessage:new{
                    icon = "notice-warning",
                    text = _("Could not create plugin directory.\nCheck file system permissions."),
                })
                lease:release()
                if post_install_callback then post_install_callback() end
                return
            end
        end

        local dest = U.plugin_path .. "syncthing"
        local tmp_dest = dest .. ".new"
        os.execute("rm -f '" .. U.shellEscape(tmp_dest) .. "'")
        local mv_ok = U.execOk(os.execute(string.format(
            "mv -f '%s' '%s'", U.shellEscape(binary_path), U.shellEscape(tmp_dest))))

        if not mv_ok then
            fail_install(_("Could not install the binary into the plugin folder.\n\nThe folder may be on a read-only filesystem."))
            return
        end

        local chmod_ok = U.execOk(os.execute(
            "chmod +x '" .. U.shellEscape(tmp_dest) .. "'"))
        if not chmod_ok then
            fail_install(_("The downloaded binary could not be made executable.\n\nThe plugin folder may be on a filesystem mounted without execute permission."))
            return
        end

        if not U.isELF(tmp_dest) then
            fail_install(_("The installed file is not a valid Linux executable.\n\nPlease try the download again."))
            return
        end

        local replace_ok = U.execOk(os.execute(string.format(
            "mv -f '%s' '%s'", U.shellEscape(tmp_dest), U.shellEscape(dest))))

        cleanup()

        if not replace_ok then
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = _("Could not replace the old Syncthing binary.\n\nThe plugin folder may be on a read-only filesystem."),
            })
            lease:release()
            if post_install_callback then post_install_callback() end
            return
        end

        self:_invalidateBinaryCache()
        self:_invalidateVersionCache()
        self:_cacheInvalidate()

        UIManager:show(InfoMessage:new{
            text = should_restart
                and T(_("Syncthing updated to v%1 and restarting…"), version)
                or  T(_("Syncthing v%1 installed!\n\nYou can now start syncing."), version),
            dismiss_callback = function()
                if self._suggestPassword and not self.gui_password then
                    self:_suggestPassword()
                end
            end,
        })

        lease:release()
        if should_restart then
            self._silentStart = true
            self:start(post_install_callback)
        elseif post_install_callback then
            post_install_callback()
        end
    end

    if should_restart then self:stop(do_install) else do_install() end
end

---------------------------------------------------------------------------
-- Perform the actual download and installation
---------------------------------------------------------------------------
local function performUpdate(self, url, version, expected_size, post_install_callback)
    local dl_msg = InfoMessage:new{
        text = T(_(
            "Downloading Syncthing v%1…\n\n" ..
            "This may take a few minutes.\n" ..
            "Please do not close KOReader."), version)
    }
    UIManager:show(dl_msg)
    local lease = Guard:acquire("update_download", {
        standby  = true,
        wakelock = true,
    })
    UIManager:scheduleIn(0.1, function()
        os.execute("rm -f '" .. U.shellEscape(tmp_tar_path) .. "'")
        local dest = U.plugin_path .. "syncthing"
        if util.pathExists(dest) and not U.isELF(dest) then
            os.execute("rm -f '" .. U.shellEscape(dest) .. "'")
            self:_invalidateBinaryCache()
        end

        local dl_ok, dl_err = _downloadFile(url, tmp_tar_path)
        UIManager:close(dl_msg)

        if not dl_ok then
            os.execute("rm -f '" .. U.shellEscape(tmp_tar_path) .. "'")
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = _("Download failed.\n\nPlease check your Wi-Fi connection and try again.") ..
                       (dl_err and "\n\nDetails: " .. dl_err or "")
            })
            lease:release()
            return
        end

        local actual = U.fileSize(tmp_tar_path) or 0

        if actual < MIN_ARCHIVE_SIZE then
            os.execute("rm -f '" .. U.shellEscape(tmp_tar_path) .. "'")
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = T(_(
                    "Downloaded file is too small to be a Syncthing archive.\n\n" ..
                    "Actual: %1\n\nPlease try again."),
                    util.getFriendlySize(actual)),
            })
            lease:release()
            return
        end

        if expected_size and expected_size > 0 then
            local ratio = actual / expected_size
            if ratio < 0.75 or ratio > 1.25 then
                os.execute("rm -f '" .. U.shellEscape(tmp_tar_path) .. "'")
                UIManager:show(InfoMessage:new{
                    icon = "notice-warning",
                    text = T(_(
                        "Downloaded file size is unexpected.\n\n" ..
                        "Expected: ~%1\nActual: %2\n\n" ..
                        "The download may be corrupt. Please try again."),
                        util.getFriendlySize(expected_size), util.getFriendlySize(actual)),
                })
                lease:release()
                return
            end
        end

        if not U.isGzip(tmp_tar_path) then
            os.execute("rm -f '" .. U.shellEscape(tmp_tar_path) .. "'")
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = _("Downloaded file is not the expected Linux tar.gz archive.\n\nPlease try again."),
            })
            lease:release()
            return
        end

        _finishInstallation(self, version, post_install_callback, lease)
    end)
end

local function _doFetchRelease(self, post_install_callback)
    local release_json = nil

    -- Use the unified download function (wget → curl → LuaSocket)
    local tmp_json = "/tmp/syncthing_release.json"
    os.remove(tmp_json)
    local ok, err = _downloadFile(
        "https://api.github.com/repos/syncthing/syncthing/releases/latest",
        tmp_json)
    if ok then
        local f = io.open(tmp_json, "r")
        if f then
            release_json = f:read("*a")
            f:close()
        end
        os.remove(tmp_json)
    else
        logger.warn("[KOSyncthing+] Release download failed: " .. tostring(err))
    end

    if not release_json or release_json == "" then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Update check failed.\n\nThe server could not be reached. Please check your Wi-Fi connection."),
        })
        return
    end

    local parse_ok, release = pcall(JSON.decode, release_json)
    if not parse_ok or type(release) ~= "table" or not release.tag_name then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Could not read release information from GitHub.\n\nThe response may have been malformed."),
        })
        return
    end

    local latest_ver  = release.tag_name:match("v?(%d+%.%d+%.%d+)") or release.tag_name
    local current_ver = getCurrentVersion(self)

    -- Treat a non-ELF file at the binary path (for example a tiny metadata
    -- file named "syncthing") as "not installed".
    local is_new_install = not U.isELF(U.plugin_path .. "syncthing")

    if not is_new_install and current_ver == latest_ver then
        UIManager:show(InfoMessage:new{
            text = T(_("Syncthing is already up to date.\n\nInstalled version: %1"), current_ver),
        })
        return
    end

    local arch, arch_fallback, raw_machine = detectArch()
    local expected_name = string.format("syncthing-linux-%s-v%s.tar.gz", arch, latest_ver)
    local dl_url, dl_size

    for _, asset in ipairs(release.assets or {}) do
        local n = asset.name or ""
        if n == expected_name then
            dl_url  = asset.browser_download_url
            dl_size = asset.size
            break
        end
    end

    if not dl_url then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_(
                "No binary found for this device.\n\n" ..
                "Architecture detected: %1\n" ..
                "Latest release: v%2\n\n" ..
                "You can download the binary manually from:\n" ..
                "github.com/syncthing/syncthing/releases"),
                arch, latest_ver),
        })
        return
    end

    if arch_fallback then
        UIManager:show(ConfirmBox:new{
            text = T(_(
                "Architecture detection warning\n\n" ..
                "This device reported \"%1\", which is not a recognised CPU identifier.\n\n" ..
                "The plugin will attempt to download the 32-bit ARM binary — this is correct " ..
                "for most Kindles and Kobos, but may be wrong for your device.\n\n" ..
                "If Syncthing fails to start after installation, please download the correct " ..
                "binary manually from:\ngithub.com/syncthing/syncthing/releases\n\n" ..
                "Continue with the ARM download?"),
                raw_machine),
            ok_text     = _("Download anyway"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                performUpdate(self, dl_url, latest_ver, dl_size, post_install_callback)
            end,
        })
        return
    end

    if is_new_install then
        performUpdate(self, dl_url, latest_ver, dl_size, post_install_callback)
    else
        local size_str = dl_size and (" (~" .. util.getFriendlySize(dl_size) .. ")") or ""
        local confirm_text = T(_(
            "A new version is available!\n\n" ..
            "Installed:  v%1\n" ..
            "Available:  v%2%3\n\n" ..
            "Update now?"), current_ver or "?", latest_ver, size_str)

        UIManager:show(ConfirmBox:new{
            text        = confirm_text,
            ok_text     = _("Update"),
            cancel_text = _("Not now"),
            ok_callback = function()
                performUpdate(self, dl_url, latest_ver, dl_size, post_install_callback)
            end,
        })
    end
end

local function checkForUpdates(self, post_install_callback, is_new_install)
    if not U.cacertExists() then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = U.NO_CACERT_MSG })
        return
    end
    if not NetworkMgr:isOnline() then
        UIManager:show(InfoMessage:new{
            text = _("Please connect to the Internet before checking for updates."),
        })
        return
    end

    local free = U.getFreeSpace(U.plugin_path)
    if free and free < 20 * 1024 * 1024 then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_("Not enough free space to download Syncthing.\n\nFree: %1\nRequired: 20 MB"), util.getFriendlySize(free)),
        })
        return
    end

    if is_new_install then
        _doFetchRelease(self, post_install_callback)
    else
        local checking_msg = InfoMessage:new{ text = _("Checking for updates…\n\nThis may take a moment.") }
        UIManager:show(checking_msg)
        UIManager:scheduleIn(0.1, function()
            UIManager:close(checking_msg)
            _doFetchRelease(self, post_install_callback)
        end)
    end
end

return {
    getCurrentVersion       = getCurrentVersion,
    _invalidateVersionCache = invalidateVersionCache,
    checkForUpdates         = checkForUpdates,
    performUpdate           = performUpdate,
    -- Generic transport (curl → wget → LuaSocket, follows redirects, uses the
    -- bundled CA store).  Exposed so st_plugin_update can reuse the exact same
    -- proven downloader for the GitHub API and the plugin archive.
    downloadFile            = _downloadFile,
}
