# KOSyncthing+ – Public API

The plugin exposes a rich public API that companion plugins can use
to monitor and control Syncthing, without duplicating internal logic.

---

## Getting the API

After the plugin has initialised, you can access the API in two ways:

```lua
-- Via require (recommended)
local Syncthing = require("st_api_public").api

-- Via global variable
local Syncthing = _G.KOSyncthingPlusAPI
```

Both reference the same table.

### API version

```lua
Syncthing.version  --> string, e.g. "1.1.1"
```

Use this to gate features when writing a companion plugin that may run
against different installed versions of the plugin.

### Platform support

The API is platform-agnostic.  On **Android** the plugin runs in *remote mode*:
it talks to a separately installed Syncthing app (e.g. Syncthing-Fork or
BasicSync) over that app's REST API.  Every call — `apiCall` and the `status` /
`control` / `info` helpers — is routed to the app transparently, and `version`
is unchanged, so companion plugins need **no** Android-specific code; they use
`_G.KOSyncthingPlusAPI` exactly as on Kindle/Kobo.

One behavioural note for remote mode: `control.start()` and `control.stop()` are
no-ops, because the Syncthing app owns the daemon.  Use `status.isRunning()` to
check whether the app is reachable rather than starting it yourself.

---

## Status – Read-only Live State

```lua
Syncthing.status.isRunning()        --> boolean
Syncthing.status.getConflicts()     --> table of conflict paths (strings)
Syncthing.status.getFolderHealth()  --> aggregate health table (see below)
Syncthing.status.getStatusHeader()  --> one-line summary string
Syncthing.status.getDeviceId()      --> string (this device's ID)
Syncthing.status.isPeriodicSyncEnabled()  --> boolean
Syncthing.status.getPeriodicSyncInterval() --> number (minutes, 1–1440)
Syncthing.status.getNextPeriodicSyncAt()  --> os.time() epoch or nil
```

### `getFolderHealth()` return format

Returns `nil` when Syncthing is not running or the API is unreachable.
Otherwise returns a table:

| Field | Type | Description |
|---|---|---|
| `syncing` | `number` | Count of folders currently transferring data |
| `errors` | `number` | Count of folders with errors |
| `need_bytes` | `number` | Total bytes outstanding across all non-paused folders |
| `paused` | `number` | Count of paused folders |
| `total` | `number` | Total configured folder count |
| `watch_errors` | `table` | List of folder labels that have filesystem-watcher errors |
| `folder_states` | `table` | Per-folder state map, keyed by folder ID (see below) |

Each entry in `folder_states[folder_id]`:

| Field | Type | Description |
|---|---|---|
| `state` | `string` | Syncthing folder state: `"idle"`, `"syncing"`, `"scanning"`, `"error"`, `"paused"`, `"unknown"` |
| `need_bytes` | `number` | Bytes outstanding for this folder |
| `errors` | `boolean` | True if the folder has reported errors |
| `paused` | `boolean` | True if the folder is paused |

---

## Control – Actions

```lua
Syncthing.control.start(callback)
Syncthing.control.stop(callback)
Syncthing.control.quickSync(touchmenu_instance)
Syncthing.control.toggle(callback)
Syncthing.control.pauseAllFolders()
Syncthing.control.resumeAllFolders()
Syncthing.control.setPeriodicSyncEnabled(enabled)
Syncthing.control.setPeriodicSyncInterval(minutes)
Syncthing.control.runPeriodicSyncNow()
```

#### `start(callback)` / `stop(callback)`

Start or stop the Syncthing daemon.

- `callback` (`function`, optional) — called with no arguments after the
  operation completes (or is rejected, e.g. because a start is already in
  progress). Wrapped in `pcall`; errors in the callback do not affect the
  plugin.
- No return value (fire-and-forget; the callback carries the result signal).

If no binary is installed, `start` shows the first-run download dialog
instead of attempting to launch.

#### `toggle(callback)`

Convenience wrapper: calls `stop` if running, `start` if stopped.
Same `callback` contract as `start`/`stop`.

#### `quickSync(on_complete)`

Run a full Quick Sync: start → scan all folders → wait for idle →
show transfer summary → stop.

- `on_complete` (`function`, optional) — called with no arguments after
  the entire flow finishes (whether by success, error, or timeout).
  Wrapped in `pcall`; errors in the callback do not affect the plugin.
  Pass `nil` if you only need the `SyncthingSyncCompleted` event.
- Returns nothing; progress is communicated via toast notifications and
  the `SyncthingSyncCompleted` KOReader event.

```lua
-- With completion callback
Syncthing.control.quickSync(function()
    myWidget:refresh()
end)

-- Fire and forget
Syncthing.control.quickSync()
```

> If Syncthing is already running when `quickSync` is called, it triggers
> a rescan only (no start/stop). The `on_complete` callback still fires.

#### `pauseAllFolders()` / `resumeAllFolders()`

Toggle the paused state of all configured folders via the Syncthing REST
API. Return nothing; errors are logged internally.
#### `setPeriodicSyncEnabled(enabled)`

Enable or disable automatic periodic Quick Sync.
- `enabled` (`boolean`) – `true` to turn on, `false` to turn off.
- Returns `true` on success, `nil` and an error message on failure.
- Saves the setting persistently.

#### `setPeriodicSyncInterval(minutes)`

Set a new interval for periodic sync.
- `minutes` (`number`) – interval in minutes (1–1440). Must be a whole number (no decimals).
- If periodic sync is enabled, the timer restarts with the new interval.
- Returns `true` on success, `nil` and an error message on failure.

#### `runPeriodicSyncNow()`

Run one periodic sync cycle immediately, without waiting for the next scheduled time.
- Requires `periodic_sync_enabled == true`.
- Returns `true` on success, `nil` and an error message on failure.
- Does not alter the schedule – the next execution stays on the regular interval.
---

## Conflict Resolution (Programmatic)

Resolve conflicts without showing any UI – useful for companion plugins
that want to implement their own conflict handling or auto-resolve
everything.

### Resolve All Conflicts

```lua
local result = Syncthing.control.resolveAllConflicts("keep_local")
-- result = { kept_local = 3, kept_remote = 0, merged = 0, skipped = 0, failed = 0 }
```

All strategies return a **consistent table** with all five fields:

| Field | Type | Description |
|---|---|---|
| `kept_local` | `number` | Conflicts where the local version was kept |
| `kept_remote` | `number` | Conflicts where the remote version was applied |
| `merged` | `number` | Conflicts merged (only for `"auto_merge"`) |
| `skipped` | `number` | Files intentionally left untouched |
| `failed` | `number` | Files that could not be resolved due to I/O errors |

### Auto Merge

```lua
local stats = Syncthing.control.resolveAllConflicts("auto_merge")
-- stats = {
--     merged = 2,
--     kept_local = 1,
--     kept_remote = 1,
--     skipped = 0,
--     failed = 0
-- }
```

### Resolve a Single Conflict

```lua
local ok, err = Syncthing.control.resolveConflictByPath(
    "/path/to/file.sync-conflict-...",
    "use_remote"
)
```

### Conflict Resolution Strategies

| Strategy | Effect |
|---|---|
| `"keep_local"` | Delete all conflict copies. Returns `kept_local` and `failed`. |
| `"use_remote"` | Replace originals with conflict copies. Returns `kept_remote`, `skipped`, and `failed`. |
| `"auto_merge"` | Keep higher reading progress for metadata; skip non-metadata. Returns all five fields. |

> **Note:** `resolveConflictByPath` accepts only `"keep_local"` and `"use_remote"`. Passing `"auto_merge"` returns an `"Unknown strategy"` error — to auto-merge by reading progress use `resolveAllConflicts("auto_merge")`, which keeps the higher progress and skips non-metadata files automatically.

After any conflict resolution:

- Caches are invalidated automatically
- Listeners are notified

---

## Ignore Pattern Management

### Get Ignore Patterns

```lua
local patterns, err = Syncthing.info.getFolderIgnore("folder-id")

for _, p in ipairs(patterns) do
    print(p)
    -- e.g. "(?d)Thumbs.db", "*.tmp", "// comment"
end
```

Returns a table of strings representing the current ignore patterns.
May be empty. Returns `nil` and an error message on failure.

### Set Ignore Patterns

```lua
local newPatterns = {
    "(?d)Thumbs.db",
    "*.tmp",
    "// This is a comment",
}

local ok, err = Syncthing.control.setFolderIgnore(
    "folder-id",
    newPatterns
)
```

Replaces the entire ignore list for the given folder.
Returns `true` on success, or `nil` and an error message on failure.

> Note: Changing ignore patterns does not trigger an automatic rescan.
> Use `Syncthing.control.quickSync()` or let a periodic sync handle it.

### Pattern Syntax

The following directives are supported by Syncthing:

| Pattern | Description |
|---|---|
| `(?d)` | Allow deletion if it prevents directory removal |
| `(?i)` | Case-insensitive matching |
| `!` | Negate the pattern |
| `*` | Single-level wildcard |
| `**` | Multi-level wildcard |
| `//` | Comment (must be at the start of a line) |

Refer to the Syncthing documentation for a complete description.

> Note: Changing ignore patterns does not trigger an automatic rescan.
> Use `Syncthing.control.quickSync()` or let a periodic sync handle it.

---

## Information – Detailed Data

### Folder Listing

```lua
local folders = Syncthing.info.getFolders()

for _, f in ipairs(folders) do
    print(
        f.id,
        f.label,
        f.path,
        f.state,
        f.needBytes,
        f.paused
    )
end
```

### Device Listing

```lua
local devices = Syncthing.info.getDevices()

for _, d in ipairs(devices) do
    print(
        d.id,
        d.name,
        d.connected,
        d.address,
        d.paused
    )
end
```

### Pending Requests

```lua
local pendingDevices = Syncthing.info.getPendingDevices()
local pendingFolders = Syncthing.info.getPendingFolders()
```

### Plugin Configuration (Read-only)

```lua
local port    = Syncthing.info.getGUIPort()
local profile = Syncthing.info.getResourceProfile()
local netMode = Syncthing.info.getNetworkAccess()
```

### Detailed Conflict Information

```lua
local details = Syncthing.info.getConflictsDetailed()

for _, c in ipairs(details) do
    print(c.path, c.original_path, c.is_metadata, c.local_progress, c.remote_progress)
end
```

Returns a table where each entry describes one sync conflict with all the
information needed to build a custom resolution dialog.

| Field | Type | Description |
|---|---|---|
| `path` | `string` | Full path to the conflict file |
| `original_path` | `string` | Path to the original file (may be same if missing) |
| `is_metadata` | `bool` | True if it's a KOReader metadata sidecar |
| `has_progress` | `bool` | True if `percent_finished` was found |
| `local_progress` | `number or nil` | Reading progress of the local copy (`0–100`) |
| `remote_progress` | `number or nil` | Reading progress of the remote copy (`0–100`) |
| `local_mtime` | `number or nil` | Unix timestamp of the local file |
| `remote_mtime` | `number or nil` | Unix timestamp of the conflict copy |

The function internally calls `findConflicts()` and enriches the result
with metadata detection, reading-progress extraction, and file timestamps.
Companion plugins can use this to build their own conflict resolution UI
without duplicating the parsing logic.

---

## Proxied REST Call

Companion plugins can issue any Syncthing REST API request without
ever seeing the API key. The secret stays inside the plugin.

### GET Request

```lua
local config = Syncthing.apiCall("config/folders")
```

### POST / PATCH Requests

```lua
Syncthing.apiCall(
    "config/devices",
    "POST",
    '{"deviceID":"...","name":"My Device"}'
)

Syncthing.apiCall(
    "config/folders/abc123",
    "PATCH",
    '{"paused":true}'
)
```

### Function Signature

```lua
apiCall(endpoint, method, body)
```

### Parameters

| Parameter | Description |
|---|---|
| `endpoint` | Example: `"system/status"` or `"db/status?folder=id"` |
| `method` | `"GET"` (default), `"POST"`, `"PATCH"`, `"DELETE"` |
| `body` | Optional JSON string |

### Return value

Returns the **raw parsed response** from Syncthing:

- On **success** — a Lua table (parsed JSON). Write endpoints that return
  an empty body (e.g. `POST db/scan`, `PATCH config/folders/{id}`) return
  `true` instead of a table.
- On **failure** (network error, timeout, non-2xx status) — `nil`.

This is a thin transport wrapper. It does not use the SafeClient result
envelope (`{ok, error, data}`) — use the `status` and `info` APIs when
you need structured error handling.

## Events

### Custom Listener List

```lua
Syncthing.onStatusChange(function(event, data)
    if event == "process_started" then
        -- daemon started

    elseif event == "process_stopped" then
        -- daemon stopped

    elseif event == "conflicts_changed" then
        -- data is a table of conflict paths
        -- or nil to force refresh
    end
end)

-- Later, remove the listener
Syncthing.offStatusChange(callback)
```

All callbacks are wrapped in `pcall` – a broken listener will never
crash KOSyncthing+.

---

## KOReader Global Events

The plugin also broadcasts standard KOReader events that any widget
can listen to via `UIManager:registerListener`.

### `SyncthingSyncCompleted`

Fired after a Quick Sync completes.

> **Note (v1.1.1+):** The plugin itself subscribes to this event via
> `onSyncthingSyncCompleted` to run the opt-in auto-merge pass. Companion
> plugin handlers receive the event after the internal handler has already
> run, so any conflicts the auto-merge resolved will no longer appear in
> `Syncthing.status.getConflicts()` by the time your handler fires.
> If you need to act on *all* conflicts including those that are auto-merged,
> subscribe to `SyncthingConflictDetected` instead, which fires earlier
> (during the sync), before the completion event and before auto-merge runs.

#### Event Arguments

```lua
{
    sent = 1234,
    received = 5678,
    upToDate = false
}
```

### `SyncthingConflictDetected`

Fired when new conflicts are found.

#### Event Arguments

```lua
{
    "/path/to/conflict1",
    "/path/to/conflict2"
}
```

---

## Utilities

```lua
Syncthing.util.formatBytes(1234567)
--> "1.2 MB"

Syncthing.util.isValidDeviceID("...")
--> true / false

Syncthing.util.formatTime("2024-...")
--> formatted date/time
```

---

## IgnoreRegistry

Companion plugins can exclude their own files' conflict copies from the
conflict scanner so the Conflicts badge stays accurate.  A plugin registers a
list of filename globs against the ORIGINAL basenames; the registry matches a
conflict copy by de-mangling its `.sync-conflict-…` / `~sync-conflict-…` name
first, so a companion registers plain names (`state.lua`, `*.sdr`) and never
encodes the conflict form itself.

### Register Ignore Pattern

```lua
-- A single glob, or a list of globs.  The call REPLACES this plugin's set.
_G.KOSyncthingPlusAPI.IgnoreRegistry:register(
    "my_plugin_id",
    { "*.my-sidecar", "state.lua", "metadata.*.lua" }
)
```

Patterns match the **original** basename; the registry handles the
`.sync-conflict-…` mangling, so do not add it yourself.  Re-registering replaces
this plugin's previous list (it does not append).

### Unregister Ignore Pattern

```lua
_G.KOSyncthingPlusAPI.IgnoreRegistry:unregister(
    "my_plugin_id"
)
```

### Check if a plugin is registered

```lua
local registered = _G.KOSyncthingPlusAPI.IgnoreRegistry:isRegistered("my_plugin_id")
-- returns boolean
```

### Get all registered patterns

```lua
local patterns = _G.KOSyncthingPlusAPI.IgnoreRegistry:getAll()
-- returns { plugin_id = { "pattern", ... }, ... }
for id, list in pairs(patterns) do
    print(id, table.concat(list, ", "))
end
```

### Match a conflict filename

```lua
local hit = _G.KOSyncthingPlusAPI.IgnoreRegistry:matchesConflictBasename(
    "state.sync-conflict-20260101-120000-ABCDEFG.lua")
-- boolean: true if the de-mangled original matches a registered glob
```

Both conflict scanners (Kindle/daemon and Android) call this, so a registered
pattern is honoured identically on every platform.

### API version

```lua
local v = _G.KOSyncthingPlusAPI.IgnoreRegistry.getApiVersion()
-- returns the same version string as KOSyncthingPlusAPI.version
```

---

## Safety Guarantees

- All control methods use the same guards as the menu:
  - Double-start prevention
  - Wi-Fi checks
  - Shared safety logic

- The proxied `apiCall` never exposes the Syncthing API key

- Listener callbacks are wrapped in `pcall`
  - A broken companion plugin cannot crash Syncthing

- All API calls are synchronous and safe to invoke from:
  - Widget callbacks
  - Timers
  - Any normal KOReader Lua callback

> KOReader uses single-threaded LuaJIT execution.
