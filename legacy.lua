-- legacy.lua — Legacy Syncthing binary support
--
-- This module handles three distinct concerns that arise when the user's
-- device has a kernel too old for the current Syncthing binary:
--
--   1. Detection   — needsLegacy() probes the running kernel version
--                    and returns true when it is < 3.2 (the minimum for
--                    Go 1.24+, which recent Syncthing versions require).
--
--   2. Lifecycle   — enable() / disable() persist the user's choice and
--                    coordinate with the running daemon (stop on switch).
--
--   3. Download    — downloadBinary() fetches the chosen legacy version
--                    from GitHub and installs it as "syncthing-legacy"
--                    in the plugin folder.
--
--   4. API compat  — patchSyncthingObject() is called from main.lua AFTER
--                    all modules are mixed in.  It replaces the five REST
--                    API methods that rely on endpoints introduced in
--                    Syncthing v1.12.0 with read-modify-write equivalents
--                    that work on ANY version back to v1.2.2.
--
--                    The patch is applied ONLY when the user has chosen
--                    v1.2.2 specifically.  v1.27.12 already supports the
--                    modern /rest/config endpoint and needs no patching.
--
--   5. Menu        — buildMenuItems() returns a sub-table consumed by
--                    getSetupMenu() in st_menu.lua.
--
-- Path resolution
-- ---------------
-- ALL path decisions (which binary to run, which config directory to
-- read/write) go through U.getBinaryPath() and U.getConfigDir() in
-- st_utils.lua, which read from G_reader_settings at call time.  This
-- module therefore needs no knowledge of paths — it only flips the
-- "syncthing_use_legacy" and "syncthing_legacy_version" settings and lets
-- the helper functions propagate the change automatically.

local ConfirmBox  = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager   = require("ui/uimanager")
local Device      = require("device")
local logger      = require("logger")
local util        = require("util")
local ffiutil     = require("ffi/util")
local T           = ffiutil.template
local _           = require("syncthing_i18n").gettext
local U           = require("st_utils")
local Guard       = require("st_guard")

-- LEGACY_VERSIONS defines the two supported binary versions.
-- Each entry carries the version tag, a human-readable label, and a flag
-- that indicates whether the v1.12.0 config API (/rest/config) is present.
-- This flag drives the decision in main.lua about whether to call
-- patchSyncthingObject().
local LEGACY_VERSIONS = {
    {
        tag       = "v1.27.12",
        label     = _("v1.27.12 — kernels 2.6.32–3.1 (recommended, full API)"),
        needs_patch = false,   -- has /rest/config and PATCH endpoints
    },
    {
        tag       = "v1.2.2",
        label     = _("v1.2.2 — very old kernels < 2.6.32 (limited features)"),
        needs_patch = true,    -- predates /rest/config; uses /rest/system/config
    },
}

local Legacy = {}
local MIN_ARCHIVE_SIZE = 1024 * 1024

-- ---------------------------------------------------------------------------
-- Detection
-- ---------------------------------------------------------------------------

-- Module-level cache for the kernel version check.
-- The kernel version cannot change while KOReader is running, so one
-- subprocess invocation per session is both correct and sufficient.
local _kernel_state_cache = nil

--- Classifies the running kernel into one of three states:
--   "old"     — kernel < 3.2.  Current Syncthing (built with Go 1.24+, which
--               requires kernel ≥ 3.2) cannot start; a legacy binary is needed.
--   "modern"  — kernel ≥ 3.2.  Current Syncthing runs fine; legacy mode is
--               never relevant and must stay hidden.
--   "unknown" — the kernel version could not be read or parsed.  We cannot
--               rule legacy in or out, so the menu only surfaces it here as a
--               fallback when a real start attempt has failed.
-- The three-way result (vs. the old true/false) matters because "false" used
-- to conflate "confirmed modern" with "could not tell" — and those two cases
-- must behave differently for menu visibility.
function Legacy.kernelState()
    if _kernel_state_cache ~= nil then return _kernel_state_cache end

    local function major_minor(s)
        if not s then return nil end
        local maj, min = s:match("(%d+)%.(%d+)")
        return tonumber(maj), tonumber(min)
    end
    local function first_line(path)
        local f = io.open(path, "r"); if not f then return nil end
        local l = f:read("*l"); f:close(); return l
    end

    local major, minor
    -- 1. uname -r — the existing probe, kept first.
    local p = io.popen("uname -r 2>/dev/null")
    if p then
        local ver = p:read("*l"); p:close()
        major, minor = major_minor(ver)
    end
    -- 2. /proc/sys/kernel/osrelease — kernel-published release string; covers
    --    stripped firmware where the `uname` userspace binary is absent.  We
    --    already depend on procfs for process detection, so it is present
    --    wherever the plugin can run.
    if not major then
        major, minor = major_minor(first_line("/proc/sys/kernel/osrelease"))
    end
    -- 3. /proc/version — "Linux version X.Y.Z ..."; grab the token after
    --    "version" so the match cannot land on the compiler version.
    if not major then
        local v = first_line("/proc/version")
        major, minor = major_minor(v and v:match("version%s+(%S+)"))
    end

    local state = "unknown"
    if major then
        state = ((major < 3) or (major == 3 and (minor or 0) < 2)) and "old" or "modern"
    end
    _kernel_state_cache = state
    return state
end

--- Returns true when the running kernel is older than 3.2 (i.e. confirmed
--- too old for a current Syncthing binary).  Thin wrapper over kernelState()
--- kept for existing callers; an "unknown" kernel returns false here.
function Legacy.needsLegacy()
    return Legacy.kernelState() == "old"
end

-- Module-level cache for the recommended-version probe (kernel is immutable
-- for the session, so one uname call is enough).
local _recommended_version_cache = nil

--- Returns the legacy Syncthing version best suited to this device's kernel.
-- v1.2.2   — kernels older than 2.6.32 (e.g. Kindle PW1)
-- v1.27.12 — kernels 2.6.32 through 3.1 (the common legacy case)
-- The plugin reads the kernel itself so the user never has to know their
-- kernel version or choose a release number.  When the kernel cannot be read,
-- v1.27.12 is the safe default: it has the full REST API, so a wrong guess
-- here only means "more features than strictly needed", never a broken API.
function Legacy.recommendedVersion()
    if _recommended_version_cache ~= nil then return _recommended_version_cache end
    local result = "v1.27.12"
    local p = io.popen("uname -r 2>/dev/null")
    if p then
        local ver = p:read("*l"); p:close()
        if ver then
            local major, minor, patch = ver:match("^(%d+)%.(%d+)%.?(%d*)")
            major = tonumber(major)
            minor = tonumber(minor)
            patch = tonumber(patch) or 0
            if major then
                -- kernel < 2.6.32 → v1.2.2
                if (major < 2)
                    or (major == 2 and minor < 6)
                    or (major == 2 and minor == 6 and patch < 32) then
                    result = "v1.2.2"
                end
            end
        end
    end
    _recommended_version_cache = result
    return result
end

--- Returns true when legacy mode is currently enabled in settings.
function Legacy.isEnabled()
    return G_reader_settings:isTrue("syncthing_use_legacy")
end

--- Returns the currently configured legacy version tag, e.g. "v1.27.12".
function Legacy.getVersion()
    return G_reader_settings:readSetting("syncthing_legacy_version") or "v1.27.12"
end

--- Returns true when the chosen version requires API monkey-patching
--- (i.e. when the binary predates the /rest/config endpoint).
function Legacy.needsPatch()
    local ver = Legacy.getVersion()
    for _, entry in ipairs(LEGACY_VERSIONS) do
        if entry.tag == ver then return entry.needs_patch end
    end
    return false  -- unknown version: assume modern API to avoid over-patching
end

-- ---------------------------------------------------------------------------
-- Lifecycle — enable and disable
-- ---------------------------------------------------------------------------

--- Enable legacy mode for the given version tag.
-- Persist the legacy mode choice and clear stale caches.
-- IMPORTANT: stop() is the CALLER'S responsibility (see showVersionPicker /
-- buildMenuItems).  enable() and disable() intentionally do NOT call stop()
-- so they can be used inside a stop() callback without re-entry problems.
function Legacy.enable(self, version)
    version = version or "v1.27.12"
    G_reader_settings:saveSetting("syncthing_use_legacy", true)
    G_reader_settings:saveSetting("syncthing_legacy_version", version)
    -- The legacy daemon generates its own config.xml in settings/syncthing-legacy/
    -- with a DIFFERENT API key (random, generated at first run) and a DIFFERENT
    -- TLS certificate (= different Syncthing device ID).
    --
    -- self.api_key is an instance-level cache set by getAPIKey() in st_api.lua.
    -- Without clearing it here, the next apiCall() would send the stale standard-mode
    -- key to the legacy daemon, which would reject it with 403 Forbidden.  The plugin
    -- would appear to work (no crash) but every API call would silently fail.
    self.api_key = nil
    -- _invalidateDeviceIdCache() clears the module-level _cached_device_id in
    -- st_api.lua so getDeviceId() re-reads from the new config directory.
    self:_invalidateDeviceIdCache()
    -- _invalidateBinaryCache() clears the module-level _binary_exists_cache in
    -- st_process.lua.  The cache is a plain boolean with no memory of WHICH path
    -- it checked.  After switching modes, U.getBinaryPath() returns a different
    -- path (syncthing-legacy vs syncthing), but the cache still holds the result
    -- from the old path.  Concretely: if the standard binary existed, the cache
    -- says true, the first-run download dialog for the legacy binary is suppressed,
    -- and the plugin tries to launch a file that isn't there.
    self:_invalidateBinaryCache()
    -- AD-19: getDataDir() caches the resolved DB directory for the session, but
    -- getConfigDir() reflects the mode at call time.  Without clearing the data
    -- cache here, after a mode switch the next start would reuse the previous
    -- mode's resolved directory (e.g. standard's /var/local for the legacy
    -- binary, or — worse — legacy's /mnt/us config dir for standard, which is
    -- the broken FUSE mount the relocation exists to avoid).
    U.invalidateDataDirCache()
    logger.info("[Syncthing] Legacy mode enabled: " .. version)
end

--- Disable legacy mode.
-- The version setting is intentionally left intact so the user can re-enable
-- with the same version without going through the picker again.
-- stop() is the caller's responsibility — see buildMenuItems().
function Legacy.disable(self)
    G_reader_settings:delSetting("syncthing_use_legacy")
    self.api_key = nil          -- must re-read from settings/syncthing/config.xml
    self:_invalidateDeviceIdCache()
    -- Same cache-staleness issue as enable(): after switching back to standard
    -- mode, getBinaryPath() returns the standard binary path, but the cache may
    -- hold a false from when it wasn't installed, or a true from a previous
    -- legacy session that checked a different path.  Force a fresh probe.
    self:_invalidateBinaryCache()
    -- AD-19: clear the data-dir cache too (see enable()) so standard mode
    -- re-resolves instead of reusing the legacy config dir.
    U.invalidateDataDirCache()
    logger.info("[Syncthing] Legacy mode disabled")
end

-- ---------------------------------------------------------------------------
-- Download
-- ---------------------------------------------------------------------------

--- Detect the device architecture for constructing the download URL.
local function detectArch()
    local arch = U.detectArch()
    return arch
end

--- Download and install a specific Syncthing version as "syncthing-legacy".
-- The function constructs the GitHub release URL from the version tag and
-- the detected architecture, downloads the tar.gz, extracts the binary,
-- and installs it as plugin_path/syncthing-legacy.
-- callback(ok, err_string) is invoked when the operation completes.
function Legacy.downloadBinary(self, version, callback)
    if not U.cacertExists() then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = U.NO_CACERT_MSG,
        })
        if callback then callback(false, "cacert.pem not found") end
        return
    end

    local arch     = detectArch()
    local filename = string.format("syncthing-linux-%s-%s.tar.gz", arch, version)
    local url      = string.format(
        "https://github.com/syncthing/syncthing/releases/download/%s/%s",
        version, filename)

    local tmp_tar = U.plugin_path .. "syncthing_legacy_update.tar.gz"
    local tmp_dir = U.plugin_path .. "syncthing_legacy_extract"

    local msg = InfoMessage:new{
        text = T(_("Downloading Syncthing %1…\n\nThis may take a few minutes.\nPlease do not close KOReader."),
                 version),
    }
    UIManager:show(msg)
    local lease = Guard:acquire("legacy_download", {
        standby  = true,
        wakelock = true,
    })

    UIManager:scheduleIn(0.1, function()
        os.execute("rm -f '"  .. U.shellEscape(tmp_tar) .. "'")
        os.execute("rm -rf '" .. U.shellEscape(tmp_dir) .. "'")

        local function cleanup()
            os.execute("rm -rf '" .. U.shellEscape(tmp_dir) .. "'")
            os.execute("rm -f '"  .. U.shellEscape(tmp_tar) .. "'")
            os.execute("rm -f '"  .. U.shellEscape(U.plugin_path .. "syncthing-legacy.new") .. "'")
        end

        local function fail_download(err_msg)
            cleanup()
            lease:release()
            UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err_msg })
            if callback then callback(false, err_msg) end
        end

        -- Download: prefer curl for GitHub redirects/TLS, then fallback to wget.
        local dl_ok = false
        if U.curlAvailable() and U.cacertExists() then
            local curl_cmd = string.format(
                "curl -f -L -s --connect-timeout 30 --max-time 600 --retry 2 --retry-delay 2 --cacert '%s' '%s' -o '%s'",
                U.shellEscape(U.cacert_path),
                U.shellEscape(url),
                U.shellEscape(tmp_tar))
            dl_ok = U.execOk(os.execute(curl_cmd))
        end
        if not dl_ok then
            local wget_cmd = string.format(
                "wget -qO '%s' '%s' 2>/dev/null",
                U.shellEscape(tmp_tar), U.shellEscape(url))
            dl_ok = U.execOk(os.execute(wget_cmd))
        end

        UIManager:close(msg)

        if not dl_ok then
            local err_msg = _("Download failed.\n\nPlease check your Wi-Fi connection and try again.")
            fail_download(err_msg)
            return
        end

        local actual = U.fileSize(tmp_tar) or 0
        if actual < MIN_ARCHIVE_SIZE then
            local err_msg = T(_(
                "Downloaded file is too small to be a Syncthing archive.\n\n" ..
                "Actual: %1\n\nPlease try again."),
                util.getFriendlySize(actual))
            fail_download(err_msg)
            return
        end

        if not U.isGzip(tmp_tar) then
            local err_msg = _("Downloaded file is not the expected Linux tar.gz archive.\n\nPlease try again.")
            fail_download(err_msg)
            return
        end

        -- Extract
        local extract_ok = U.unpackArchive(tmp_tar, tmp_dir, true)
        if not extract_ok then
            local err_msg = _("Extraction failed. The archive may be corrupt. Please try again.")
            fail_download(err_msg)
            return
        end

        -- Find the binary inside the extracted tree
        local fp = io.popen(
            "find '" .. U.shellEscape(tmp_dir) .. "' -name syncthing -type f -maxdepth 3 2>/dev/null")
        local binary_path = fp and fp:read("*l")
        if fp then fp:close() end

        if not binary_path or binary_path == "" then
            local err_msg = _("Binary not found inside the downloaded archive. Please try again.")
            fail_download(err_msg)
            return
        end

        if not U.isELF(binary_path) then
            local err_msg = _("The downloaded archive did not contain a valid Linux Syncthing binary.\n\nPlease try again.")
            fail_download(err_msg)
            return
        end

        -- Atomically install as syncthing-legacy
        local dest   = U.plugin_path .. "syncthing-legacy"
        local tmp_dest = dest .. ".new"
        os.execute("rm -f '" .. U.shellEscape(tmp_dest) .. "'")
        local mv_ok  = U.execOk(os.execute(string.format(
            "mv -f '%s' '%s'", U.shellEscape(binary_path), U.shellEscape(tmp_dest))))

        if not mv_ok then
            local err_msg = _("Could not install the legacy binary.\n\nThe plugin folder may be on a read-only filesystem.")
            fail_download(err_msg)
            return
        end

        -- Make the binary executable and verify it.  If chmod fails (plugin
        -- folder on a noexec mount, unusual ACLs, read-only bind-mount), the
        -- file exists but cannot run.  Recording it as installed would let the
        -- version guard and binaryExists() both pass, and the user would hit a
        -- confusing 12 s start timeout with no hint of the real cause.
        -- Remove the file and surface a clear error instead.
        local chmod_ok = U.execOk(os.execute(
            "chmod +x '" .. U.shellEscape(tmp_dest) .. "'"))
        if not chmod_ok then
            self:_invalidateBinaryCache()
            local err_msg = _(
                "The downloaded binary could not be made executable.\n\n" ..
                "The plugin folder may be on a filesystem mounted without " ..
                "execute permission (noexec). Try moving the plugin to " ..
                "internal storage.")
            fail_download(err_msg)
            return
        end

        if not U.isELF(tmp_dest) then
            self:_invalidateBinaryCache()
            local err_msg = _("The installed file is not a valid Linux executable.\n\nPlease try the download again.")
            fail_download(err_msg)
            return
        end

        local replace_ok = U.execOk(os.execute(string.format(
            "mv -f '%s' '%s'", U.shellEscape(tmp_dest), U.shellEscape(dest))))
        cleanup()

        if not replace_ok then
            self:_invalidateBinaryCache()
            local err_msg = _("Could not replace the old legacy binary.\n\nThe plugin folder may be on a read-only filesystem.")
            lease:release()
            UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err_msg })
            if callback then callback(false, err_msg) end
            return
        end

        self:_invalidateBinaryCache()
        -- Record which version is now physically on disk.  Both legacy
        -- versions share the filename "syncthing-legacy", so the selected
        -- version (syncthing_legacy_version) alone cannot tell us what was
        -- actually installed — a cancelled or failed switch would leave the
        -- setting and the file disagreeing (AD-14).  st_process.start()
        -- compares these two before launching and refuses on a mismatch.
        -- Written only after mv AND chmod both succeed, so a failed download
        -- correctly leaves the previous installed-version value intact.
        G_reader_settings:saveSetting("syncthing_legacy_installed_version", version)
        lease:release()
        if callback then callback(true, nil) end
    end)
end

-- ---------------------------------------------------------------------------
-- API compatibility patch — v1.2.2 only
-- ---------------------------------------------------------------------------

--- Replace REST API methods on SyncthingClass that use the v1.12.0+ config
--- endpoint with equivalents that work on v1.2.2 using /rest/system/config.
--
-- Why this approach?
--   In v1.2.2, GET /rest/config → 404.  The plugin uses PATCH /rest/config/*
--   for live configuration updates and GET /rest/config/folders for folder
--   enumeration.  Neither exists before v1.12.0.
--
--   The workaround is a read-modify-write pattern:
--     1. GET /rest/system/config   (always available)
--     2. Apply the desired change to the Lua table
--     3. PUT /rest/system/config   (always available)
--
--   Each wrapper checks patchActive() at CALL TIME and falls through to the
--   original method whenever the shim should not apply.  Because of that,
--   main.lua installs this patch UNCONDITIONALLY and ONCE at startup; the
--   wrappers themselves decide per call whether to engage.  This is what
--   makes enabling v1.2.2 from the menu take effect immediately, without a
--   KOReader restart (AD-12), while never affecting standard mode or
--   v1.27.12 (AD-13).
--
-- The inner helper putConfig performs the read-modify-write atomically from
-- the Lua side.  It uses SafeClient.GET / SafeClient.PUT (mixed into
-- Syncthing by main.lua) so all the existing error handling and API-key
-- logic is reused transparently.
function Legacy.patchSyncthingObject(SyncthingClass)
    -- Idempotency guard.  The patch is applied to the CLASS, so installing it
    -- once covers the whole session.  A second call would capture the
    -- already-wrapped methods as "originals", nesting the shim and breaking
    -- fall-through.  The guard makes it safe for main.lua to call this
    -- unconditionally at startup (see AD-12 fix).
    if SyncthingClass._st_legacy_patched then return end
    SyncthingClass._st_legacy_patched = true

    -- patchActive() decides, at CALL TIME, whether the read-modify-write shim
    -- should take over.  It must be true ONLY when legacy mode is enabled AND
    -- the selected version actually predates /rest/config (v1.2.2).  Checking
    -- isEnabled() alone (the previous behaviour) routed v1.27.12 — which has
    -- the modern config API — through the old /rest/system/config shim after
    -- an in-session version switch (AD-13).  Re-reading both settings here
    -- means the wrappers always track the live configuration.
    local function patchActive()
        return Legacy.isEnabled() and Legacy.needsPatch()
    end

    -- putConfig is closed over the SyncthingClass methods at patch time.
    -- At call time, `self` is the Syncthing instance.
    local function putConfig(self, modifier)
        local r = self:GET("system/config")
        if not U.isOk(r) then
            return { ok = false, error = "Could not read config via system/config: " .. (r.error or "") }
        end
        local config = r.data
        if type(config) ~= "table" then
            return { ok = false, error = "system/config response is not a table" }
        end
        modifier(config)
        return self:PUT("system/config", config)
    end

    -- Capture originals before replacing them.
    local origGetConfig  = SyncthingClass.getConfig
    local origGetFolders = SyncthingClass.getFolders
    local origGetDevices = SyncthingClass.getDevices
    local origGetOptions = SyncthingClass.getOptions
    local origPatchFolder  = SyncthingClass.patchFolder
    local origPatchDevice  = SyncthingClass.patchDevice
    local origPatchOptions = SyncthingClass.patchOptions
	local origAddDevice = SyncthingClass.addDevice
	local origAddFolder = SyncthingClass.addFolder
	local origDeleteFolder = SyncthingClass.deleteFolder

    -- getConfig: use /rest/system/config (old endpoint) instead of /rest/config
    SyncthingClass.getConfig = function(self)
        if not patchActive() then return origGetConfig(self) end
        local r = self:GET("system/config")
        if not U.isOk(r) then return nil end
        return r.data
    end

    -- getFolders: extract from full config (no /rest/config/folders on v1.2.2)
    SyncthingClass.getFolders = function(self)
        if not patchActive() then return origGetFolders(self) end
        local config = self:getConfig()
        return config and config.folders
    end

    -- getDevices: same pattern
    SyncthingClass.getDevices = function(self)
        if not patchActive() then return origGetDevices(self) end
        local config = self:getConfig()
        return config and config.devices
    end

    -- getOptions: same pattern
    SyncthingClass.getOptions = function(self)
        if not patchActive() then return origGetOptions(self) end
        local config = self:getConfig()
        return config and config.options
    end

    -- patchFolder: read-modify-write the matching folder entry
    SyncthingClass.patchFolder = function(self, folder_id, patch)
        if not patchActive() then return origPatchFolder(self, folder_id, patch) end
        return putConfig(self, function(cfg)
            for _, f in ipairs(cfg.folders or {}) do
                if f.id == folder_id then
                    for k, v in pairs(patch) do f[k] = v end
                end
            end
        end)
    end

    -- patchDevice: read-modify-write the matching device entry
    SyncthingClass.patchDevice = function(self, device_id, patch)
        if not patchActive() then return origPatchDevice(self, device_id, patch) end
        return putConfig(self, function(cfg)
            for _, d in ipairs(cfg.devices or {}) do
                if d.deviceID == device_id then
                    for k, v in pairs(patch) do d[k] = v end
                end
            end
        end)
    end

    -- patchOptions: read-modify-write the options block
    SyncthingClass.patchOptions = function(self, options)
        if not patchActive() then return origPatchOptions(self, options) end
        return putConfig(self, function(cfg)
            if not cfg.options then cfg.options = {} end
            for k, v in pairs(options) do cfg.options[k] = v end
        end)
    end
	

	
	SyncthingClass.addDevice = function(self, device)
		if not patchActive() then return origAddDevice(self, device) end
		return putConfig(self, function(cfg)
			local exists = false
			for _, d in ipairs(cfg.devices or {}) do
				if d.deviceID == device.deviceID then exists = true; break end
			end
			if not exists then
				cfg.devices = cfg.devices or {}
				table.insert(cfg.devices, device)
			end
		end)
	end
	
	SyncthingClass.addFolder = function(self, folder)
		if not patchActive() then return origAddFolder(self, folder) end
		return putConfig(self, function(cfg)
			local exists = false
			for _, f in ipairs(cfg.folders or {}) do
				if f.id == folder.id then exists = true; break end
			end
			if not exists then
				cfg.folders = cfg.folders or {}
				table.insert(cfg.folders, folder)
			end
		end)
	end

	SyncthingClass.deleteFolder = function(self, folder_id)
		if not patchActive() then return origDeleteFolder(self, folder_id) end
		return putConfig(self, function(cfg)
			local folders = cfg.folders or {}
			for i, f in ipairs(folders) do
				if f.id == folder_id then
					table.remove(folders, i)
					return
				end
			end
		end)
	end

    logger.info("[Syncthing] legacy.lua: API compatibility shim installed (active only on v1.2.2)")
end

-- ---------------------------------------------------------------------------
-- Menu builder
-- ---------------------------------------------------------------------------

-- Internal: turn legacy mode on, install the binary, and offer to start.
-- enableAndInstall is the single funnel for enabling legacy mode — both the
-- guided setup dialog and the manual version picker end here, so the
-- "stop → enable → download → offer to start" sequence is defined once.
--
-- Any version-specific warning (e.g. the v1.2.2 protocol-compatibility note)
-- is shown by the CALLER before invoking this; enableAndInstall assumes the
-- user has already committed to `version`.
--
-- stop() is called first so its status message (if any) settles before the
-- next dialog appears; its callback fires immediately when Syncthing is not
-- running.
local function enableAndInstall(self, version, tmi)
    self:stop(function()
        Legacy.enable(self, version)
        if tmi then tmi:updateItems() end
        Legacy.downloadBinary(self, version, function(ok)
            if not ok then return end   -- downloadBinary shows its own error
            -- Offer to start straight away.  The old flow left the user with
            -- a passive "tap Start" message and a submenu to back out of;
            -- this turns the end of setup into a single tap.
            UIManager:show(ConfirmBox:new{
                text        = T(_(
                    "Legacy Syncthing %1 is installed and ready.\n\nStart it now?"), version),
                ok_text     = _("Start"),
                cancel_text = _("Later"),
                ok_callback = function()
                    -- onToggleSyncthingServer handles the binary check and
                    -- the run-when-online wrapper; Syncthing was just stopped
                    -- above, so this toggles it on.
                    self:onToggleSyncthingServer()
                end,
            })
        end)
    end)
end

-- Internal: the v1.2.2 protocol/feature warning, shown before committing to
-- that version from either entry point.
local function confirmV122ThenInstall(self, tmi)
    UIManager:show(ConfirmBox:new{
        text = _(
            "v1.2.2 has an older, limited REST API.\n\n"
         .. "All features remain available — start, sync, pause, and "
         .. "folder/device management work normally through an automatic "
         .. "compatibility layer.\n\n"
         .. "The only difference: a few newer performance and network "
         .. "tuning settings did not exist in v1.2.2, so they are skipped "
         .. "automatically and have no effect.\n\n"
         .. "Important: v1.2.2 is a very old release. The device you sync "
         .. "with (computer or phone) should run a Syncthing version old "
         .. "enough to remain protocol-compatible — a recent v1.x is usually "
         .. "safe; a very new release may fail to connect.\n\n"
         .. "Continue?"),
        ok_text     = _("Enable v1.2.2"),
        cancel_text = _("Cancel"),
        ok_callback = function() enableAndInstall(self, "v1.2.2", tmi) end,
    })
end

-- showVersionPicker — manual version override.
-- Reachable from "Choose version manually" in the guided setup dialog and
-- from the "Legacy version" item once legacy mode is already enabled.  Most
-- users never see this: the guided flow picks the right version for them.
local function showVersionPicker(self, tmi)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dlg
    dlg = ButtonDialog:new{
        -- ButtonDialog renders `title` as the explanatory text block.
        title = _(
            "Choose the Syncthing version for this device.\n\n"
         .. "v1.27.12 — kernels 2.6.32–3.1. Full feature support; "
         .. "all menu options remain available.\n\n"
         .. "v1.2.2 — very old kernels below 2.6.32 (e.g. Kindle PW1). "
         .. "All features remain available; a few newer tuning settings "
         .. "are skipped automatically."),
        buttons = {
            {{
                text     = _("v1.27.12"),
                callback = function()
                    UIManager:close(dlg)
                    enableAndInstall(self, "v1.27.12", tmi)
                end,
            }},
            {{
                text     = _("v1.2.2 (very old kernels)"),
                callback = function()
                    UIManager:close(dlg)
                    confirmV122ThenInstall(self, tmi)
                end,
            }},
            {{
                text     = _("Cancel"),
                callback = function() UIManager:close(dlg) end,
            }},
        },
    }
    UIManager:show(dlg)
end

-- showLegacySetup — guided, low-decision legacy setup.  This is what the user
-- sees when they enable legacy mode from the menu.  The version is detected
-- from the kernel; the user only confirms.  "Choose version manually" is the
-- escape hatch for the rare case where the detected kernel is misleading.
local function showLegacySetup(self, tmi)
    local recommended = Legacy.recommendedVersion()

    -- Body text; the v1.2.2 protocol-compatibility note is folded in when
    -- v1.2.2 is what we are about to install, so the user does not need to
    -- read a second dialog for the common guided path.
    local body
    if recommended == "v1.2.2" then
        body = T(_(
            "Legacy mode lets Syncthing run on devices with a very old "
         .. "Linux kernel.\n\n"
         .. "Recommended for this device: %1.\n\n"
         .. "%1 is an old release with a limited API, but all features stay "
         .. "available through an automatic compatibility layer — only a few "
         .. "newer tuning settings are skipped. The device you sync "
         .. "with should run a Syncthing version old enough to stay "
         .. "protocol-compatible.\n\n"
         .. "The binary (~10–20 MB) will be downloaded — Wi-Fi is required."),
            recommended)
    else
        body = T(_(
            "Legacy mode lets Syncthing run on devices with an older Linux "
         .. "kernel.\n\n"
         .. "Recommended for this device: %1, with full feature support.\n\n"
         .. "The binary (~10–20 MB) will be downloaded — Wi-Fi is required."),
            recommended)
    end

    local ButtonDialog = require("ui/widget/buttondialog")
    local dlg
    dlg = ButtonDialog:new{
        title = body,
        buttons = {
            {{
                text     = T(_("Set up & download (%1)"), recommended),
                callback = function()
                    UIManager:close(dlg)
                    if recommended == "v1.2.2" then
                        -- The setup body already carried the v1.2.2 note, so
                        -- go straight to install rather than repeating it.
                        enableAndInstall(self, "v1.2.2", tmi)
                    else
                        enableAndInstall(self, recommended, tmi)
                    end
                end,
            }},
            {{
                text     = _("Choose version manually"),
                callback = function()
                    UIManager:close(dlg)
                    showVersionPicker(self, tmi)
                end,
            }},
            {{
                text     = _("Cancel"),
                callback = function() UIManager:close(dlg) end,
            }},
        },
    }
    UIManager:show(dlg)
end

--- Build and return the Legacy Syncthing sub-menu item table.
-- This is called from getSetupMenu() in st_menu.lua and returns a list of
-- items that represent the complete legacy configuration surface.
function Legacy.buildMenuItems(self)
    local items  = {}
    local enabled = Legacy.isEnabled()
    local version = Legacy.getVersion()
    local D = require("st_disabled")

    -- ── Enable / disable toggle ──────────────────────────────────────────
    local toggle_help = _(
        "Legacy mode runs an older Syncthing binary that is compatible with "
     .. "devices whose Linux kernel is older than 3.2.\n\n"
     .. "You normally do not need this unless Syncthing crashes immediately "
     .. "on startup with a 'runtime: netpoll failed' or 'epollwait failed' error.\n\n"
     .. "Two versions are available:\n"
     .. "• v1.27.12 — kernels 2.6.32–3.1, full API support\n"
     .. "• v1.2.2   — kernels below 2.6.32 (e.g. Kindle PW1), limited API")
    table.insert(items, {
        text_func = function()
            if Legacy.isEnabled() then
                return T(_("Legacy mode: ON (%1)"), Legacy.getVersion())
            else
                -- An action, not a status line: tapping it starts setup.
                return _("Set up Legacy mode…")
            end
        end,
        help_text      = toggle_help,
        keep_menu_open = true,
        hold_callback  = D.helpHold(toggle_help),
        callback       = function(tmi)
            if Legacy.isEnabled() then
                UIManager:show(ConfirmBox:new{
                    text        = _("Disable legacy mode?\n\n"
                                .. "Syncthing will be stopped. Restart it to use the standard binary."),
                    ok_text     = _("Disable"),
                    cancel_text = _("Cancel"),
                    ok_callback = function()
                        -- stop() first so its status message (if any) appears
                        -- before the menu refreshes.  Legacy.disable() is called
                        -- inside the callback so the sequence is clean.
                        self:stop(function()
                            Legacy.disable(self)
                            if tmi then tmi:updateItems() end
                        end)
                    end,
                })
            else
                showLegacySetup(self, tmi)
            end
        end,
    })

    -- ── Change version (only when enabled) ──────────────────────────────
    if enabled then
        local change_ver_help = T(_(
            "Change the legacy Syncthing version.\n\n"
         .. "Currently: %1\n\n"
         .. "Changing the version stops Syncthing. You will also need to "
         .. "download the new binary before restarting."), version)
        table.insert(items, {
            text_func      = function()
                return T(_("Legacy version: %1"), Legacy.getVersion())
            end,
            help_text      = change_ver_help,
            keep_menu_open = true,
            hold_callback  = D.helpHold(change_ver_help),
            callback       = function(tmi)
                showVersionPicker(self, tmi)
            end,
        })

        -- ── Download / re-download the binary ───────────────────────────
        -- The label distinguishes "Re-download" (the selected version is the
        -- one currently on disk) from "Download" (a different version is on
        -- disk, or nothing is — the user must fetch the selected one).  This
        -- relies on syncthing_legacy_installed_version, written by
        -- downloadBinary() only after a successful install (AD-14).
        local dl_help = T(_(
            "Download the legacy Syncthing binary (%1) for this device.\n\n"
         .. "The binary is saved as 'syncthing-legacy' in the plugin folder. "
         .. "Approximately 10–20 MB depending on architecture.\n\n"
         .. "The two legacy versions share one file, so switching version "
         .. "requires downloading the newly selected one before it can start."), version)
        table.insert(items, {
            text_func = function()
                local sel  = Legacy.getVersion()
                local inst = G_reader_settings:readSetting("syncthing_legacy_installed_version")
                if inst == sel and util.pathExists(U.plugin_path .. "syncthing-legacy") then
                    return T(_("Re-download legacy binary (%1)"), sel)
                else
                    return T(_("Download legacy binary (%1)"), sel)
                end
            end,
            help_text      = dl_help,
            keep_menu_open = true,
            hold_callback  = D.helpHold(dl_help),
            callback       = function()
                Legacy.downloadBinary(self, Legacy.getVersion(), function(ok, err)
                    if ok then
                        UIManager:show(ConfirmBox:new{
                            text        = T(_(
                                "Legacy Syncthing %1 is installed and ready.\n\nStart it now?"),
                                Legacy.getVersion()),
                            ok_text     = _("Start"),
                            cancel_text = _("Later"),
                            ok_callback = function()
                                self:onToggleSyncthingServer()
                            end,
                        })
                    end
                    -- Error dialogs are shown inside downloadBinary itself
                end)
            end,
        })
    end

    return items
end

return Legacy
