-- st_health_spec.lua – tests for the status aggregation layer.
-- Covers every branch of getStatusHeader (8 priority cases + ordering),
-- headerNeedsAction, getStatusBullets (all bullet types), and ago.

local Mock = require("spec.spec_helper")

-- ─────────────────────────────────────────────────────────────────────────────
-- Module loader
-- ─────────────────────────────────────────────────────────────────────────────

local function freshHealth()
    package.loaded["st_health"] = nil
    -- st_health requires st_utils; give it the real one so it can call U.formatBytes etc.
    package.loaded["st_utils"]  = nil
    package.loaded["util"]      = nil
    local u_path = package.searchpath("st_utils", package.path)
    package.preload["st_utils"] = assert(loadfile(u_path))
    local h_path = package.searchpath("st_health", package.path)
    package.preload["st_health"] = assert(loadfile(h_path))
    return require("st_health")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Plugin stub factory
-- All fields have sensible defaults; override only what each test needs.
-- ─────────────────────────────────────────────────────────────────────────────

local function healthy()
    -- Default folder health: 1 active folder, nothing wrong.
    return { total = 1, paused = 0, syncing = 0, errors = 0,
             need_bytes = 0, watch_errors = {} }
end

local function makePlugin(ov)
    ov = ov or {}
    local p = {
        binaryExists    = ov.binaryExists    or function() return true  end,
        isRunning       = ov.isRunning       or function() return true  end,
        findConflicts   = ov.findConflicts   or function() return {}    end,
        getFolderHealth = ov.getFolderHealth or function() return healthy() end,
        getConnections  = ov.getConnections  or function() return {}    end,
        getDeviceId     = ov.getDeviceId     or function() return nil   end,
        _last_sync_progress     = ov._last_sync_progress,
        _connections_cache      = nil,
        _connections_cache_time = nil,
    }
    return p
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 1: ago
-- ─────────────────────────────────────────────────────────────────────────────

describe("ago", function()
    before_each(function() Mock.reset() end)

    it("returns nil for nil epoch", function()
        local H = freshHealth()
        assert.is_nil(H.ago(nil))
    end)

    it("returns nil for epoch 0", function()
        local H = freshHealth()
        assert.is_nil(H.ago(0))
    end)

    it("returns 'just now' for < 60 seconds ago", function()
        local H = freshHealth()
        local result = H.ago(os.time() - 30)
        assert.is_truthy(result:find("just now", 1, true))
    end)

    it("returns 'Xm ago' for < 1 hour ago", function()
        local H = freshHealth()
        local result = H.ago(os.time() - 14 * 60)   -- 14 minutes
        assert.is_truthy(result:find("14", 1, true))
        assert.is_truthy(result:find("m", 1, true))
    end)

    it("returns 'Xh ago' for < 1 day ago", function()
        local H = freshHealth()
        local result = H.ago(os.time() - 3 * 3600)   -- 3 hours
        assert.is_truthy(result:find("3", 1, true))
        assert.is_truthy(result:find("h", 1, true))
    end)

    it("returns 'Xd ago' for >= 1 day ago", function()
        local H = freshHealth()
        local result = H.ago(os.time() - 2 * 86400)  -- 2 days
        assert.is_truthy(result:find("2", 1, true))
        assert.is_truthy(result:find("d", 1, true))
    end)

    it("uses floor not round — 59s reads as 'just now', 61s as '1m ago'", function()
        local H = freshHealth()
        assert.is_truthy(H.ago(os.time() - 59):find("just now", 1, true))
        assert.is_truthy(H.ago(os.time() - 61):find("1", 1, true))
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 2: getStatusHeader – the 8 priority cases
-- ─────────────────────────────────────────────────────────────────────────────

describe("getStatusHeader – priority cases", function()
    before_each(function() Mock.reset() end)

    it("case 1 – binary not installed", function()
        local H = freshHealth()
        local p = makePlugin({ binaryExists = function() return false end })
        local h = H.getStatusHeader(p)
        assert.is_truthy(h:find("Not installed", 1, true))
    end)

    it("case 2 – daemon stopped", function()
        local H = freshHealth()
        local p = makePlugin({ isRunning = function() return false end })
        local h = H.getStatusHeader(p)
        assert.is_truthy(h:find("Stopped", 1, true))
        assert.is_truthy(h:find("tap to start", 1, true))
    end)

    it("case 3 – conflicts present", function()
        local H = freshHealth()
        local p = makePlugin({
            findConflicts = function() return { "/a/b.conflict", "/c/d.conflict" } end,
        })
        local h = H.getStatusHeader(p)
        assert.is_truthy(h:match("^⚠"))
        assert.is_truthy(h:find("2", 1, true))
        assert.is_truthy(h:find("conflict", 1, true))
    end)

    it("case 4 – folder errors", function()
        local H = freshHealth()
        local p = makePlugin({
            getFolderHealth = function()
                return { total=2, paused=0, syncing=0, errors=1,
                         need_bytes=0, watch_errors={} }
            end,
        })
        local h = H.getStatusHeader(p)
        assert.is_truthy(h:match("^⚠"))
        assert.is_truthy(h:find("Error", 1, true))
    end)

    it("case 5a – syncing, no progress percentage", function()
        local H = freshHealth()
        local p = makePlugin({
            getFolderHealth = function()
                return { total=1, paused=0, syncing=1, errors=0,
                         need_bytes=2*1024*1024, watch_errors={} }
            end,
        })
        local h = H.getStatusHeader(p)
        assert.is_truthy(h:find("Syncing", 1, true))
        assert.is_falsy(h:find("%%"))   -- no percentage sign
    end)

    it("case 5b – syncing with known progress percentage", function()
        local H = freshHealth()
        local p = makePlugin({
            getFolderHealth = function()
                return { total=1, paused=0, syncing=1, errors=0,
                         need_bytes=1024*1024, watch_errors={} }
            end,
            _last_sync_progress = { pct = 42 },
        })
        local h = H.getStatusHeader(p)
        assert.is_truthy(h:find("42", 1, true))
        assert.is_truthy(h:find("%%") or h:find("%", 1, true))
    end)

    it("case 6 – all folders paused", function()
        local H = freshHealth()
        local p = makePlugin({
            getFolderHealth = function()
                return { total=2, paused=2, syncing=0, errors=0,
                         need_bytes=0, watch_errors={} }
            end,
        })
        local h = H.getStatusHeader(p)
        assert.is_truthy(h:find("paused", 1, true))
    end)

    it("case 7 – up to date with at least one device online", function()
        local H = freshHealth()
        local p = makePlugin({
            getConnections = function()
                return { connections = {
                    ["DEVICE-A"] = { connected = true },
                    ["DEVICE-B"] = { connected = false },
                }}
            end,
        })
        local h = H.getStatusHeader(p)
        assert.is_truthy(h:find("Up to date", 1, true))
        assert.is_truthy(h:find("1", 1, true))
        assert.is_truthy(h:find("online", 1, true))
    end)

    -- In Syncthing's /system/connections, `isLocal` marks a connection over the
    -- LOCAL NETWORK (LAN) — not the local device.  Peers on the same Wi-Fi all
    -- report isLocal=true and MUST be counted.  Regression: they were excluded
    -- on isLocal, so a single-network setup showed "no devices online" while the
    -- device list showed every peer connected.
    it("counts LAN-connected peers (isLocal=true is a LAN connection, not the local device)", function()
        local H = freshHealth()
        local p = makePlugin({
            getDeviceId    = function() return "SELF-XXXX" end,
            getConnections = function()
                return { connections = {
                    ["REMOTE-1"] = { connected = true, isLocal = true },
                    ["REMOTE-2"] = { connected = true, isLocal = true },
                }}
            end,
        })
        local h = H.getStatusHeader(p)
        assert.is_truthy(h:find("2/2", 1, true))      -- both LAN peers online
    end)

    -- A peer reached over the internet/relay (not LAN) reports isLocal=false (or
    -- omits it).  The count must depend on connected + device ID, never on
    -- isLocal, so a LAN peer that switches to a global connection (and vice
    -- versa) keeps being counted, and a mix of both is summed correctly.  The
    -- local device's own entry (here keyed by self_id, not connected) is the
    -- only thing excluded.
    it("counts a global (non-LAN) peer and mixes LAN + global correctly", function()
        local H = freshHealth()
        local p = makePlugin({
            getDeviceId    = function() return "SELF-XXXX" end,
            getConnections = function()
                return { connections = {
                    ["LAN-PEER"]    = { connected = true,  isLocal = true  },
                    ["GLOBAL-PEER"] = { connected = true,  isLocal = false },
                    ["SELF-XXXX"]   = { connected = false, isLocal = false }, -- local, excluded by ID
                }}
            end,
        })
        local h = H.getStatusHeader(p)
        assert.is_truthy(h:find("2/2", 1, true))   -- LAN + global counted, local excluded
    end)

    -- Older daemons (e.g. the legacy v1.2.2 binary) may not send isLocal, so the
    -- local entry is identified by its key matching the local device ID instead.
    it("excludes the local device by device ID when isLocal is absent", function()
        local H = freshHealth()
        local p = makePlugin({
            getDeviceId    = function() return "SELF-XXXX" end,
            getConnections = function()
                return { connections = {
                    ["REMOTE-1"]  = { connected = true },
                    ["SELF-XXXX"] = { connected = false },   -- no isLocal field
                }}
            end,
        })
        local h = H.getStatusHeader(p)
        assert.is_truthy(h:find("1/1", 1, true))
        assert.is_nil(h:find("1/2", 1, true))
    end)

    it("case 8 – up to date, no devices online", function()
        local H = freshHealth()
        local p = makePlugin()    -- getConnections returns {}
        local h = H.getStatusHeader(p)
        assert.is_truthy(h:find("Up to date", 1, true))
        assert.is_truthy(h:find("no devices", 1, true))
    end)

    it("API not responding yet (getFolderHealth=nil) → Starting up…", function()
        local H = freshHealth()
        local p = makePlugin({
            getFolderHealth = function() return nil end,
        })
        local h = H.getStatusHeader(p)
        assert.is_truthy(h:find("Starting", 1, true))
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 3: getStatusHeader – priority ordering
-- ─────────────────────────────────────────────────────────────────────────────

describe("getStatusHeader – priority ordering", function()
    before_each(function() Mock.reset() end)

    it("conflicts win over folder errors (case 3 > case 4)", function()
        local H = freshHealth()
        local p = makePlugin({
            findConflicts   = function() return { "/x" } end,
            getFolderHealth = function()
                return { total=1, paused=0, syncing=0, errors=1,
                         need_bytes=0, watch_errors={} }
            end,
        })
        local h = H.getStatusHeader(p)
        assert.is_truthy(h:find("conflict", 1, true))
        assert.is_falsy(h:find("Error", 1, true))
    end)

    it("folder errors win over syncing (case 4 > case 5)", function()
        local H = freshHealth()
        local p = makePlugin({
            getFolderHealth = function()
                return { total=2, paused=0, syncing=1, errors=1,
                         need_bytes=512*1024, watch_errors={} }
            end,
        })
        local h = H.getStatusHeader(p)
        assert.is_truthy(h:find("Error", 1, true))
        assert.is_falsy(h:find("Syncing", 1, true))
    end)

    it("syncing wins over all-paused (case 5 > case 6)", function()
        local H = freshHealth()
        local p = makePlugin({
            getFolderHealth = function()
                -- All 3 folders paused, but 1 is also syncing (shouldn't happen
                -- in practice, but tests the pure code path ordering).
                return { total=3, paused=3, syncing=1, errors=0,
                         need_bytes=1024, watch_errors={} }
            end,
        })
        local h = H.getStatusHeader(p)
        assert.is_truthy(h:find("Syncing", 1, true))
    end)

    it("stopped wins over conflicts (daemon not running means no conflict data)", function()
        -- When isRunning=false, getStatusHeader returns case 2 immediately without
        -- ever calling findConflicts.
        local H = freshHealth()
        local conflict_checked = false
        local p = makePlugin({
            isRunning     = function() return false end,
            findConflicts = function() conflict_checked = true; return { "/x" } end,
        })
        H.getStatusHeader(p)
        assert.is_false(conflict_checked)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 4: headerNeedsAction
-- ─────────────────────────────────────────────────────────────────────────────

describe("headerNeedsAction", function()
    before_each(function() Mock.reset() end)

    it("returns true when there are conflicts (header starts with ⚠)", function()
        local H = freshHealth()
        local p = makePlugin({
            findConflicts = function() return { "/x" } end,
        })
        assert.is_true(H.headerNeedsAction(p))
    end)

    it("returns true when there are folder errors (header starts with ⚠)", function()
        local H = freshHealth()
        local p = makePlugin({
            getFolderHealth = function()
                return { total=1, paused=0, syncing=0, errors=2,
                         need_bytes=0, watch_errors={} }
            end,
        })
        assert.is_true(H.headerNeedsAction(p))
    end)

    it("returns false when stopped", function()
        local H = freshHealth()
        local p = makePlugin({ isRunning = function() return false end })
        assert.is_false(H.headerNeedsAction(p))
    end)

    it("returns false when up to date", function()
        local H = freshHealth()
        assert.is_false(H.headerNeedsAction(makePlugin()))
    end)

    it("returns false when syncing", function()
        local H = freshHealth()
        local p = makePlugin({
            getFolderHealth = function()
                return { total=1, paused=0, syncing=1, errors=0,
                         need_bytes=1024, watch_errors={} }
            end,
        })
        assert.is_false(H.headerNeedsAction(p))
    end)

    it("returns false when all folders paused", function()
        local H = freshHealth()
        local p = makePlugin({
            getFolderHealth = function()
                return { total=2, paused=2, syncing=0, errors=0,
                         need_bytes=0, watch_errors={} }
            end,
        })
        assert.is_false(H.headerNeedsAction(p))
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 5: getStatusBullets
-- ─────────────────────────────────────────────────────────────────────────────

local function findBullet(bullets, text_fragment)
    for _, b in ipairs(bullets) do
        if b.text:find(text_fragment, 1, true) then return b end
    end
    return nil
end

describe("getStatusBullets", function()
    before_each(function() Mock.reset() end)

    it("returns a single 'not running' bullet when stopped", function()
        local H = freshHealth()
        local p = makePlugin({ isRunning = function() return false end })
        local bullets = H.getStatusBullets(p)
        assert.are.equal(1, #bullets)
        assert.is_truthy(bullets[1].text:find("not running", 1, true))
        assert.are.equal("info", bullets[1].severity)
    end)

    it("shows 'No folders' bullet when total=0", function()
        local H = freshHealth()
        local p = makePlugin({
            getFolderHealth = function()
                return { total=0, paused=0, syncing=0, errors=0,
                         need_bytes=0, watch_errors={} }
            end,
        })
        local bullets = H.getStatusBullets(p)
        assert.is_truthy(findBullet(bullets, "No folders"))
    end)

    it("shows syncing bullet with remaining size when syncing", function()
        local H = freshHealth()
        local p = makePlugin({
            getFolderHealth = function()
                return { total=1, paused=0, syncing=2, errors=0,
                         need_bytes=3*1024*1024, watch_errors={} }
            end,
        })
        local bullets = H.getStatusBullets(p)
        local b = findBullet(bullets, "Syncing")
        assert.is_not_nil(b)
        assert.are.equal("info", b.severity)
        assert.is_truthy(b.text:find("2", 1, true))   -- 2 folders
    end)

    it("shows all-paused bullet when paused == total", function()
        local H = freshHealth()
        local p = makePlugin({
            getFolderHealth = function()
                return { total=3, paused=3, syncing=0, errors=0,
                         need_bytes=0, watch_errors={} }
            end,
        })
        local bullets = H.getStatusBullets(p)
        local b = findBullet(bullets, "paused")
        assert.is_not_nil(b)
        assert.are.equal("warn", b.severity)
    end)

    it("shows up-to-date bullet with active count when healthy", function()
        local H = freshHealth()
        local p = makePlugin({
            getFolderHealth = function()
                return { total=3, paused=1, syncing=0, errors=0,
                         need_bytes=0, watch_errors={} }
            end,
        })
        local bullets = H.getStatusBullets(p)
        -- 3-1 = 2 active folders
        local b = findBullet(bullets, "up to date")
        assert.is_not_nil(b)
        assert.is_truthy(b.text:find("2", 1, true))
        assert.are.equal("ok", b.severity)
    end)

    it("adds an errors bullet when h.errors > 0", function()
        local H = freshHealth()
        local p = makePlugin({
            getFolderHealth = function()
                return { total=2, paused=0, syncing=0, errors=1,
                         need_bytes=0, watch_errors={} }
            end,
        })
        local bullets = H.getStatusBullets(p)
        local b = findBullet(bullets, "error")
        assert.is_not_nil(b)
        assert.are.equal("error", b.severity)
    end)

    it("adds a watch-errors bullet when watch_errors is non-empty", function()
        local H = freshHealth()
        local p = makePlugin({
            getFolderHealth = function()
                return { total=1, paused=0, syncing=0, errors=0,
                         need_bytes=0, watch_errors={"inotify limit reached"} }
            end,
        })
        local bullets = H.getStatusBullets(p)
        local b = findBullet(bullets, "watcher")
        assert.is_not_nil(b)
        assert.is_truthy(b.text:find("inotify", 1, true))
        assert.are.equal("warn", b.severity)
    end)

    it("adds a partial-paused bullet when 0 < paused < total", function()
        local H = freshHealth()
        local p = makePlugin({
            getFolderHealth = function()
                return { total=4, paused=1, syncing=0, errors=0,
                         need_bytes=0, watch_errors={} }
            end,
        })
        local bullets = H.getStatusBullets(p)
        local b = findBullet(bullets, "1")
        -- Look for the partial-paused bullet specifically (severity=warn, text has "paused")
        local paused_b = nil
        for _, bullet in ipairs(bullets) do
            if bullet.severity == "warn" and bullet.text:find("paused", 1, true) then
                paused_b = bullet
            end
        end
        assert.is_not_nil(paused_b)
    end)

    it("adds 'No sync conflicts' bullet (ok) when no conflicts", function()
        local H = freshHealth()
        local bullets = H.getStatusBullets(makePlugin())
        local b = findBullet(bullets, "No sync conflicts")
        assert.is_not_nil(b)
        assert.are.equal("ok", b.severity)
    end)

    it("adds conflicts bullet (warn) when conflicts present", function()
        local H = freshHealth()
        local p = makePlugin({
            findConflicts = function() return { "/a", "/b", "/c" } end,
        })
        local bullets = H.getStatusBullets(p)
        local b = findBullet(bullets, "conflict")
        assert.is_not_nil(b)
        assert.are.equal("warn", b.severity)
        assert.is_truthy(b.text:find("3", 1, true))
    end)

    it("adds devices-online bullet when connected count > 0", function()
        local H = freshHealth()
        local p = makePlugin({
            getConnections = function()
                return { connections = {
                    X = { connected = true },
                    Y = { connected = true },
                }}
            end,
        })
        local bullets = H.getStatusBullets(p)
        local b = findBullet(bullets, "online")
        assert.is_not_nil(b)
        assert.are.equal("ok", b.severity)
        assert.is_truthy(b.text:find("2", 1, true))
    end)

    it("adds no-devices bullet when nothing is connected", function()
        local H = freshHealth()
        local bullets = H.getStatusBullets(makePlugin())  -- getConnections returns {}
        local b = findBullet(bullets, "No remote devices")
        assert.is_not_nil(b)
        assert.are.equal("info", b.severity)
    end)

    it("adds 'Waiting for local API' bullet when getFolderHealth returns nil", function()
        local H = freshHealth()
        local p = makePlugin({ getFolderHealth = function() return nil end })
        local bullets = H.getStatusBullets(p)
        local b = findBullet(bullets, "API")
        assert.is_not_nil(b)
        assert.are.equal("info", b.severity)
    end)

    it("connection cache: getConnections called only once for two header calls", function()
        local H = freshHealth()
        local calls = 0
        local p = makePlugin({
            getConnections = function()
                calls = calls + 1
                return { connections = { X = { connected = true } } }
            end,
        })
        H.getStatusHeader(p)
        H.getStatusHeader(p)
        assert.are.equal(1, calls)
    end)
end)
