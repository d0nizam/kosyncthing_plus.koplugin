# Test Suite

506 tests across 16 spec files. No KOReader installation required — all
platform modules are stubbed by the mock layer.

## Setup

### Windows (one-command)

```powershell
.\spec\setup_windows.ps1
```

This does everything automatically: installs MinGW-w64 (C compiler) via
winget, installs LuaRocks standalone (bundles LuaJIT), installs the
`luafilesystem` rock, then runs all 16 spec files.

The script is idempotent — subsequent runs are much faster because
already-installed components are skipped.

### Windows (manual)

```powershell
# 1. MinGW-w64 (UCRT) — C compiler for Lua rocks
winget install -e --id BrechtSanders.WinLibs.POSIX.UCRT --accept-package-agreements

# 2. LuaRocks — download luarocks-3.12.2-windows-64.zip from
#    https://luarocks.github.io/luarocks/releases/
#    Extract and add to PATH.

# 3. Dependencies (only luafilesystem is needed)
luarocks install luafilesystem

# 4. Run all tests
foreach ($spec in Get-ChildItem spec\*_spec.lua) {
  luajit spec/run_tests.lua $spec.FullName
}
```

Notes:
- `luasocket`, `lua-cjson`, and `luajson` are **not** needed — HTTP tests use
  injectable `request_fn` fakes, and no JSON C extension is required.
- `lpeg` is **not** needed (no LuaRocks with C dependencies beyond lfs).

Without `winget`:
- Install MinGW-w64 manually from [winlibs.com](https://winlibs.com/)
  (UCRT variant, extract, add `mingw64\bin` to PATH), then follow steps 2-4.

### Linux (WSL / native)

```sh
sudo apt update
sudo apt install luajit luarocks
sudo luarocks install luafilesystem
for f in spec/*_spec.lua; do luajit spec/run_tests.lua "$f"; done
```

## Running

Once the dependencies are installed, run tests from the plugin root:

```sh
# Run one file
luajit spec/run_tests.lua spec/st_health_spec.lua

# Run everything (POSIX)
for f in spec/*_spec.lua; do luajit spec/run_tests.lua "$f"; done

# Run everything (Windows PowerShell)
foreach ($spec in Get-ChildItem spec\*_spec.lua) {
  luajit spec/run_tests.lua $spec.FullName
}
```

[Busted](https://lunarmodules.github.io/busted/) also works for all files
except `st_process_spec` (see below):

```sh
luarocks install busted
busted spec/st_health_spec.lua   # single file
busted spec                      # all files (skips st_process_spec)
```

### Expected output

```
st_android_spec.lua ... OK
st_api_public_spec.lua ... OK
...
Total time: 4.8s
Specs: 16, Passed: 16, Failed: 0
```

## Spec files

| File | What it covers | Tests |
|------|---------------|-------|
| `st_sync_spec.lua` | Quick Sync: scan failure, disk-space abort, folder-error detection during idle wait | 3 |
| `st_conflict_spec.lua` | Conflict auto-merge: file removal failure, path construction, `.sync-conflict` pattern matching, **`last_percent` fallback** (old KOReader format), **`has_progress` detection when only one side has a percent field**, **short device ID parsing and device-name resolution** (including daemon-down fallback and self-conflict detection); **`resolveConflict`**: unresolvable path warning, missing-original keep/discard branches, reading-progress percentage dialog (keep local / use conflict), generic file timestamp dialog, `conflict_is_mine` orientation for both the file and the reading-progress dialogs ("Keep incoming / Restore mine") | 47 |
| `st_health_spec.lua` | `getFolderHealth`: paused/error/syncing/idle state derivation, need-bytes accounting, per-folder error aggregation, **device-online count includes LAN and global peers, excluding only the local device by its own deviceID** (`isLocal` in Syncthing marks a LAN connection, not the local device) | 44 |
| `st_orchestrator_spec.lua` | Lifecycle orchestration: autostart/stop, manual toggle, periodic sync scheduling, suspend/resume, Wi-Fi lease cleanup, reconcile, **opt-in auto-merge after sync** (`runSyncCompleted`), **a session-only pause flag gates Autostart**, **`hasNetwork()` LAN-only and full-offline paths**, **disconnect→reconnect cycle**, **three-way Autostart mode (off/wifi/always): start gating, force-Wi-Fi only on "always", mode-gated network-disconnect and charging** | 55 |
| `st_timer_spec.lua` | Periodic timer cancellation through the public API | 1 |
| `st_guard_spec.lua` | Named lease idempotency, standby/wakelock balance, exception-path release | 25 |
| `st_utils_spec.lua` | Path helpers, `isTransientFolderError`, `formatTime`, `getFriendlySize`, settings key catalogue, loopback detection, **`detectArch`** (LuaJIT path, `uname -m` fallback, unknown/failure cases) | 65 |
| `st_android_spec.lua` | `androidApiCall` contract: status codes, JSON decode, error recording, TLS flag propagation; **IgnoreRegistry scanner wiring** (exclusion predicate seam, both `.`/`~` separators) | 25 |
| `st_datadir_spec.lua` | Data-directory selection, legacy-path migration, FAT/FUSE detection | 11 |
| `st_filesystem_spec.lua` | Safe-delete guard, dangerous-path rejection, conflict-file scanning, archive extraction | 36 |
| `st_api_spec.lua` | `SafeClient` HTTP layer: GET/PUT/PATCH routing, error capture, cache invalidation | 33 |
| `st_legacy_spec.lua` | Legacy-mode gate (`needsPatch`), `downloadBinary` URL/arch construction, archive validation (`fileSize`, `isGzip`, `isELF`), atomic staging install, `patchSyncthingObject` read-modify-write shim, **procfs kernel-detection fallback** (`/proc/sys/kernel/osrelease`, `/proc/version`) when `uname` is unavailable | 73 |
| `st_process_spec.lua` | Binary lifecycle: `start`, `stop`, `kindlePortGuard`, Kindle UDP port guards, `binaryExists` (ELF check), `isRunning`, `safeHomeDir`, `applyNetworkSettings`, `stopPlugin`, **Autostart pause (session-only flag) set only on manual stop, cleared on start, absent on automatic/suspend stops** | 56 |
| `st_api_public_spec.lua` | `IgnoreRegistry` companion API: `register` (single string or list, all-or-nothing validation, de-dup, **replace** semantics, idempotent generation bumps, apostrophe globs), `getAll` returns an independent copy, `unregister`/`isRegistered`, and **`matchesConflictBasename`** (de-mangles a conflict copy to its original and matches registered globs — exact names, `*` globs, both `.`/`~` separators, multi-dot originals, the conflict-copy gate, stray legacy values) | 16 |
| `st_plugin_update_spec.lua` | Plugin self-updater pure logic: `parseVersion`/`isNewer` (numeric semver, differing component counts), `selectAsset` (release `.zip` asset vs `zipball_url` fallback and the strip-root flag), `stripMarkdown`, `getInstalledPluginVersion`, and a guard that the module hard-codes no `/tmp` path (not writable on Android) | 13 |
| `st_update_download_spec.lua` | `downloadFile` LuaSocket transport: **no double-close** of the handle on success (`socketutil.file_sink` already closes it), partial-file removal + defensive close when `http.request` raises, non-200 returns false | 3 |
| **Total** | | **506** |

### Note on `st_process_spec` and Busted

`st_process_spec` passes cleanly under `run_tests.lua` but hangs under
Busted (Lua 5.1). The cause is a Busted-specific sandboxing interaction with
`io.popen` — Busted's environment isolation prevents the spec's `stubIO()`
mock from intercepting `io.popen` calls made by `st_process.lua` before the
first `before_each` fires. The plain runner in `run_tests.lua` does not use
`setfenv` isolation and does not have this problem.

## Infrastructure

| File | Role |
|------|------|
| `spec_helper.lua` | Sets `package.path` and calls `Mock.install()` |
| `mock_koreader.lua` | Stubs `UIManager`, `NetworkMgr` (including `isConnected` and `isOnline`), `Device`, `G_reader_settings`, all widgets, `util`, `ffi/util`, timer scheduling, and `dkjson`/`json` |
| `dkjson.lua` | Bundled pure-Lua JSON library used by specs that need real JSON decoding |
| `run_tests.lua` | Minimal Busted-compatible runner; works under plain Lua 5.1/5.3/5.4/LuaJIT without luarocks. Patches `os.execute`/`io.open`/`io.popen` on Windows for cross-platform `mkdir -p`/`rm -rf`/`find` compatibility |
| `setup_windows.ps1` | One-command Windows setup script: installs MinGW-w64, LuaRocks, and `luafilesystem` |

### Design rules

- Each spec file is **self-contained**: it installs only the mock surface it
  actually needs. Accidental dependencies on unrelated globals remain visible
  as immediate errors rather than silent passes.
- `spec_helper.lua` / `mock_koreader.lua` provide the shared baseline.
  Specs that need narrower or conflicting behaviour override individual
  `package.loaded` entries before calling `require()`.
- `Mock.state.wifi_connected` controls `NetworkMgr:isConnected()` independently
  of `wifi_online`. When `nil` (the default), `isConnected()` mirrors
  `wifi_online`; set it to `true` to simulate a LAN-only network (IP
  association without an internet route), or `false` to simulate a network
  that is fully down even after `enableWifi` is called (combine with
  `wifi_auto_callback = false` so the enable callback does not fire).
- `detectArch` tests control `package.loaded["jit"]` directly (not `_G.jit`)
  because `detectArch` uses `pcall(require, "jit")` which reads the module
  cache, not the global — this matters when running under `texlua`/LuaTeX
  where the real `jit` module is already cached at startup.
- `st_legacy_spec` and `st_process_spec` stub new `st_utils` helpers
  (`fileSize`, `isGzip`, `isELF`, `kindleOpenPortUDP`, `kindleClosePortUDP`)
  as controllable fakes. Defaults represent the happy path so existing tests
  are unaffected; tests that exercise a specific failure path override via
  `FAKE.*` fields (e.g. `FAKE.is_gzip = false`).
- No network access, no filesystem writes, no real processes are started.
