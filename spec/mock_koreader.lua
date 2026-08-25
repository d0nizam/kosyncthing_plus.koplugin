local Mock = {}

local function identity(...)
    return ...
end

local function template(fmt, ...)
    local args = { ... }
    return (tostring(fmt):gsub("%%(%d+)", function(i)
        return tostring(args[tonumber(i)] or "")
    end))
end

function Mock.reset()
    if package.loaded.st_guard and package.loaded.st_guard.releaseAll then
        package.loaded.st_guard:releaseAll()
    end

    Mock.state = {
        now = 0,
        timers = {},
        shown = {},
        closed = {},
        broadcasts = {},
        notifications = {},
        logs = {},
        settings = {},
        path_exists = {},
        free_space = {},
        mount_points = {},
        standby = 0,
        wakelock = 0,
        wifi_online = true,
        wifi_connected = nil,  -- nil = follow wifi_online; true/false = independent LAN state
        wifi_enable_calls = 0,
        wifi_disable_calls = 0,
        wifi_auto_callback = true,
    }

    for _, name in ipairs({
        "st_guard",
        "st_sync",
        "st_conflict",
        "st_orchestrator",
        "st_api_public",
        "st_filesystem",
    }) do
        package.loaded[name] = nil
    end
end

function Mock.install()
    Mock.reset()

    -- KOReader runs on LuaJIT which exports `unpack` as a global.
    -- Lua 5.4 moved it to table.unpack; restore the alias so plugin code works.
    _G.unpack = _G.unpack or table.unpack

    package.preload["rapidjson"] = nil  -- force fallback to json

    -- st_api_public.lua does: pcall(require, "rapidjson") then require("json").
    -- Stub both so the timer spec does not need a system-wide lua-json install.
    package.preload["json"] = function()
        return {
            decode = function(s)
                -- minimal: return empty table for any input
                if type(s) ~= "string" or s == "" then return nil end
                return {}
            end,
            encode = function() return "{}" end,
        }
    end

    package.preload["logger"] = function()
        local logger = {}
        for _, level in ipairs({ "dbg", "info", "warn", "err" }) do
            logger[level] = function(...)
                table.insert(Mock.state.logs, { level = level, args = { ... } })
            end
        end
        return logger
    end

    package.preload["syncthing_i18n"] = function()
        return {
            gettext = identity,
            ngettext = function(singular, plural, n)
                return (n == 1) and singular or plural
            end,
        }
    end

    package.preload["gettext"] = function()
        return identity
    end

    package.preload["ffi/util"] = function()
        return {
            template = template,
            purgeDir = function() end,
        }
    end

    package.preload["ui/time"] = function()
        return {
            now = function() return Mock.state.now end,
            to_s = function(v) return v end,
        }
    end

    package.preload["ui/event"] = function()
        local Event = {}
        function Event:new(name, data)
            return { name = name, data = data }
        end
        return Event
    end

    package.preload["ui/uimanager"] = function()
        local UIManager = {}

        function UIManager:preventStandby()
            Mock.state.standby = Mock.state.standby + 1
        end

        function UIManager:allowStandby()
            Mock.state.standby = Mock.state.standby - 1
        end

        function UIManager:scheduleIn(delay, fn)
            table.insert(Mock.state.timers, { delay = delay or 0, fn = fn, cancelled = false })
        end

        function UIManager:nextTick(fn)
            self:scheduleIn(0, fn)
        end

        function UIManager:unschedule(fn)
            for _, timer in ipairs(Mock.state.timers) do
                if timer.fn == fn then
                    timer.cancelled = true
                end
            end
        end

        function UIManager:show(widget)
            table.insert(Mock.state.shown, widget)
        end

        function UIManager:close(widget)
            table.insert(Mock.state.closed, widget)
        end

        function UIManager:broadcastEvent(event)
            table.insert(Mock.state.broadcasts, event)
        end

        return UIManager
    end

    local function widget(name)
        return {
            new = function(_, o)
                o = o or {}
                o._widget = name
                return o
            end,
        }
    end

    for _, module in ipairs({
        "ui/widget/infomessage",
        "ui/widget/confirmbox",
        "ui/widget/inputdialog",
        "ui/widget/multiinputdialog",
        "ui/widget/textviewer",
        "ui/widget/buttondialog",
        "ui/widget/qrmessage",
        "ui/widget/notification",
    }) do
        package.preload[module] = function()
            return widget(module)
        end
    end

    package.preload["ui/network/manager"] = function()
        return {
            isOnline = function()
                return Mock.state.wifi_online
            end,
            isConnected = function()
                return Mock.state.wifi_connected ~= nil
                    and Mock.state.wifi_connected
                    or  Mock.state.wifi_online
            end,
            enableWifi = function(_, cb)
                Mock.state.wifi_enable_calls = Mock.state.wifi_enable_calls + 1
                Mock.state.wifi_online = true
                if cb and Mock.state.wifi_auto_callback then cb() end
            end,
            disableWifi = function()
                Mock.state.wifi_disable_calls = Mock.state.wifi_disable_calls + 1
                Mock.state.wifi_online = false
            end,
            beforeWifiAction = function(_, cb)
                if cb then cb() end
            end,
            afterWifiAction = function() end,
            runWhenOnline = function(_, cb)
                Mock.state.wifi_online = true
                if cb then cb() end
            end,
        }
    end

    package.preload["device"] = function()
        return {
            powerd = {
                preventSuspend = function()
                    Mock.state.wakelock = Mock.state.wakelock + 1
                end,
                allowSuspend = function()
                    Mock.state.wakelock = Mock.state.wakelock - 1
                end,
                isCharging = function() return true end,
            },
            screen = {
                getWidth = function() return 1080 end,
                getHeight = function() return 1440 end,
            },
            isAndroid = function() return false end,
            isKindle = function() return false end,
            isKobo = function() return false end,
            isPocketBook = function() return false end,
            unpackArchive = function() return true end,
        }
    end

    package.preload["datastorage"] = function()
        return {
            getFullDataDir = function() return "/tmp/koreader" end,
            getSettingsDir = function() return "/tmp/koreader/settings" end,
        }
    end

    package.preload["luasettings"] = function()
        return {
            open = function()
                local store = {}
                return {
                    readSetting = function(_, k) return store[k] end,
                    saveSetting = function(_, k, v) store[k] = v end,
                    delSetting = function(_, k) store[k] = nil end,
                    flush = function() end,
                }
            end,
        }
    end

    package.preload["util"] = function()
        return {
            pathExists = function(path)
                return Mock.state.path_exists[path] == true
            end,
            makePath = function(path)
                Mock.state.path_exists[path] = true
                return true
            end,
            getFriendlySize = function(bytes)
                bytes = tonumber(bytes) or 0
                if bytes >= 1024 * 1024 then
                    return string.format("%.1f MB", bytes / 1024 / 1024)
                end
                return tostring(bytes) .. " B"
            end,
            getFilesystemType = function() return "ext4" end,
            urlEncode = function(s)
                return tostring(s):gsub("([^%w_%.%-])", function(c)
                    return string.format("%%%02X", string.byte(c))
                end)
            end,
        }
    end

    package.preload["st_utils"] = function()
        return {
            FOLDER_CACHE_TTL = 15,
            setAutostartPaused = function(v) Mock.state.autostart_paused = v and true or false end,
            isAutostartPaused  = function() return Mock.state.autostart_paused == true end,
            ALL_SETTINGS_KEYS = {},
            plugin_path = "/tmp/koreader/plugins/kosyncthing_plus.koplugin/",
            shellEscape = function(s)
                return tostring(s or ""):gsub("'", "'\\''")
            end,
            stripConflictInfix = function(name)
                if type(name) ~= "string" then return name end
                return (name:gsub("[.~]sync%-conflict%-[%d%-]+%-[%dA-Z]+(%.?[^/]*)$", "%1"))
            end,
            isConflictBasename = function(name)
                return type(name) == "string" and name:find("[.~]sync%-conflict%-") ~= nil
            end,
            globToLuaPattern = function(glob)
                local out, i = { "^" }, 1
                while i <= #glob do
                    local c = glob:sub(i, i)
                    if c == "*" then out[#out + 1] = ".*"
                    elseif c == "?" then out[#out + 1] = "."
                    elseif c:match("[%^%$%(%)%.%%%[%]%*%+%-%?]") then out[#out + 1] = "%" .. c
                    else out[#out + 1] = c end
                    i = i + 1
                end
                out[#out + 1] = "$"
                return table.concat(out)
            end,
            getMountPoint = function(path)
                return Mock.state.mount_points[path] or path
            end,
            getFreeSpace = function(path)
                return Mock.state.free_space[path] or Mock.state.free_space.default
            end,
            isOk = function(r)
                return r ~= nil and r.ok == true
            end,
            errOf = function(r)
                return (r and r.error) or "no response"
            end,
            formatBytes = tostring,
            formatTime = tostring,
            isValidDeviceID = function(s)
                return type(s) == "string" and #s > 0
            end,
            getConfigDir = function() return "/tmp/koreader/settings/syncthing" end,
            getDataDir = function() return "/tmp/koreader/settings/syncthing", nil end,
            invalidateLoopbackCache = function() end,
            invalidateCurlCache = function() end,
        }
    end

    package.preload["st_api_public"] = function()
        return {
            IgnoreRegistry = {
                getGeneration = function() return 0 end,
                matchesConflictBasename = function() return false end,
            },
        }
    end

    _G.G_reader_settings = {
        readSetting = function(_, key, default)
            local value = Mock.state.settings[key]
            if value == nil then return default end
            return value
        end,
        saveSetting = function(_, key, value)
            Mock.state.settings[key] = value
        end,
        delSetting = function(_, key)
            Mock.state.settings[key] = nil
        end,
        isTrue = function(_, key)
            return Mock.state.settings[key] == true
        end,
    }
end

function Mock.runNextTimer()
    local best_i, best
    for i, timer in ipairs(Mock.state.timers) do
        if not timer.cancelled and (not best or timer.delay < best.delay) then
            best_i, best = i, timer
        end
    end
    if not best then return false end
    table.remove(Mock.state.timers, best_i)
    Mock.state.now = Mock.state.now + best.delay
    best.fn()
    return true
end

function Mock.runTimers(limit)
    limit = limit or 100
    local count = 0
    while count < limit and Mock.runNextTimer() do
        count = count + 1
    end
    return count
end

return Mock
