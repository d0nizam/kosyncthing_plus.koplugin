-- st_health.lua — Smart status aggregation
--
-- Produces a one-line status summary suitable for showing as the top-level
-- menu header.  The goal is that the user understands the current state of
-- Syncthing without drilling into any submenu.
--
-- The summary is computed from cached data only (folder_health, conflicts,
-- connections), so it is cheap to call from `text_func` on every menu render.

local time   = require("ui/time")
local util   = require("util")
local _      = require("syncthing_i18n").gettext
local N_     = require("syncthing_i18n").ngettext
local T      = require("ffi/util").template

local U = require("st_utils")

local CONNECTION_CACHE_TTL = 10
-- Android remote mode talks to the companion app over REST (slower than the
-- local loopback daemon), so the connection count is cached a little longer
-- there.  Actions invalidate the cache, keeping post-action state fresh.
local ANDROID_CONNECTION_CACHE_TTL = 20

---------------------------------------------------------------------------
-- Internal helpers
---------------------------------------------------------------------------

-- How long ago an event happened, in human terms.
-- Used by the header to say "last synced 14m ago".
local function ago(epoch)
    if not epoch or epoch == 0 then return nil end
    local diff = os.time() - epoch
    if diff < 60     then return _("just now") end
    if diff < 3600   then return T(_("%1m ago"),  math.floor(diff / 60)) end
    if diff < 86400  then return T(_("%1h ago"),  math.floor(diff / 3600)) end
    return T(_("%1d ago"), math.floor(diff / 86400))
end

-- Count remote devices: how many are currently exchanging data with us
-- (online) and how many are configured in total.  The connections map lists
-- every configured remote device with a `connected` flag (the local device is
-- not part of it), so the number of entries is the remote total and the
-- connected entries are the online count.  Both values are cached together.
--
-- Returns: online, total
local function countConnectedDevices(self)
    if not self:isRunning() then return 0, 0 end
    local now = time.to_s(time.now())
    local conn_ttl = self._android_mode and ANDROID_CONNECTION_CACHE_TTL or CONNECTION_CACHE_TTL
    if self._connections_cache
       and (now - (self._connections_cache_time or 0)) < conn_ttl then
        return self._connections_cache, self._connections_total or self._connections_cache
    end
    local connections = self:getConnections() or {}
    local conn_map    = connections.connections or {}
    -- Identify the LOCAL device's own entry so it does not inflate the
    -- "X/Y devices online" count.  It is keyed by the local device ID and, when
    -- present in the map, Syncthing reports it as not connected (see the REST
    -- API docs: the list "also contains the local device itself as not
    -- connected").
    --
    -- NOTE: `conn.isLocal` is NOT a local-device marker.  In Syncthing it means
    -- the connection is over the local network (LAN).  Every peer on the same
    -- Wi-Fi reports isLocal=true, so excluding on it zeroed the count for any
    -- single-network setup (all peers dropped).  Match on the device ID only.
    local self_id = self.getDeviceId and self:getDeviceId() or nil
    local online, total = 0, 0
    for id, conn in pairs(conn_map) do
        local is_self = (self_id ~= nil and id == self_id)
        if not is_self then
            total = total + 1
            if conn.connected then online = online + 1 end
        end
    end
    self._connections_cache      = online
    self._connections_total      = total
    self._connections_cache_time = now
    return online, total
end

---------------------------------------------------------------------------
-- Public: getStatusHeader
--
-- Returns a single short line describing what Syncthing is doing right now.
-- Cases (in priority order):
--   1. Daemon not installed     → "Syncthing not installed — tap to install"
--   2. Daemon stopped           → "Stopped — tap to start"
--   3. Conflicts present        → "⚠ N file conflicts need attention"
--   4. Folder errors            → "⚠ Errors in N folders"
--   5. Currently syncing        → "Syncing… X MB remaining"
--   6. All folders paused       → "All folders paused"
--   7. Up to date (peers seen)  → "Up to date · N devices online"
--   8. Up to date (no peers)    → "Up to date · no devices online"
---------------------------------------------------------------------------
local function getStatusHeader(self)
    if not self:binaryExists() then
        -- Header is read-only when not installed (headerNeedsAction returns false
        -- for this state).  Don't say "tap to install" — the row is greyed and
        -- tapping it does nothing.  The "Install Syncthing binary" row below
        -- handles installation clearly.
        return _("Not installed — use \"Install Syncthing binary\" below")
    end

    if not self:isRunning() then
        -- On Android the daemon belongs to the separate Syncthing app; there is
        -- no local daemon to "start" from here, so word it for that context.
        if self._android_mode then
            return _("Syncthing app not reachable — open it to sync")
        end
        return _("Stopped — tap to start")
    end

    -- Conflicts get top billing because they are user-visible problems.
    local conflicts = self:findConflicts()
    if #conflicts > 0 then
        return T(N_("⚠ %1 file conflict needs attention", "⚠ %1 file conflicts need attention", #conflicts), #conflicts)
    end

    local h = self:getFolderHealth()
    if not h then
        return _("Starting up…")
    end

    if h.errors > 0 then
        return T(N_("⚠ Error in %1 folder", "⚠ Errors in %1 folders", h.errors), h.errors)
    end

	if h.syncing > 0 then
		local remaining = util.getFriendlySize(h.need_bytes)
		local prog = self._last_sync_progress
		if prog and prog.pct and prog.pct > 0 then
			return T(_("Syncing… %1% (%2 remaining)"), prog.pct, remaining)
		else
			return T(_("Syncing… %1 remaining"), remaining)
		end
	end

    if h.total > 0 and h.paused == h.total then
        return _("All folders paused")
    end

    local online, total = countConnectedDevices(self)
    if online > 0 then
        return T(N_("Up to date · %1/%2 device online", "Up to date · %1/%2 devices online", total), online, total)
    end

    return _("Up to date · no devices online")
end

---------------------------------------------------------------------------
-- Public: getStatusBullets
--
-- Returns a list of short status lines used by the Status submenu.  Each
-- entry is a {symbol, text, severity} triple suitable for rendering as a
-- single menu row.  Severity is "ok" | "warn" | "error" | "info".
---------------------------------------------------------------------------
local function getStatusBullets(self)
    local bullets = {}

    if not self:isRunning() then
        table.insert(bullets, {
            symbol   = "o",
            text     = _("Syncthing is not running"),
            severity = "info",
        })
        return bullets
    end

    local h = self:getFolderHealth()
    if h then
        if h.total == 0 then
            table.insert(bullets, {
                symbol   = "ℹ",
                text     = _("No folders are configured yet"),
                severity = "info",
            })
        elseif h.syncing > 0 then
            table.insert(bullets, {
                symbol   = "⟳",
                text     = T(N_("Syncing %1 folder · %2 remaining", "Syncing %1 folders · %2 remaining", h.syncing),
                             h.syncing, util.getFriendlySize(h.need_bytes)),
                severity = "info",
            })
        elseif h.paused == h.total then
            table.insert(bullets, {
                symbol   = "⏸",
                text     = _("All folders paused"),
                severity = "warn",
            })
        else
            local active = h.total - h.paused
            table.insert(bullets, {
                symbol   = "✓",
                text     = T(N_("%1 folder up to date", "%1 folders up to date", active), active),
                severity = "ok",
            })
        end

        if h.errors > 0 then
            table.insert(bullets, {
                symbol   = "✗",
                text     = T(N_("%1 folder reporting errors", "%1 folders reporting errors", h.errors), h.errors),
                severity = "error",
            })
        end

        if #h.watch_errors > 0 then
            table.insert(bullets, {
                symbol   = "⚠",
                text     = T(_("File watcher failed: %1"),
                             table.concat(h.watch_errors, ", ")),
                severity = "warn",
            })
        end

        if h.paused > 0 and h.paused < h.total then
            table.insert(bullets, {
                symbol   = "⏸",
                text     = T(N_("%1 folder paused", "%1 folders paused", h.paused), h.paused),
                severity = "warn",
            })
        end
    else
	    -- h is nil: the daemon is running, but the REST API is not responding yet.
        -- This is normal for a few seconds after startup.
        table.insert(bullets, {
            symbol   = "⟳",
            text     = _("Waiting for local API…"),
            severity = "info",
        })
    end

    -- Conflicts row (always present, even when zero, so the user can confirm
    -- nothing is wrong rather than wondering whether the check ran).
    local conflicts = self:findConflicts()
    if #conflicts > 0 then
        table.insert(bullets, {
            symbol   = "⚠",
            text     = T(N_("%1 sync conflict needs attention", "%1 sync conflicts need attention", #conflicts), #conflicts),
            severity = "warn",
        })
    else
        table.insert(bullets, {
            symbol   = "✓",
            text     = _("No sync conflicts"),
            severity = "ok",
        })
    end

    -- Connected devices row.
    local online, total = countConnectedDevices(self)
    if online > 0 then
        table.insert(bullets, {
            symbol   = "⇆",
            text     = T(N_("%1/%2 remote device online", "%1/%2 remote devices online", total), online, total),
            severity = "ok",
        })
    else
        table.insert(bullets, {
            symbol   = "∅",
            text     = _("No remote devices currently online"),
            severity = "info",
        })
    end

    return bullets
end

---------------------------------------------------------------------------
-- Public: headerNeedsAction
--
-- Returns true when the status header describes a situation that requires
-- the user's attention and that opening the Status submenu would help with
-- (currently: unresolved file conflicts or folder errors).
--
-- Used by the menu row to decide whether to make the header tappable and
-- whether to append a contextual hint such as "— tap to resolve".
--
-- Rule: the header starts with "⚠" for exactly these two cases.  We derive
-- the answer from the header string itself so the two functions can never
-- get out of sync.
---------------------------------------------------------------------------
local function headerNeedsAction(self)
    local header = getStatusHeader(self)
    return header:match("^⚠") ~= nil
end

return {
    getStatusHeader   = getStatusHeader,
    headerNeedsAction = headerNeedsAction,
    getStatusBullets  = getStatusBullets,
    ago               = ago,
}