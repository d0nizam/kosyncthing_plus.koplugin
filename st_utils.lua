-- st_utils.lua – Shared constants, paths, shell helpers, network utilities, and the single‑source list of all settings keys
local DataStorage = require("datastorage")
local Device      = require("device")
local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local util        = require("util")
local logger      = require("logger")
local _           = require("syncthing_i18n").gettext

local datetime_ok, datetime = pcall(require, "datetime")

local path        = DataStorage:getFullDataDir()
local plugin_path = path .. "/plugins/kosyncthing_plus.koplugin/"
local cacert_path = plugin_path .. "cacert.pem"

local DANGEROUS_PATHS = {
    ["/"] = true, ["/mnt"] = true, ["/data"] = true,
    ["/system"] = true, ["/proc"] = true, ["/sys"] = true,
    ["/dev"] = true, ["/etc"] = true, [""] = true,
}

local NO_CACERT_MSG = _(
    "The SSL certificate bundle (cacert.pem) is missing from the plugin folder.\n\n" ..
    "This file is required for secure HTTPS downloads. " ..
    "Please reinstall KOSyncthing+ from scratch.")

local FOLDER_CACHE_TTL = 15

-- Session-only "Autostart paused" flag.  A manual Stop sets it so the
-- health-check timer, resume, network-connected and charging triggers do NOT
-- restart the daemon for the rest of THIS session — the desktop "I closed it
-- on purpose" model.  It deliberately lives in this module (required once and
-- shared by the FileManager and Reader plugin instances) rather than on the
-- plugin object, so it survives FileManager<->Reader navigation and suspend/
-- resume; and because it is plain Lua state, a KOReader restart reloads this
-- module and clears it, so Autostart starts the daemon again next launch.
local autostart_paused = false

local function setAutostartPaused(v)
    autostart_paused = v and true or false
end

local function isAutostartPaused()
    return autostart_paused
end


local function formatTime(iso_str)
    if not iso_str or iso_str == "" then return _("N/A") end
    if datetime_ok and datetime and datetime.stringISO8601ToSeconds then
        local seconds = datetime.stringISO8601ToSeconds(iso_str)
        if seconds and datetime.secondsToDateTime then
            return datetime.secondsToDateTime(seconds)
        end
    end
    -- Fallback: simple substring replacement
    return string.sub(iso_str, 1, 16):gsub("T", " ")
end

-- getDeviceIP() returns a printable IP for QR codes / GUI URL display.
-- We try IPv4 first because LAN setups overwhelmingly use IPv4 and the
-- resulting URL is shorter & easier to type into a browser by hand.  If
-- the device only has IPv6 (rare on consumer e-readers but real on some
-- IPv6-only networks), we fall back to the first IPv6 address printed by
-- Device:retrieveNetworkInfo().  As a last resort we return 127.0.0.1.
local function getDeviceIP()
    local info = Device.retrieveNetworkInfo and Device:retrieveNetworkInfo() or ""
    local v4 = info:match("IP: (%d+%.%d+%.%d+%.%d+)")
    if v4 then return v4 end
    -- IPv6 addresses contain colons and hex digits.  We only accept
    -- something that looks like at least two hex groups separated by a
    -- colon, which rules out accidental matches on log lines containing
    -- "IP: x" without an actual address.
    local v6 = info:match("IP[v6]*:%s*([%x:]+:[%x:]+)")
    if v6 and v6:find(":", 1, true) then return v6 end
    return "127.0.0.1"
end

local function shellEscape(s)
    if not s then return "" end
    return tostring(s):gsub("'", "'\\''")
end

-- Strip Syncthing's conflict infix from a basename or path, yielding the
-- ORIGINAL name.  Syncthing inserts "<sep>sync-conflict-YYYYMMDD-HHMMSS-<DEV>"
-- before the final extension, where <sep> is "." or "~".  Handles both forms.
--   mybook.sync-conflict-20260614-120000-ABCDEFG.epub -> mybook.epub
--   state~sync-conflict-20260614-120000-ABCDEFG.lua   -> state.lua
local function stripConflictInfix(name)
    if type(name) ~= "string" then return name end
    return (name:gsub("[.~]sync%-conflict%-[%d%-]+%-[%dA-Z]+(%.?[^/]*)$", "%1"))
end

-- True if `name` looks like a Syncthing conflict copy ("<sep>sync-conflict-…",
-- where <sep> is "." or "~").  Single source for the "is this a conflict
-- basename?" gate shared by both conflict scanners and matchesConflictBasename
-- (so the gate cannot drift looser than the scanners that feed it).
local function isConflictBasename(name)
    return type(name) == "string" and name:find("[.~]sync%-conflict%-") ~= nil
end

-- Translate a shell `-name` glob into an anchored Lua pattern that matches a
-- *basename*.  Mirrors `find -name`: `*` -> any run, `?` -> one char,
-- everything else literal (Lua magic characters escaped).
-- globToLuaPattern is a pure function of `glob`, so a glob always compiles to
-- the same Lua pattern; the memo (over the small, validated set of registered
-- globs) needs no invalidation.  Avoids recompiling identical patterns once per
-- conflict file during a scan.
local _glob_pattern_cache = {}
local function globToLuaPattern(glob)
    local cached = _glob_pattern_cache[glob]
    if cached then return cached end
    local out, i = { "^" }, 1
    while i <= #glob do
        local c = glob:sub(i, i)
        if c == "*" then
            out[#out + 1] = ".*"
        elseif c == "?" then
            out[#out + 1] = "."
        elseif c:match("[%^%$%(%)%.%%%[%]%*%+%-%?]") then
            out[#out + 1] = "%" .. c
        else
            out[#out + 1] = c
        end
        i = i + 1
    end
    out[#out + 1] = "$"
    local pattern = table.concat(out)
    _glob_pattern_cache[glob] = pattern
    return pattern
end

-- Detect the userspace architecture for Syncthing release assets.
-- LuaJIT reports the ABI KOReader itself is running under, which is the
-- safest first choice on newer devices whose kernel uname can be unusual.
local function detectArch()
    local ok, jit = pcall(require, "jit")
    if ok and type(jit) == "table" and type(jit.arch) == "string" then
        local arch = jit.arch:lower()
        if arch == "arm64" or arch == "arm64be" then
            return "arm64", false, arch .. " (LuaJIT)"
        elseif arch == "x64" then
            return "amd64", false, arch .. " (LuaJIT)"
        elseif arch == "x86" then
            return "386", false, arch .. " (LuaJIT)"
        elseif arch == "arm" or arch == "armbe" then
            return "arm", false, arch .. " (LuaJIT)"
        end
    end

    local p = io.popen("uname -m 2>/dev/null")
    if not p then return "arm", true, "unknown" end
    local m = p:read("*l")
    p:close()
    if not m then return "arm", true, "unknown" end
    m = tostring(m):gsub("^%s+", ""):gsub("%s+$", "")
    if m == "" then return "arm", true, "unknown" end
    if m == "aarch64" or m == "arm64" then return "arm64", false, m end
    if m == "x86_64"                  then return "amd64", false, m end
    if m:match("^i[3-6]86$")          then return "386",   false, m end
    return "arm", m:match("^armv%d") == nil, m
end



local function isValidDeviceID(s)
    if type(s) ~= "string" then return false end
    local stripped = s:gsub("%-", "")
    return #stripped == 56 and stripped:match("^[A-Z2-7]+$") ~= nil
end

local function copyToClipboard(text)
    if Device.input and Device.input.setClipboardText then
        Device.input.setClipboardText(text)
        UIManager:show(InfoMessage:new{ timeout = 2, text = _("Copied to clipboard.") })
    else
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Clipboard not supported on this device."),
        })
    end
end

local function execOk(ret)
    return ret == 0 or ret == true
end

local ELF_MAGIC = string.char(0x7f) .. "ELF"
local GZIP_MAGIC = string.char(0x1f, 0x8b)
local ZIP_MAGIC = "PK" .. string.char(0x03, 0x04)

local function fileHasPrefix(path, prefix)
    local f = io.open(path, "rb")
    if not f then return false end
    local head = f:read(#prefix)
    f:close()
    return head == prefix
end

local function isELF(path)
    return fileHasPrefix(path, ELF_MAGIC)
end

local function isGzip(path)
    return fileHasPrefix(path, GZIP_MAGIC)
end

local function isZip(path)
    return fileHasPrefix(path, ZIP_MAGIC)
end

local function fileSize(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end")
    f:close()
    return size
end

local _loopback_checked = nil
local function loopbackIsUp()
    if _loopback_checked ~= nil then return _loopback_checked end
    local p = io.popen("ip link show lo 2>/dev/null")
    if not p then _loopback_checked = false; return false end
    local out = p:read("*a"); p:close()
    _loopback_checked = out and out:find("UP") ~= nil
    return _loopback_checked
end

-- Loopback state can change between sessions (e.g. user reboots, or some
-- other tool brings `lo` down).  This invalidator lets the caller drop the
-- sticky cache before re-probing — `start` in st_process.lua now calls it
-- so we re-check on every start attempt.
local function invalidateLoopbackCache()
    _loopback_checked = nil
end

local function kindleOpenPort(port)
    local rule = string.format("INPUT -p tcp --dport %s -j ACCEPT", port)
    if not execOk(os.execute("iptables -C " .. rule .. " 2>/dev/null")) then
        os.execute("iptables -A " .. rule .. " 2>/dev/null")
    end
end

local function kindleClosePort(port)
    local max_attempts = 10
    while max_attempts > 0 and execOk(os.execute(string.format(
        "iptables -D INPUT -p tcp --dport %s -j ACCEPT 2>/dev/null", port))) do
        max_attempts = max_attempts - 1
    end
end

local function kindleOpenPortUDP(port)
    local rule = string.format("INPUT -p udp --dport %s -j ACCEPT", port)
    if not execOk(os.execute("iptables -C " .. rule .. " 2>/dev/null")) then
        os.execute("iptables -A " .. rule .. " 2>/dev/null")
    end
end

local function kindleClosePortUDP(port)
    local max_attempts = 10
    while max_attempts > 0 and execOk(os.execute(string.format(
        "iptables -D INPUT -p udp --dport %s -j ACCEPT 2>/dev/null", port))) do
        max_attempts = max_attempts - 1
    end
end

local _curl_ok = nil
local function curlAvailable()
    if _curl_ok ~= nil then return _curl_ok end
    local p = io.popen("curl --version 2>/dev/null")
    if p then
        p:read("*a")
        local ok = p:close()
        _curl_ok = (ok == true or ok == 0)
    else
        _curl_ok = false
    end
    return _curl_ok
end

-- curl availability shouldn't normally change at runtime but a factory
-- reset is the right moment to drop the assumption.
local function invalidateCurlCache()
    _curl_ok = nil
end

-- Single source of truth for ALL G_reader_settings keys this plugin owns.
-- Used by st_reset._wipe (factory reset) and st_process.deletePluginSettings
-- (plugin removal) so the two paths stay in sync.  Adding a new setting
-- means adding it here once.
local ALL_SETTINGS_KEYS = {
    "syncthing_port",
    "syncthing_gui_user",
    "syncthing_gui_password",
    "syncthing_auto_start_charging",
    "syncthing_auto_start_always",
    "syncthing_autostart_mode",
    "syncthing_password_dialog_seen",
    "syncthing_conflict_cache_ttl",
    "syncthing_notifications_enabled",
    "syncthing_resource_profile",
    "syncthing_network_access",
    "syncthing_settings_version",
    "syncthing_periodic_sync_enabled",
    "syncthing_periodic_sync_interval_min",
    "syncthing_was_running",
    "syncthing_arch_warning_shown",
    "syncthing_password_configured",
    "syncthing_password_skip_at",
    -- Deprecated: no longer written or read.  Kept here only so a factory
    -- reset still clears any value left by an older version.
    "syncthing_start_failed",
    -- Database relocation (AD-19): where the SQLite DB lives when /mnt/us is a
    -- hard_remove FUSE mount, plus the one-time "first scan" notice flag.  Both
    -- are cleared by factory reset so a fresh DB re-resolves and re-notifies.
    "syncthing_data_dir",
    "syncthing_data_notice_seen",
    -- Obsolete mode-selection keys.  Kept only so factory reset and plugin
    -- removal clean values left by older plugin versions.
    "syncthing_use_legacy",
    "syncthing_legacy_version",
    "syncthing_legacy_installed_version",
    "syncthing_legacy_hint_seen",
    -- Android remote-mode keys (written by st_android): the API key, port and
    -- the discovered scheme (http/https) used to reach the Syncthing app.
    "syncthing_android_apikey",
    "syncthing_android_port",
    "syncthing_android_scheme",
    -- Opt-in auto-merge after Quick Sync completes.
    "syncthing_auto_merge_conflicts",
}

local function cacertExists()
    return util.pathExists(cacert_path)
end

-- Sets or clears GUI user/password in Syncthing's config.xml.
-- When `password` is nil or empty, any existing <user> and <password> tags
-- are removed, effectively disabling GUI authentication.
-- When `password` is provided, `syncthing generate` is called to hash
-- the password and update the config (requires --data flag).
-- setGUIPassword(password, config_dir, gui_user)
-- Sets or removes the Syncthing Web GUI password by editing config.xml.
--
-- Returns true on success, or (false, error_message) on failure.  Callers
-- should check the return value and surface the error to the user — earlier
-- versions silently swallowed every failure mode, leaving the user thinking
-- their password was saved when in fact it wasn't.
local function setGUIPassword(password, config_dir, gui_user)
    if not config_dir then return false, "no config directory provided" end
    local user = gui_user or "syncthing"
    local binary = plugin_path .. "syncthing"
    if not util.pathExists(binary) then
        logger.warn("[Syncthing] Cannot set password: no Syncthing binary found")
        return false, "Syncthing binary not found in plugin folder"
    end

    if not util.pathExists(config_dir) then
        util.makePath(config_dir)
        if not util.pathExists(config_dir) then
            logger.warn("[Syncthing] Could not create config directory: " .. config_dir)
            return false, "Could not create config directory"
        end
    end

    local config_xml = config_dir .. "/config.xml"
    local FS = require("st_filesystem")

    if password and password ~= "" then
        -- Set / update the password using `syncthing generate`.  This
        -- creates config.xml if it doesn't exist, or rewrites the
        -- <user>/<password> entries if it does.
        local cmd = string.format(
            "'%s' generate --data='%s' --config='%s' --gui-user='%s' --gui-password='%s' 2>&1",
            shellEscape(binary),
            shellEscape(config_dir),
            shellEscape(config_dir),
            shellEscape(user),
            shellEscape(password))
		local f = io.popen(cmd)
		local output = "(no output)"
		local cmd_ok = false
		if f then
			output = f:read("*a") or output
			-- f:close() returns ok, exit_type, exit_code
			local ok_close, _, exit_code = f:close()
			cmd_ok = (ok_close == true) or (exit_code == 0)
		end
		-- Fail if command failed OR config.xml is still missing
		if not cmd_ok or not util.pathExists(config_xml) then
			logger.warn("[Syncthing] setGUIPassword failed; output: " .. output)
			return false, "Failed to write config.xml: " .. output:sub(1, 200)
		end
		return true
    else
        -- Remove the password by stripping <user>/<password> elements
        -- from config.xml.  Read, transform, write back, and verify the
        -- write succeeded.
        if not util.pathExists(config_xml) then
            -- Nothing to do — there was no config to remove a password
            -- from.  This is a successful no-op.
            return true
        end
        local f = io.open(config_xml, "r")
        if not f then return false, "Could not open config.xml for reading" end
        local content = f:read("*a")
        f:close()
        if not content then return false, "config.xml was empty or unreadable" end

        content = content:gsub("%s*<user>[^<]*</user>%s*", "")
        content = content:gsub("%s*<password>[^<]*</password>%s*", "")

        local ok, err = FS.write(config_xml, content)
        if not ok then
            return false, "Failed to write config.xml: " .. tostring(err)
        end
        return true
    end
end

---------------------------------------------------------------------------
-- getFreeSpace(path)
--
-- Returns the number of free bytes on the filesystem containing `path`,
-- or nil if it cannot be determined.  Used to warn the user before a
-- Quick Sync would fill up the device — Syncthing has no built-in space
-- check and will happily fill a Kindle to zero free bytes.
--
-- Implementation: shell out to `df`.  We try a few invocations:
--
--   1. `df -k -P '<path>'`  — POSIX-conformant, single-line per mount.
--      Available on busybox >= 1.13 and on GNU coreutils.  This is the
--      preferred form because the column layout is guaranteed.
--   2. `df -k '<path>'`     — fallback for any df that doesn't recognise
--      -P (very old busybox, or stripped builds).  Output may wrap onto
--      two lines if the device path is long; we handle that case.
--
-- If both fail or the output is unparseable, returns nil.  Callers must
-- handle nil gracefully — typically by skipping the disk-space check
-- rather than blocking the user.
---------------------------------------------------------------------------
local function _parseDfOutput(content, available_col)
    -- Parse df output.  available_col is the 1-based column index where
    -- the "Available" KB count lives — 4 for the standard 6-column
    -- layout (Filesystem 1K-blocks Used Available Use% Mounted-on).
    --
    -- Some df versions wrap long device paths onto a separate header
    -- line: "/dev/some/very/long/path\n   123456  78901  3456  ..."
    -- so we collect ALL numeric tokens from data lines and look for a
    -- row that has at least available_col numbers.
    local lines = {}
    for line in content:gmatch("[^\n]+") do table.insert(lines, line) end
    if #lines < 2 then return nil end

    -- Skip the header.  Try every subsequent line; collect leading
    -- numeric tokens.  When the first token is non-numeric (a device
    -- path), skip it; when it is numeric (continuation line), include it.
    for i = 2, #lines do
        local tokens = {}
        for tok in lines[i]:gmatch("%S+") do table.insert(tokens, tok) end

        -- If the line has fewer columns than expected and the next line
        -- exists, try to merge (handles wrapping).
        if #tokens < available_col and i < #lines then
            for tok in lines[i + 1]:gmatch("%S+") do
                table.insert(tokens, tok)
            end
        end

        -- Find the first run of numeric tokens; "Available" is the third
        -- numeric value (1K-blocks, Used, Available).
        local nums = {}
        for _, t in ipairs(tokens) do
            local n = tonumber(t)
            if n then table.insert(nums, n) end
        end
        if #nums >= 3 then
            -- nums[3] is Available KB.
            return nums[3]
        end
    end
    return nil
end

local function getFreeSpace(path)
    if not path or path == "" then return nil end

    -- Primary attempt: -k -P (POSIX-portable, single-line guaranteed).
    local f = io.popen(string.format(
        "df -k -P '%s' 2>/dev/null", shellEscape(path)))
    if f then
        local content = f:read("*a") or ""
        f:close()
        if content ~= "" then
            local kb = _parseDfOutput(content, 4)
            if kb then return kb * 1024 end
        end
    end

    -- Fallback: -k alone, in case the df on this device doesn't accept -P
    -- (very old busybox builds).  Same column layout in practice.
    f = io.popen(string.format(
        "df -k '%s' 2>/dev/null", shellEscape(path)))
    if f then
        local content = f:read("*a") or ""
        f:close()
        if content ~= "" then
            local kb = _parseDfOutput(content, 4)
            if kb then return kb * 1024 end
        end
    end

    return nil
end

-- getMountPoint returns the mount point of a path by parsing df output.
-- Returns the mount point string or nil on failure.
local function getMountPoint(path)
    if not path or path == "" then return nil end
    local f = io.popen(string.format(
        "df -k -P '%s' 2>/dev/null | awk 'NR>1 {print $NF}'", shellEscape(path)))
    if not f then return nil end
    local mp = f:read("*l")
    f:close()
    if mp and mp ~= "" then return mp end
    return nil
end

local function formatBytes(b)
    if not b or b == 0 then return "0 B" end
    local units = { "B", "KB", "MB", "GB", "TB" }
    local i = 1
    while b >= 1024 and i < #units do
        b = b / 1024
        i = i + 1
    end
    if i == 1 then
        return string.format("%d B", b)
    end
    return string.format("%.1f %s", b, units[i])
end

---------------------------------------------------------------------------
-- API result helpers
--
-- SafeClient always returns a table {ok=bool, error="...", data=...}.
-- A bare `if result then` is always true (tables are truthy), so every
-- caller that needs to distinguish success from failure MUST read
-- result.ok.  These two helpers make that contract explicit and also
-- handle the nil case (e.g. when a caller forgets `or {}` on a read).
---------------------------------------------------------------------------

--- Returns true only when `r` is a SafeClient result table with ok==true.
--- Nil-safe: `isOk(nil)` returns false instead of erroring.
local function isOk(r)
    return r ~= nil and r.ok == true
end

--- Returns the error string from a SafeClient result, or "no response"
--- when the result is nil or carries no error field.
local function errOf(r)
    return (r and r.error) or "no response"
end

---------------------------------------------------------------------------
-- Config directory (named local so getDataDir and the public table share
-- one definition instead of duplicating the path computation).
--
---------------------------------------------------------------------------
local function getConfigDir()
    return DataStorage:getFullDataDir() .. "/settings/syncthing"
end

---------------------------------------------------------------------------
-- Data-directory resolution (AD-19).
--
-- Syncthing 2.x keeps its SQLite database in the --data directory.  On
-- Kindle, /mnt/us is a FUSE mount (fuse.fsp) commonly mounted with the
-- hard_remove option: an unlinked-but-open file is deleted immediately and
-- every subsequent write/fsync on that descriptor returns ENOENT.  SQLite's
-- WAL and DELETE-ON-CLOSE temp files use exactly the unlink-then-write
-- pattern, so the database cannot live there — every index update fails with
-- "disk I/O error: no such file or directory" (upstream issue jasonchoimtt
-- /koreader-syncthing#48; reproduced on a Paperwhite 12th-gen).
--
-- Detection is BEHAVIOURAL, not by mount options: hard_remove is a libfuse
-- userspace flag that does NOT appear in /proc/mounts (confirmed on the
-- affected device, whose mount line is indistinguishable from a safe one).
-- Probing the actual unlink-then-write behaviour is filesystem- and
-- model-agnostic and future-proof.
---------------------------------------------------------------------------

-- unlinkWriteBroken(dir): true when "open fd, unlink, write" fails in `dir`.
-- setvbuf("no") forces the write() syscall immediately rather than letting it
-- sit in stdio's buffer, so the failure surfaces on the write itself.
local function unlinkWriteBroken(dir)
    if not dir or dir == "" then return false end
    local tmp = string.format("%s/.st_hr_probe.%d", dir, os.time())
    local f = io.open(tmp, "w")
    if not f then return false end          -- cannot create here: not THIS failure
    f:setvbuf("no")
    os.remove(tmp)                          -- unlink while the handle is open
    local wok = f:write("probe")
    local fok = f:flush()
    f:close()
    os.remove(tmp)                          -- cleanup if it somehow survived
    return not (wok and fok)
end

-- _ensureWritableDir(path): create `path` if missing and confirm it is
-- writable.  Also the survives-firmware-update check: if a previously chosen
-- directory was wiped, this re-creates it; if the mount itself is gone, it
-- returns false and the caller recomputes.
local function _ensureWritableDir(path)
    if not path or path == "" then return false end
    if not util.pathExists(path) then util.makePath(path) end
    if not util.pathExists(path) then return false end
    local probe = path .. "/.st_w_probe"
    local f = io.open(probe, "w")
    if not f then return false end
    f:close(); os.remove(probe)
    return true
end

-- _platformDataCandidates(): persistent, non-FUSE database locations for THIS
-- platform, in preference order.  Only Kindle has a known-safe ext partition
-- (/var/local).  Kobo and PocketBook use directly-mounted VFAT for user
-- storage (NOT affected by hard_remove), and their only ext partition is the
-- system rootfs (small, overwritten by firmware updates) — so no candidate is
-- offered there and such devices stay on the config directory.
local function _platformDataCandidates()
    if Device and Device.isKindle and Device:isKindle() then
        return { "/var/local/kosyncthing_plus" }
    end
    return {}
end

-- Tier thresholds (bytes).  A real KOReader index rarely exceeds tens of MB.
local DATA_DIR_COMFORT = 80 * 1024 * 1024   -- prefer a candidate with >= this
local DATA_DIR_MINIMUM = 20 * 1024 * 1024   -- refuse a candidate below this

-- resolveDataDir(config_dir, opts) -> data_dir, reason, note
-- opts (all optional; used by tests): sticky, candidates,
--   comfort_bytes, min_bytes, probe, free_space.  In production these derive
--   from settings/Device and the real probe; tests inject probe/free_space to
--   exercise the broken-filesystem path without a real FUSE mount.
local function resolveDataDir(config_dir, opts)
    opts = opts or {}
    local comfort   = opts.comfort_bytes or DATA_DIR_COMFORT
    local minimum   = opts.min_bytes     or DATA_DIR_MINIMUM
    local probe     = opts.probe         or unlinkWriteBroken
    local freespace = opts.free_space    or getFreeSpace

    -- Sticky / manual override: a previously chosen (or user-set) directory,
    -- reused only if it still exists, is writable, AND is not itself broken.
    local sticky = opts.sticky
    if sticky == nil then sticky = G_reader_settings:readSetting("syncthing_data_dir") end
    if sticky and sticky ~= "" and sticky ~= config_dir then
        if _ensureWritableDir(sticky) and not probe(sticky) then
            return sticky, "sticky", nil
        end
    end

    -- Probe where the database would actually live.
    if not probe(config_dir) then
        return config_dir, "clean", nil
    end

    -- Broken: walk candidates in preference order.  Aggressive — take the
    -- first safe candidate with >= minimum, even if below comfort (with note).
    local candidates = opts.candidates or _platformDataCandidates()
    for _, cand in ipairs(candidates) do
        local parent = cand:match("^(.+)/[^/]+$") or cand
        if util.pathExists(parent) or _ensureWritableDir(parent) then
            local free = freespace(parent)
            local safe = _ensureWritableDir(parent) and not probe(parent)
            if safe and free then
                if free >= comfort then
                    _ensureWritableDir(cand)
                    return cand, "redirected", nil
                elseif free >= minimum then
                    _ensureWritableDir(cand)
                    return cand, "redirected_tight",
                        string.format("low space on %s (%d MB free)",
                                      parent, math.floor(free / 1048576))
                end
            end
        end
    end

    -- Nothing better — stay put; the caller surfaces a visible warning.
    return config_dir, "fallback_warn", nil
end

-- Session cache so the probe runs at most once per run.
local _data_dir_cache, _data_dir_reason, _data_dir_note
local function invalidateDataDirCache()
    _data_dir_cache, _data_dir_reason, _data_dir_note = nil, nil, nil
end

-- True when a folder scan/pull error is the transient, rescan-fixable kind.
-- Syncthing reports these as "… changed during hashing" / "changed during scan"
-- when a file is still being written while Syncthing reads it; a rescan retries.
-- Permission / no-space / folder-marker / I/O errors do NOT match: a rescan
-- will not clear them, so the UI must not promise a "fix" for those.
local function isTransientFolderError(msg)
    return tostring(msg):lower():find("changed during", 1, true) ~= nil
end

-- classifyFolderError — map a Syncthing folder/pull error string to a coarse
-- category so the UI can show a plain-language explanation tailored to the kind
-- of problem.  Substring match on the lowercased message (Syncthing's wording
-- is stable English).  Categories:
--   "ignored"    — a remote deletion is blocked by ignored files in the dir
--                  (".. contains ignored files (?d) ..", or "directory not empty")
--   "transient"  — "changed during ..." — a rescan clears it (no Explain button)
--   "nospace"    — out of disk space
--   "permission" — cannot write (read-only / permission denied)
--   "missing"    — folder path or .stfolder marker is gone
--   "other"      — anything else; the Explain text shows the raw message
local function classifyFolderError(msg)
    local m = tostring(msg):lower()
    if m:find("ignored files", 1, true) or m:find("(?d)", 1, true)
       or m:find("not empty", 1, true) then
        return "ignored"
    end
    if m:find("changed during", 1, true) then return "transient" end
    if m:find("no space", 1, true) or m:find("space left", 1, true) then
        return "nospace"
    end
    if m:find("permission denied", 1, true) or m:find("read-only", 1, true)
       or m:find("read only", 1, true) or m:find("access is denied", 1, true) then
        return "permission"
    end
    if m:find("no such file", 1, true) or m:find("folder marker", 1, true)
       or m:find(".stfolder", 1, true) or m:find("cannot find", 1, true)
       or m:find("does not exist", 1, true) then
        return "missing"
    end
    return "other"
end

return {
    isTransientFolderError    = isTransientFolderError,
    classifyFolderError       = classifyFolderError,
    formatBytes               = formatBytes,
    formatTime                = formatTime,
    getDeviceIP               = getDeviceIP,
    getFreeSpace              = getFreeSpace,
	getMountPoint			  = getMountPoint,
    shellEscape               = shellEscape,
    stripConflictInfix        = stripConflictInfix,
    isConflictBasename        = isConflictBasename,
    globToLuaPattern          = globToLuaPattern,
    detectArch                = detectArch,
    isValidDeviceID           = isValidDeviceID,
    copyToClipboard           = copyToClipboard,
    execOk                    = execOk,
    isELF                     = isELF,
    isGzip                    = isGzip,
    isZip                     = isZip,
    fileSize                  = fileSize,
    loopbackIsUp              = loopbackIsUp,
    invalidateLoopbackCache   = invalidateLoopbackCache,
    kindleOpenPort            = kindleOpenPort,
    kindleClosePort           = kindleClosePort,
    kindleOpenPortUDP         = kindleOpenPortUDP,
    kindleClosePortUDP        = kindleClosePortUDP,
    curlAvailable             = curlAvailable,
    invalidateCurlCache       = invalidateCurlCache,
    cacertExists              = cacertExists,
    setGUIPassword            = setGUIPassword,
    DANGEROUS_PATHS           = DANGEROUS_PATHS,
    NO_CACERT_MSG             = NO_CACERT_MSG,
    FOLDER_CACHE_TTL          = FOLDER_CACHE_TTL,
    setAutostartPaused        = setAutostartPaused,
    isAutostartPaused         = isAutostartPaused,
    ALL_SETTINGS_KEYS         = ALL_SETTINGS_KEYS,
    plugin_path               = plugin_path,
    cacert_path               = cacert_path,
    isOk                      = isOk,
    errOf                     = errOf,

    getBinaryPath = function()
        return plugin_path .. "syncthing"
    end,

    -- Extract just the Syncthing executable from a release tarball, straight to
    -- `dest`.  Returns true, or false plus a reason.
    --
    -- The selection is by archive path on purpose.  A release archive contains
    -- THREE entries named `syncthing`: the ELF executable at the archive root,
    -- plus helper scripts under etc/freebsd-rc/ and etc/firewall-ufw/.  Any
    -- approach that unpacks the whole tree and then searches the filesystem for
    -- the name has to break the tie by directory order, which is filesystem
    -- dependent, or by depth, which depends on whether the extractor stripped
    -- the archive's top-level directory.  Both produced installs of a shell
    -- script that was then rejected as "not a valid Linux binary".  Matching the
    -- entry inside the archive is unambiguous: the executable is the only
    -- `syncthing` entry with exactly one path component ahead of it, and that
    -- holds regardless of the order entries appear in.
    --
    -- `entry.size` is the fallback if a future archive ever changes that shape:
    -- the executable is ~25 MB, the helper scripts under 2 KB.
    --
    -- The caller must ensure the parent directory of `dest` exists.
    extractBinaryFromArchive = function(archive, dest)
        local ok_mod, Archiver = pcall(require, "ffi/archiver")
        if not ok_mod or type(Archiver) ~= "table" or not Archiver.Reader then
            return false, "archiver unavailable"
        end
        local arc = Archiver.Reader:new()
        if not arc:open(archive) then
            arc:close()
            return false, "cannot open archive"
        end

        local exact, biggest, biggest_size
        for entry in arc:iterate() do
            if entry.mode == "file" and entry.path:match("/syncthing$") then
                if entry.path:match("^[^/]+/syncthing$") then
                    exact = entry.path
                    break
                end
                local size = tonumber(entry.size) or 0
                if not biggest_size or size > biggest_size then
                    biggest, biggest_size = entry.path, size
                end
            end
        end

        local key = exact or biggest
        if not key then
            arc:close()
            return false, "no syncthing entry in archive"
        end

        local ok = arc:extractToPath(key, dest)
        local err = arc.err
        arc:close()
        if not ok then
            return false, tostring(err or "extraction failed")
        end
        return true
    end,

    -- Single source of truth for the config directory (see the named local
    -- above).  Used by st_api, st_process, st_settings, and main.
    getConfigDir = getConfigDir,

    -- Behavioural probe and resolver, exported for the test suite.
    unlinkWriteBroken      = unlinkWriteBroken,
    resolveDataDir         = resolveDataDir,
    invalidateDataDirCache = invalidateDataDirCache,

    -- getDataDir(): the active Syncthing DATABASE directory, mirroring
    -- getConfigDir().  On an affected Kindle (standard 2.x binary) it relocates
    -- the database off the hard_remove FUSE mount to a persistent ext partition;
    -- everywhere else it equals the config directory.  Resolved once per session
    -- and the choice persisted in syncthing_data_dir so it is stable across
    -- restarts.  Returns: dir, reason, note.
    --   reason ∈ { sticky, clean, redirected, redirected_tight, fallback_warn }
    getDataDir = function()
        if _data_dir_cache then
            return _data_dir_cache, _data_dir_reason, _data_dir_note
        end
        local config_dir = getConfigDir()
        local dir, reason, note = resolveDataDir(config_dir)
        if (reason == "redirected" or reason == "redirected_tight")
                and dir ~= config_dir then
            G_reader_settings:saveSetting("syncthing_data_dir", dir)
        end
        _data_dir_cache, _data_dir_reason, _data_dir_note = dir, reason, note
        return dir, reason, note
    end,
	
	-- Unpack an archive, with fallback for KOReader builds that removed
    -- Device:unpackArchive (koreader@751b497).
    unpackArchive = function(archive, extract_to, strip_root)
        if Device.unpackArchive then
            return Device:unpackArchive(archive, extract_to, strip_root)
        end
        local Archiver = require("ffi/archiver")
        local arc = Archiver.Reader:new()
        local ok = arc:open(archive)
        if ok then
            for entry in arc:iterate() do
                local dest_path = entry.path
                if strip_root then
                    local _, tail = dest_path:match("([^/]*)/*(.*)")
                    if tail then
                        dest_path = tail
                    elseif entry.mode == 'directory' then
                        goto continue
                    end
                end
                if not arc:extractToPath(entry.path, extract_to .. "/" .. dest_path) then
                    break
                end
                ::continue::
            end
            ok = not arc.err
        end
        if ok then
            pcall(os.remove, archive)
        end
        arc:close()
        if not ok then
            return false, tostring(arc.err or "unknown error")
        end
        return true
    end,
}
