-- st_process.lua - Binary lifecycle: start/stop/isRunning, performance and network settings, first-run dialog
local DataStorage     = require("datastorage")
local Device          = require("device")
local UIManager       = require("ui/uimanager")
local ConfirmBox      = require("ui/widget/confirmbox")
local InfoMessage     = require("ui/widget/infomessage")
local NetworkMgr      = require("ui/network/manager")
local ffiutil         = require("ffi/util")
local logger          = require("logger")
local JSON 			  = require("json")
local util            = require("util")
local _               = require("syncthing_i18n").gettext
local T               = ffiutil.template

local U = require("st_utils")

local path     = DataStorage:getFullDataDir()
local pid_path = "/tmp/syncthing_koreader.pid"

local _binary_exists_cache = nil
local _binary_arch_cache   = nil

---------------------------------------------------------------------------
-- Kindle port guard
--
-- iptables on Kindle must be opened before the daemon accepts connections
-- and closed on every exit path from start()/stop().  Forgetting one exit
-- path leaks the rule until the next stop() call.
--
-- Pattern:
--   self._kindle_release = kindlePortGuard(port)   -- opens port
--   ...
--   releaseKindlePort(self)                         -- closes idempotently
--
-- kindlePortGuard() opens the port and returns a closure.
-- releaseKindlePort() calls the closure once then clears it from self.
-- Calling releaseKindlePort() again is safe (no-op).
---------------------------------------------------------------------------

local function kindlePortGuard(port)
    if Device:isKindle() then
        U.kindleOpenPort(port)
        U.kindleOpenPort("22000")      -- sync protocol (TCP) - required for pairing and data transfer
        U.kindleOpenPortUDP("21027")   -- local discovery (UDP) - speeds up initial peer detection
    end
    local released = false
    return function()
        if released then return end
        released = true
        if Device:isKindle() then
            U.kindleClosePort(port)
            U.kindleClosePort("22000")
            U.kindleClosePortUDP("21027")
        end
    end
end

local function releaseKindlePort(self)
    if self._kindle_release then
        self._kindle_release()
        self._kindle_release = nil
    end
end

local function binaryExists(self)
    if _binary_exists_cache ~= nil then return _binary_exists_cache end

    local p = U.getBinaryPath()

    -- Fast path: the file must exist at the expected location.
    if not util.pathExists(p) then
        _binary_exists_cache = false
        return false
    end

    -- A valid Syncthing binary is an ELF executable.
    -- Read the magic bytes to confirm it is not a text file (e.g. the
    -- Kobo appstream metadata file named "syncthing" that ships in the
    -- plugin directory on some Kobo firmware versions).
    --
    -- We open in binary mode because the ELF magic includes non-printable
    -- bytes and we only need the first four.
    if not U.isELF(p) then
        -- The file is either too short, not an ELF, or corrupted.
        -- We cache the negative result because the filesystem is unlikely
        -- to change within a session.
        _binary_exists_cache = false
        return false
    end

    -- It's a genuine ELF binary - cache and return true.
    _binary_exists_cache = true
    return true
end

local function invalidateBinaryCache(self)
    _binary_exists_cache = nil
    _binary_arch_cache   = nil
end

local function getBinaryArch(self)
    if _binary_arch_cache ~= nil then return _binary_arch_cache end

    local binary = U.getBinaryPath()
    local arch = nil

    -- Attempt 1: Manual ELF header parsing (works everywhere, no external tools)
    local f = io.open(binary, "rb")
    if f then
        local header = f:read(20)
        f:close()
        if header and #header >= 20 then
            -- ELF e_machine field is at bytes 19-20 (little-endian)
            local lo = header:byte(19)
            local hi = header:byte(20)
            local e_machine = lo + hi * 256
            if e_machine == 40 then          -- EM_ARM
                arch = "ARM"
            elseif e_machine == 183 then     -- EM_AARCH64
                arch = "AArch64"
            elseif e_machine == 62 then      -- EM_X86_64
                arch = "X86-64"
            elseif e_machine == 3 then       -- EM_386
                arch = "80386"
            end
        end
    end

    -- Attempt 2: file command (fallback if ELF read failed)
    if not arch or arch == "" then
        local p = io.popen(string.format("file '%s' 2>/dev/null", binary))
        if p then
            local out = p:read("*l")
            p:close()
            if out then
                if out:find("ARM") or out:find("arm") then
                    if out:find("64") or out:find("AArch64") then
                        arch = "AArch64"
                    else
                        arch = "ARM"
                    end
                elseif out:find("x86%-64") or out:find("X86%-64") then
                    arch = "X86-64"
                elseif out:find("80386") then
                    arch = "80386"
                end
            end
        end
    end

    if not arch or arch == "" then
        logger.warn("[Syncthing] Could not detect binary architecture: " .. binary)
        arch = "unknown"
    end

    if arch == "ARM" or arch == "ARM64" or arch == "AArch64" then
        if arch == "AArch64" then arch = "ARM64" end
    elseif arch == "X86-64" or arch == "X86_64" then
        arch = "x86_64"
    elseif arch == "80386" then
        arch = "i386"
    end

    _binary_arch_cache = arch
    return arch
end

local function binaryMatchesDevice(self)
    -- Re-verify with a fresh filesystem read before doing anything.
    if not U.isELF(U.getBinaryPath()) then
        invalidateBinaryCache(self)  -- stale; next binaryExists() re-reads
        return false                 -- start() shows first-run dialog instead
    end
    local p = io.popen("uname -m 2>/dev/null")
    if not p then return true end
    local line = p:read("*l")
    p:close()
    if not line then return true end
    local sys_arch = line:gsub("^%s+", ""):gsub("%s+$", "")
    local bin_arch = getBinaryArch(self)

    if bin_arch == "unknown" then
        local key = "syncthing_arch_warning_shown"
        if not G_reader_settings:isTrue(key) then
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = _("Could not verify that the Syncthing binary matches this device's architecture.\n\n"
                      .. "If it crashes at startup, download the correct version from\n"
                      .. "github.com/syncthing/syncthing/releases."),
                timeout = 5,
            })
            G_reader_settings:saveSetting(key, true)
        end
        return true
    end

    if sys_arch == "armv7l" or sys_arch == "armv6l" then sys_arch = "ARM" end
    if sys_arch == "aarch64" then sys_arch = "ARM64" end
    if sys_arch == "x86_64" then sys_arch = "x86_64" end
    if sys_arch:match("^i[3-6]86$") then sys_arch = "i386" end
    return bin_arch:lower() == sys_arch:lower()
end

local function safeHomeDir(self)
    local home = G_reader_settings:readSetting("home_dir")
    if not home then return nil end
    home = home:match("^(.-)/*$")
    if U.DANGEROUS_PATHS[home] then return nil end
    return home
end

-- Verify that a PID actually belongs to syncthing, not just any
-- process that happened to recycle the PID we wrote earlier.
--
-- Three layers of detection, ordered by reliability and portability:
--   1. /proc/<pid>/comm - present on every modern Linux kernel
--      including those on Kindle and Kobo; this is the primary path.
--   2. /proc/<pid>/cmdline - fallback for kernels with /proc but where
--      /comm is unreadable for some reason; reads the actual command
--      line that was used to exec the process.
--   3. `ps -p PID -o comm=` - last-resort fallback for systems where
--      /proc is mounted differently.  Some BusyBox builds don't
--      support `-p` + `-o comm=` together (different argument
--      parsers), so we also accept a generic `ps` listing.
local function isProcessSyncthing(pid)
    -- 1. /proc/PID/comm
    local f = io.open("/proc/" .. pid .. "/comm", "r")
    if f then
        local comm = f:read("*l")
        f:close()
        if comm == "syncthing" then return true end
    end

    -- 2. /proc/PID/cmdline (null-byte separated)
    f = io.open("/proc/" .. pid .. "/cmdline", "r")
    if f then
        local cmdline = f:read("*a")
        f:close()
        if cmdline and cmdline:find("syncthing", 1, true) then return true end
    end

    -- 3. ps with -o comm= (works on coreutils, may not on old BusyBox)
    local p = io.popen("ps -p " .. pid .. " -o comm= 2>/dev/null")
    if p then
        local comm = p:read("*l")
        p:close()
        if comm and comm:match("syncthing") then return true end
    end

    -- 4. last resort: plain `ps` then grep the PID line.  BusyBox `ps`
    --    output starts with a header followed by lines of the form
    --    "  PID USER ... CMD".  We require the syncthing token to
    --    appear on the SAME line as our PID.
    p = io.popen("ps 2>/dev/null")
    if p then
        local needle = string.format("^%s+%s%s", "%s*", tostring(pid), "%s+")
        for line in p:lines() do
            if line:find(needle) and line:find("syncthing", 1, true) then
                p:close()
                return true
            end
        end
        p:close()
    end
    return false
end

local function getPid(self)
    local f = io.open(pid_path, "r")
    if not f then return nil end
    local line = f:read("*l")
    f:close()
    return tonumber(line)
end

local function isRunning(self)
    local cached = self:_cacheGet("is_running")
    if cached ~= nil then return cached end
    local pid = getPid(self)
    if not pid then return self:_cacheSet("is_running", false) end
    if U.execOk(os.execute(string.format("kill -0 %d 2>/dev/null", pid))) then
        if isProcessSyncthing(pid) then
            return self:_cacheSet("is_running", true)
        else
            os.remove(pid_path)
            return self:_cacheSet("is_running", false)
        end
    end
    os.remove(pid_path)
    return self:_cacheSet("is_running", false)
end

local function start(self, callback)
    -- Capture and immediately clear the "silent start" flag so it cannot
    -- leak into a later manual start when this call exits early.
	local silent_start = self._silentStart
    self._silentStart = nil

	U.setAutostartPaused(false)

    if not binaryExists(self) then
        if silent_start then
            if callback then callback() end
        else
            self:showFirstRunDialog(callback)
        end
        return
    end

    -- Re-entrancy guard.  KOReader is single-threaded LuaJIT, so the
    -- read-then-write on `self._starting` is atomic with respect to
    -- itself - two `start` calls from rapid taps cannot race here.  We
    -- still keep the flag because callbacks fired during async work
    -- (UIManager:scheduleIn, tcp:receive, etc.) can re-enter the
    -- coroutine boundary and would otherwise launch a second daemon.
    if self._starting or self._stopping then
        if callback then callback() end
        return
    end
    self._starting = true
	local standby_held = true
	local function _cleanupStartResources(reason)
		if standby_held then
			UIManager:allowStandby()
			standby_held = false
		end
		releaseKindlePort(self)
		self._starting = false
		if callback then
			local ok, _ = pcall(callback)
			if not ok then logger.warn("[Syncthing] start() callback failed") end
		end
	end
    UIManager:preventStandby()
	
    -- The loopback interface state can change between sessions (the
    -- user may have rebooted, suspended, or the OS may have torn `lo`
    -- down on a network event).  Drop the sticky cache so the Kobo
    -- path below re-probes with a fresh `ip link show lo`.
    U.invalidateLoopbackCache()

    if not binaryMatchesDevice(self) then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("The installed Syncthing binary is incompatible with this device's architecture.\n\nPlease download the correct binary from github.com/syncthing/syncthing/releases and place it in the plugin folder.")
        })
        UIManager:allowStandby()
        self._starting = false
        if callback then callback() end
        return
    end

    local home = safeHomeDir(self)
    if not home then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _(
                "Home folder is not set or points to a system directory.\n\n" ..
                "Syncthing syncs the folder you set as your KOReader home directory. " ..
                "Please go to KOReader Settings → Home folder and set a safe path " ..
                "(e.g. /mnt/us/documents on Kindle, or /mnt/onboard on Kobo) " ..
                "before starting Syncthing.")
        })
        UIManager:allowStandby()
        self._starting = false
        if callback then callback() end
        return
    end

    self:_cacheInvalidate()
    if isRunning(self) then
        UIManager:allowStandby()
        self._starting = false
        if callback then callback() end
        return
    end

    self.active_port = self.syncthing_port

    -- Inject GUI credentials only if config.xml doesn't already have them.
    if self.gui_password then
        -- Compute the config path through the shared helper.
        local config_xml_path = U.getConfigDir() .. "/config.xml"
        local need_update = true
        if util.pathExists(config_xml_path) then
            local f = io.open(config_xml_path, "r")
            if f then
                local content = f:read("*a")
                f:close()
                if content and content:find("<user>") and content:find("<password>") then
                    need_update = false
                end
            end
        end
        if need_update then
            local ok, err = U.setGUIPassword(self.gui_password, U.getConfigDir(), self.gui_user)
            if not ok then
                UIManager:show(InfoMessage:new{
                    icon = "notice-warning",
                    text = T(_("Could not write the Web GUI password to Syncthing's config.\n\nDetails: %1\n\nNot starting Syncthing — the GUI would be exposed without authentication."),
                             tostring(err or "unknown error")),
                })
                UIManager:allowStandby()
				-- Fire callback BEFORE releasing the guard so it cannot re-enter start().
                -- pcall ensures a broken callback never leaves _starting stuck.
                if callback then
                    local ok, _ = pcall(callback)
                    if not ok then logger.warn("[Syncthing] start() callback failed") end
                end
                self._starting = false
                return
            end
        end
    end
	
	-- Kobo devices often have the loopback interface down by default,
    -- which prevents Syncthing from reaching its own REST API on 127.0.0.1.
    -- Bring it up explicitly; failure here is fatal because the daemon
    -- won't be able to function without loopback.
    if Device:isKobo() and not U.loopbackIsUp() then
        local ok = U.execOk(os.execute("ifconfig lo up 2>/dev/null"))
                or U.execOk(os.execute("ip link set lo up 2>/dev/null"))
        if not ok then
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = _(
                    "Could not bring up the loopback network interface.\n\n" ..
                    "Syncthing communicates with itself over localhost (127.0.0.1), " ..
                    "which requires the loopback interface to be active. " ..
                    "This is a system-level issue — try rebooting your device. " ..
                    "If the problem persists, your device may have a non-standard network configuration.")
            })
            UIManager:allowStandby()
            self._starting = false
            if callback then callback() end
            return
        end
    end
	
    -- PocketBook devices may have the loopback interface up but without
    -- an IP address, which prevents Syncthing from reaching its own API
    -- on 127.0.0.1.  Assign the address explicitly when it is missing.
    --
    -- Both commands require elevated privileges that KOReader typically does
    -- not have on PocketBook; they will succeed on rooted devices or firmware
    -- builds where the Syncthing process has the CAP_NET_ADMIN capability.
    -- On non-rooted devices the commands fail silently (2>/dev/null) and we
    -- log a warning so the user can find the root cause in the log viewer.
    -- This is the most likely explanation for issue #33 ("Device ID unknown
    -- on PocketBook Era Colour"): Syncthing starts but cannot reach 127.0.0.1.
    if Device:isPocketBook() then
        local has_addr = U.execOk(os.execute("ifconfig lo | grep -q 127.0.0.1"))
        if not has_addr then
            local ok = U.execOk(os.execute("sudo ifconfig lo 127.0.0.1 up 2>/dev/null"))
                    or U.execOk(os.execute("ip addr add 127.0.0.1/8 dev lo 2>/dev/null"))
            if not ok then
                logger.warn("[Syncthing] PocketBook: loopback interface (lo) has no IP address" ..
                    " and we could not assign 127.0.0.1 (no root/CAP_NET_ADMIN)." ..
                    " Syncthing will start but its REST API on 127.0.0.1 may be unreachable." ..
                    " Symptoms: 'Device ID unknown', connection refused errors.")
            else
                logger.info("[Syncthing] PocketBook: assigned 127.0.0.1 to lo successfully.")
            end
        end
    end

    -- Create the standard config directory if missing.
    if not util.makePath(U.getConfigDir()) then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Could not create settings directory for Syncthing.\nCheck file system permissions.")
        })
        UIManager:allowStandby()
        self._starting = false
        if callback then callback() end
        return
    end

    -- AD-19: resolve where the SQLite database lives.  On an affected Kindle
    -- this relocates it off the hard_remove FUSE mount to a persistent ext
    -- partition; elsewhere it equals the config dir.  The reason is stored for
    -- the one-time post-start notice further down.
    local data_dir, data_reason = U.getDataDir()
    self._data_dir_reason = data_reason
    local cmd = string.format(
        "sh '%s' '%s' '%s' '%s' '%s' '%s' '%s'",
        U.shellEscape(U.plugin_path .. "start-syncthing"),
        U.shellEscape(home),
        U.shellEscape(self.active_port),
        U.shellEscape(path),
        U.shellEscape(self.resource_profile),
        U.shellEscape(self.network_access),
        U.shellEscape(data_dir))

    if not U.execOk(os.execute(cmd)) then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _(
                "Failed to launch the Syncthing process.\n\n" ..
                "This usually means the binary is not executable or is the wrong architecture " ..
                "for this device.\n\n" ..
                "Check Maintenance → View logs for details, or try re-downloading the binary.")
        })
        releaseKindlePort(self)  -- close any leftover port from a prior failed start
        UIManager:allowStandby()
        self._starting = false
        if callback then callback() end
        return
    end

    -- If a previous start() crashed without a matching stop(), the old
    -- iptables closure is still alive.  Calling it now closes the stale
    -- rule so we never accumulate duplicate ACCEPT entries in the chain.
    if self._kindle_release then
        self._kindle_release()
        self._kindle_release = nil
    end

    -- Open the Kindle iptables port and capture a guard that closes it
    -- on any subsequent exit path (check_pid timeout, stop(), onCloseWidget).
    self._kindle_release = kindlePortGuard(self.active_port)

    local attempts = 0
    local max_wait = 24

    local function check_pid()
        if not self._health_check_active then
            local pid = getPid(self)
            if pid and isProcessSyncthing(pid) then
                os.execute(string.format("kill %d 2>/dev/null", pid))
                os.remove(pid_path)
            end
            _cleanupStartResources("unload")
            return
        end
        attempts = attempts + 1
        if util.pathExists(pid_path) then
            local pid = getPid(self)
            if pid and U.execOk(os.execute(string.format("kill -0 %d 2>/dev/null", pid))) and isProcessSyncthing(pid) then
                standby_held = false   -- allowStandby() is called below
                self:_cacheInvalidate()
                -- Apply network settings via API (slightly later so the
                -- performance PUT has settled first).
                UIManager:scheduleIn(3, function()
                    if not self._health_check_active or not self:isRunning() then return end
                    self:applyNetworkSettings()
                end)

                -- Automatically apply safe defaults for folders on
                -- FAT/FUSE filesystems (typical on Kindle/Kobo).
                -- These prevent spurious conflicts caused by timestamp
                -- resolution, permission mismatch, and ownership tracking.
                UIManager:scheduleIn(5, function()
                    if not self._health_check_active or not self:isRunning() then return end
                    local folders = self:getFolders() or {}
                    for _, folder in ipairs(folders) do
                        local folder_path = folder.path or ""
                        if folder_path ~= "" and util.pathExists(folder_path) then
                            local fs_type = util.getFilesystemType(folder_path)
                            if not fs_type then
                                local parent = folder_path:match("^(/[^/]+)")
                                if parent then
                                    fs_type = util.getFilesystemType(parent)
                                end
                            end
                            if fs_type and (fs_type == "vfat" or fs_type == "msdos" or fs_type:match("^fuse%.")) then
                                local patch = {}
                                local need_patch = false

                                if (folder.modTimeWindowS or 0) == 0 then
                                    patch.modTimeWindowS = 2
                                    need_patch = true
                                end
                                if (folder.ignorePerms or false) ~= true then
                                    patch.ignorePerms = true
                                    need_patch = true
                                end
                                if (folder.syncOwnership or false) == true then
                                    patch.syncOwnership = false
                                    need_patch = true
                                end
                                if (folder.sendOwnership or false) == true then
                                    patch.sendOwnership = false
                                    need_patch = true
                                end

                                if need_patch then
                                    local fid = folder.id or ""
                                    if fid ~= "" then
                                        local r = self:patchFolder(fid, patch)
                                        if not U.isOk(r) then
                                            logger.warn("[Syncthing] start: could not set FAT defaults for folder "
                                                .. fid .. ": " .. (U.errOf(r)))
                                        end
                                    end
                                end
                            end
                        end
                    end
                end)
                if not silent_start then
                    UIManager:show(InfoMessage:new{
                        timeout = 3,
                        text    = _("Syncthing started"),
                    })
                end

                -- AD-19: one-time notice when the database was relocated off a
                -- hard_remove FUSE mount.  redirected/redirected_tight is a
                -- non-blocking toast via the serialized notification queue, so
                -- it never stacks with the first-run/password dialogs; it is
                -- scheduled a few seconds out so it follows the start UI and the
                -- deferred setup above.  fallback_warn needs user action, so it
                -- is a modal - but deferred until onboarding (password) is done
                -- and skipped on silent/background starts.
                if not silent_start then
                    local dreason = self._data_dir_reason
                    if (dreason == "redirected" or dreason == "redirected_tight")
                            and not G_reader_settings:isTrue("syncthing_data_notice_seen") then
                        G_reader_settings:saveSetting("syncthing_data_notice_seen", true)
                        UIManager:scheduleIn(6, function()
                            self:showNotification(_(
                                "Syncthing's database is on internal storage for reliability "
                                .. "on this device. The first scan may take a little longer — "
                                .. "your files are not affected."), 6)
                        end)
                    elseif dreason == "fallback_warn"
                            and not G_reader_settings:isTrue("syncthing_data_notice_seen")
                            and G_reader_settings:isTrue("syncthing_password_configured") then
                        G_reader_settings:saveSetting("syncthing_data_notice_seen", true)
                        UIManager:scheduleIn(6, function()
                            UIManager:show(InfoMessage:new{
                                icon = "notice-warning",
                                text = _(
                                    "This device's storage can make Syncthing's database "
                                    .. "unreliable, and no alternative partition has enough free "
                                    .. "space. Syncing may be unstable. Free up space on internal "
                                    .. "storage (e.g. /var/local) and restart Syncthing."),
                            })
                        end)
                    end
                end

                self:_invalidateConflictCache()

                -- Notify companion plugins
                if self._notifiers then self._notifiers.notifyProcessStarted() end

                UIManager:allowStandby()
                if callback then
                    local ok, _ = pcall(callback)
                    if not ok then logger.warn("[Syncthing] start() callback failed") end
                end
                self._starting = false
                return
            end
        end
        if attempts < max_wait then
            UIManager:scheduleIn(0.5, check_pid)
        else
            _cleanupStartResources("timeout")
            local remedy = _("Re-install it from Maintenance → Check for updates, or download the "
                    .. "correct binary for your device from "
                    .. "github.com/syncthing/syncthing/releases and place it in the plugin folder.")
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = T(_("Syncthing is taking too long to start (>12 seconds).\n\n"
                        .. "This is usually a first-run delay while it generates its keys, "
                        .. "or a binary that does not run on this device.\n\n"
                        .. "%1\n\n"
                        .. "Check Maintenance → View logs for details."), remedy),
            })
        end
    end
    UIManager:scheduleIn(0.5, check_pid)
end

local function stop(self, callback, is_suspend, silent)
    if self._stopping or self._starting then
        if callback then callback() end
        return
    end
    self._stopping = true
    UIManager:preventStandby()

    self.api_key        = nil
    local port_to_clean = self.active_port or self.syncthing_port
    self.active_port    = nil

    local pid = getPid(self)
	if not pid then
		self:_cacheInvalidate()
		releaseKindlePort(self)
		if not silent then	-- honour silent flag for background stops
			UIManager:show(InfoMessage:new{ timeout = 2, text = _("Syncthing is already stopped.") })
		end
		UIManager:allowStandby()
		self._stopping = false
		if callback then callback() end
		return
	end

	if not isProcessSyncthing(pid) then
		os.remove(pid_path)
		self:_cacheInvalidate()
		releaseKindlePort(self)
		if not silent then
			UIManager:show(InfoMessage:new{ timeout = 2, text = _("Syncthing is already stopped.") })
		end
		UIManager:allowStandby()
		self._stopping = false
		if callback then callback() end
		return
	end

    os.execute(string.format("kill %d 2>/dev/null", pid))
    self:_cacheInvalidate()

    if is_suspend then
        -- INTENTIONAL synchronous sleep.  This branch runs from
        -- onSuspend, which must complete BEFORE the OS suspends the
        -- device - any UIManager:scheduleIn callback we schedule here
        -- would not fire until after resume, by which point the kernel
        -- has already paused the daemon's I/O.  We accept blocking the
        -- UI thread for ~1s to give Syncthing a chance to flush its
        -- database cleanly; otherwise we get the "disk I/O error: no
        -- such file or directory" cascade seen in user logs after
        -- suspend/resume.
        os.execute("sleep 1")
        local p = getPid(self)
        local alive = p and U.execOk(os.execute(string.format("kill -0 %d 2>/dev/null", p)))
        if not alive then
            os.remove(pid_path)
            self:_cacheInvalidate()
            releaseKindlePort(self)
            UIManager:allowStandby()
            self._stopping = false
            if callback then callback() end
            return
        end
        os.execute(string.format("kill -9 %d 2>/dev/null", pid))
        os.remove(pid_path)
        self:_cacheInvalidate()
        releaseKindlePort(self)
        UIManager:allowStandby()
        self._stopping = false
        if callback then callback() end
        return
    end

	local function finish_stop()
        os.remove(pid_path)
		-- If this was a deliberate manual stop (not suspend), clear the
		-- "was running" flag so we don't resurrect Syncthing on next start.
		-- Only pause Autostart (a session-only flag) on explicit manual stops:
		-- automatic stops (network disconnect, app close) pass silent=true
		-- and must NOT set the flag, or Autostart breaks on reconnect/relaunch.
		if not is_suspend then
			G_reader_settings:saveSetting("syncthing_was_running", false)
			if not silent then
				U.setAutostartPaused(true)
			end
		end
        self:_cacheInvalidate()
        releaseKindlePort(self)
    if not silent then
		UIManager:show(InfoMessage:new{ timeout = 2, text = _("Syncthing stopped.") })
	end

        -- Notify companion plugins
        if self._notifiers then self._notifiers.notifyProcessStopped() end

        UIManager:allowStandby()
        self._stopping = false
        if callback then callback() end
    end

    local function check_stopped(attempt)
        local p     = getPid(self)
        local alive = p and U.execOk(os.execute(string.format("kill -0 %d 2>/dev/null", p)))
        if not alive or not isProcessSyncthing(p) then
            finish_stop()
        elseif attempt < 4 then
            UIManager:scheduleIn(1, function() check_stopped(attempt + 1) end)
        elseif attempt == 4 then
            os.execute(string.format("kill -9 %d 2>/dev/null", p))
            UIManager:scheduleIn(0.5, function() check_stopped(5) end)
        else
            releaseKindlePort(self)
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = T(_(
                    "Syncthing is not responding to stop signals.\n\n" ..
                    "Process (PID %1) is still alive after a forced kill.\n\n" ..
                    "This can happen when the kernel is waiting for a filesystem operation " ..
                    "to finish. Try rebooting if the problem persists."), pid)
            })
            UIManager:allowStandby()
            self._stopping = false
            if callback then callback() end
        end
    end
    check_stopped(0)
end

-- Apply folder/device-level performance tweaks via Syncthing REST API.
-- This is NOT called automatically - the user must explicitly request it
-- from the menu.  It modifies config.xml through the API, so it will
-- persist across restarts.
--
-- Implementation note: we use targeted per-resource endpoints
-- (config/folders/{id}, config/devices/{id}) with PATCH to avoid
-- accidentally sending empty arrays that the Go JSON decoder rejects.
local function applyPerformanceSettings(self)
    if not self:isRunning() then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Syncthing must be running to apply performance settings."),
        })
        return
    end

    UIManager:scheduleIn(1, function()
        local any_changed = false
        local any_failed  = false

        -- Folders
        local folders = self:getFolders()
        if not folders then
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = _("Could not read Syncthing configuration.\n\nTry again in a few seconds."),
            })
            return
        end

		for _, folder in ipairs(folders) do
			local changed = false
			local fs_type = util.getFilesystemType(folder.path or "")

			-- Standard resource profile settings
			if self.resource_profile == "low" then
				if (folder.copiers or 0)              ~= 1     then folder.copiers              = 1;     changed = true end
				if (folder.hashers or 0)              ~= 1     then folder.hashers              = 1;     changed = true end
				if (folder.pullerMaxPendingKiB or 0)  ~= 16384 then folder.pullerMaxPendingKiB  = 16384; changed = true end
				if (folder.scanProgressIntervalS or 0)~= -1    then folder.scanProgressIntervalS = -1;   changed = true end
			else
				if (folder.copiers or 0)              ~= 2     then folder.copiers              = 2;     changed = true end
				if (folder.hashers or 0)              ~= 2     then folder.hashers              = 2;     changed = true end
				if (folder.pullerMaxPendingKiB or 0)  ~= 32768 then folder.pullerMaxPendingKiB  = 32768; changed = true end
				if (folder.scanProgressIntervalS or 0)~= 10    then folder.scanProgressIntervalS = 10;   changed = true end
			end

			-- FAT-specific settings (prevent spurious conflicts and slow scans).
			if fs_type and (fs_type == "vfat" or fs_type == "msdos" or fs_type:match("^fuse%.")) then
				if (folder.modTimeWindowS or 0) ~= 2 then
					folder.modTimeWindowS = 2
					changed = true
				end
				if (folder.ignorePerms or false) ~= true then
					folder.ignorePerms = true
					changed = true
				end
				if (folder.syncOwnership or false) ~= false then folder.syncOwnership = false; changed = true end
				if (folder.sendOwnership or false) ~= false then folder.sendOwnership = false; changed = true end
				if (folder.syncXattrs or false)    ~= false then folder.syncXattrs    = false; changed = true end
				if (folder.sendXattrs or false)    ~= false then folder.sendXattrs    = false; changed = true end
			end

			if changed then
				local fid = folder.id or ""
				local patch = {
					copiers                = folder.copiers,
					hashers                = folder.hashers,
					pullerMaxPendingKiB    = folder.pullerMaxPendingKiB,
					scanProgressIntervalS  = folder.scanProgressIntervalS,
					modTimeWindowS         = folder.modTimeWindowS,
					ignorePerms            = folder.ignorePerms,
					syncOwnership          = folder.syncOwnership,
					sendOwnership          = folder.sendOwnership,
					syncXattrs             = folder.syncXattrs,
					sendXattrs             = folder.sendXattrs,
				}
				local result = self:patchFolder(fid, patch)
				local ok = U.isOk(result)
				if ok then any_changed = true else any_failed = true end
			end
		end
        -- Devices
        local devices = self:getDevices()
        if devices then
            local desired = (self.resource_profile == "low") and 1 or 2
            for _, device in ipairs(devices) do
                if (device.numConnections or 0) ~= desired then
					local did = device.deviceID or ""
					local patch = { numConnections = desired }
					local result = self:patchDevice(did, patch)
				local ok = U.isOk(result)
                    if ok then any_changed = true else any_failed = true end
                end
            end
        end


        -- Result
        if any_failed then
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = _("Failed to apply some performance settings.\n\nCheck the API error log under Maintenance."),
            })
        elseif any_changed then
            UIManager:show(InfoMessage:new{
                timeout = 3,
                text = _("Performance settings applied.\n\nChanges take effect immediately."),
            })
        else
            UIManager:show(InfoMessage:new{
                timeout = 3,
                text = _("Performance settings are already optimal."),
            })
        end
    end)
end

-- Reset folder/device-level performance settings back to Syncthing defaults.
-- This gives users a safe way to revert any changes made by "Apply resource tweaks".
local function resetPerformanceSettings(self)
    if not self:isRunning() then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Syncthing must be running to reset performance settings."),
        })
        return
    end

    UIManager:scheduleIn(1, function()
        local any_changed = false
        local any_failed  = false

        -- Folders
        local folders = self:getFolders()
        if not folders then
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = _("Could not read Syncthing configuration."),
            })
            return
        end

		for _, folder in ipairs(folders) do
			local changed = false
			-- 0 means "let the system decide", which is the Syncthing default
			if (folder.copiers or 0) ~= 0 then folder.copiers = 0; changed = true end
			if (folder.hashers or 0) ~= 0 then folder.hashers = 0; changed = true end
			if (folder.pullerMaxPendingKiB or 0) ~= 0 then folder.pullerMaxPendingKiB = 0; changed = true end
			if (folder.scanProgressIntervalS or 0) ~= 0 then folder.scanProgressIntervalS = 0; changed = true end
			-- Also reset FAT-specific settings
			if (folder.modTimeWindowS or 0) ~= 0 then folder.modTimeWindowS = 0; changed = true end
			if (folder.ignorePerms or false) ~= false then folder.ignorePerms = false; changed = true end
			if (folder.syncOwnership or false) ~= false then folder.syncOwnership = false; changed = true end
			if (folder.sendOwnership or false) ~= false then folder.sendOwnership = false; changed = true end
			if (folder.syncXattrs or false) ~= false then folder.syncXattrs = false; changed = true end
			if (folder.sendXattrs or false) ~= false then folder.sendXattrs = false; changed = true end
			if changed then
				local fid = folder.id or ""
				local patch = {
					copiers                = folder.copiers,
					hashers                = folder.hashers,
					pullerMaxPendingKiB    = folder.pullerMaxPendingKiB,
					scanProgressIntervalS  = folder.scanProgressIntervalS,
					modTimeWindowS         = folder.modTimeWindowS,
					ignorePerms            = folder.ignorePerms,
					syncOwnership          = folder.syncOwnership,
					sendOwnership          = folder.sendOwnership,
					syncXattrs             = folder.syncXattrs,
					sendXattrs             = folder.sendXattrs,
				}
				local result = self:patchFolder(fid, patch)
				local ok = U.isOk(result)
				if ok then any_changed = true else any_failed = true end
			end
		end

        -- Devices
        local devices = self:getDevices()
        if devices then
            for _, device in ipairs(devices) do
                if (device.numConnections or 0) ~= 0 then
                    local did = device.deviceID or ""
                    local patch = { numConnections = 0 }
                    local result = self:patchDevice(did, patch)
				local ok = U.isOk(result)
                    if ok then any_changed = true else any_failed = true end
                end
            end
        end

        -- Result
        if any_failed then
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = _("Failed to reset some performance settings.\n\nCheck the API error log under Maintenance."),
            })
        elseif any_changed then
            UIManager:show(InfoMessage:new{
                timeout = 3,
                text = _("Performance settings reset to Syncthing defaults."),
            })
        else
            UIManager:show(InfoMessage:new{
                timeout = 3,
                text = _("Performance settings are already on default values."),
            })
        end
    end)
end

-- Apply network access settings via the Syncthing REST API.
-- These are config.xml <options> fields - they cannot be passed as CLI flags
-- to `syncthing serve`. The only CLI-level knob is --no-upgrade (handled by
-- start-syncthing). Everything else lives here.
--
-- lan    -> disable all external connectivity; suitable for private networks
--          and devices with no internet access.
-- global -> enable global discovery, relays, NAT traversal and automatic
--          upgrades; needed for syncing across the internet.
local function applyNetworkSettings(self)
    if not self:isRunning() then return end

    UIManager:scheduleIn(1, function()
        local current = self:getOptions()
        if not current then
            logger.warn("[Syncthing] applyNetworkSettings: could not read config/options")
            return
        end

        local patch = {}
        local lan = (self.network_access ~= "global")

        -- Helper: adds a field in the patch only if it differs
        local function set(field, desired)
            if current[field] ~= desired then
                patch[field] = desired
            end
        end

        -- Network policies
        if lan then
            set("globalAnnounceEnabled",  false)
            set("relaysEnabled",          false)
            set("natEnabled",             false)
            set("urAccepted",             -1)
            set("crashReportingEnabled",  false)
            set("autoUpgradeIntervalH",   0)
        else
            set("globalAnnounceEnabled",  true)
            set("relaysEnabled",          true)
            set("natEnabled",             true)
            if (current["urAccepted"] or 0) < 0 then
                set("urAccepted", 0)
            end
            set("crashReportingEnabled",  true)
            set("autoUpgradeIntervalH",   12)
        end

        -- Resource global options.
        if self.resource_profile == "low" then
            set("maxConcurrentIncomingRequestKiB", 32768)
            set("maxFolderConcurrency", 1)
        else
            set("maxConcurrentIncomingRequestKiB", 262144)
            set("maxFolderConcurrency", 0)
        end

        if not next(patch) then
            logger.dbg("[Syncthing] applyNetworkSettings: already up to date")
            return
        end

        local result = self:patchOptions(patch)
        if U.isOk(result) then
            logger.info("[Syncthing] applyNetworkSettings: applied mode=" .. self.network_access)
        else
            local err = U.errOf(result)
            logger.warn("[Syncthing] applyNetworkSettings: PATCH config/options failed: " .. err)
        end
    end)
end

local function onToggleSyncthingServer(self, callback)
    local cb = type(callback) == "function" and callback or function() end
    if not binaryExists(self) then
        self:showFirstRunDialog(nil)
        return
    end
    if isRunning(self) then
        stop(self, cb)
    else
        NetworkMgr:runWhenOnline(function() start(self, cb) end)
    end
end

local function showFirstRunDialog(self, callback)
    UIManager:show(ConfirmBox:new{
        text = _(
            "Welcome to KOSyncthing+!\n\n" ..
            "The Syncthing binary is not yet installed. " ..
            "It will be downloaded once (around 10–15 MB) and stored in the plugin folder — " ..
            "Wi-Fi is required.\n\n" ..
            "After installation, Syncthing runs in the background and keeps your files in sync " ..
            "with other devices over your local network, without any cloud service.\n\n" ..
            "Tap Download to fetch it now."),
        ok_text     = _("Download"),
        cancel_text = _("Later"),
        ok_callback = function()
            if not U.cacertExists() then
                UIManager:show(InfoMessage:new{ icon = "notice-warning", text = U.NO_CACERT_MSG })
                if callback then callback() end
                return
            end
            NetworkMgr:runWhenOnline(function() self:checkForUpdates(callback, true) end)
        end,
        cancel_callback = function()
            if callback then callback() end
        end,
    })
end

local function stopPlugin(self)
    self._health_check_active = false
    if not isRunning(self) then return end
    local pid = getPid(self)
    if pid and isProcessSyncthing(pid) then
        os.execute(string.format("kill %d 2>/dev/null", pid))
        os.execute("sleep 0.5")
        os.execute(string.format("kill -0 %d 2>/dev/null && kill -9 %d 2>/dev/null", pid, pid))
    end
    os.remove(pid_path)
    self:_cacheInvalidate()
    logger.info("[Syncthing] stopPlugin: daemon stopped for plugin deletion.")
end

local function deletePluginSettings(self)
    -- Stop the periodic sync timer before wiping its settings
    self:_stopPeriodicSyncTimer()
	

    -- AD-19: capture the relocated database directory BEFORE the delete loop
    -- clears syncthing_data_dir, so we can purge it below (it lives outside
    -- settings/, e.g. /var/local, and would otherwise be orphaned).
    local relocated_data = G_reader_settings:readSetting("syncthing_data_dir")

    -- Single source of truth in U.ALL_SETTINGS_KEYS - keep this and
    -- st_reset._wipe in sync by editing the list there, not here.
    for _, key in ipairs(U.ALL_SETTINGS_KEYS) do
        G_reader_settings:delSetting(key)
    end

    local FS = require("st_filesystem")
    local all_ok = true

    -- Standard config directory.
    local settings_dir = path .. "/settings/syncthing"
    if util.pathExists(settings_dir) then
        local ok, err = FS.purge(settings_dir)
        if not ok then
            all_ok = false
            logger.warn("[Syncthing] deletePluginSettings: standard purge failed: "
                        .. tostring(err))
        end
    end

    -- Remove the obsolete second config directory left by older plugin
    -- releases.  pcall guards against read-only-filesystem errors on some
    -- Kindle models.  Both the pcall result and FS.purge return value are
    -- inspected so cleanup failures cannot be reported as success (AD-18).
    local obsolete_dir = path .. "/settings/syncthing-legacy"
    if util.pathExists(obsolete_dir) then
        local pcall_ok, purge_ok, purge_err = pcall(function()
            return FS.purge(obsolete_dir)
        end)
        if not pcall_ok then
            all_ok = false
            logger.warn("[Syncthing] deletePluginSettings: obsolete-dir purge raised an error: "
                        .. tostring(purge_ok))  -- purge_ok holds the error message here
        elseif not purge_ok then
            all_ok = false
            logger.warn("[Syncthing] deletePluginSettings: obsolete-dir purge failed: "
                        .. tostring(purge_err))
        end
    end

    -- AD-19: purge the relocated database directory if it lives outside
    -- settings/ (e.g. /var/local/kosyncthing_plus).  Guarded by pcall against
    -- read-only-filesystem errors, like the obsolete-directory purge above.
    if relocated_data and relocated_data ~= ""
            and not relocated_data:find("/settings/syncthing", 1, true) then
        local pcall_ok, purge_ok, purge_err = pcall(function()
            return FS.purge(relocated_data)
        end)
        if not pcall_ok then
            all_ok = false
            logger.warn("[Syncthing] deletePluginSettings: data-dir purge raised an error: "
                        .. tostring(purge_ok))
        elseif not purge_ok then
            all_ok = false
            logger.warn("[Syncthing] deletePluginSettings: data-dir purge failed: "
                        .. tostring(purge_err))
        end
    end

    self:_cacheInvalidate()
    if all_ok then
        logger.info("[Syncthing] deletePluginSettings: settings keys and directories removed.")
    else
        logger.warn("[Syncthing] deletePluginSettings: completed with errors - "
                    .. "some settings or directories may remain. See warnings above.")
    end
    return all_ok
end

return {
    binaryExists            = binaryExists,
    _invalidateBinaryCache  = invalidateBinaryCache,
    getBinaryArch           = getBinaryArch,
    binaryMatchesDevice     = binaryMatchesDevice,
    safeHomeDir             = safeHomeDir,
    getPid                  = getPid,
    isRunning               = isRunning,
    start                   = start,
    stop                    = stop,
    onToggleSyncthingServer = onToggleSyncthingServer,
    showFirstRunDialog      = showFirstRunDialog,
    stopPlugin              = stopPlugin,
    deletePluginSettings    = deletePluginSettings,
    applyPerformanceSettings = applyPerformanceSettings,
    applyNetworkSettings    = applyNetworkSettings,
	resetPerformanceSettings = resetPerformanceSettings,
}
