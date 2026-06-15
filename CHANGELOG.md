# Changelog

## [v1.1.8] — 2026-06-15

### Fixed
- **"No devices online" while devices were actually connected.** The
  device-online count shown in the header and in *Status & conflicts* treated
  Syncthing's `isLocal` connection flag as "this entry is the local device" and
  excluded it. But `isLocal` actually marks a connection made over the **local
  network (LAN)** — so every peer on the same Wi-Fi was excluded, and the count
  read "no devices online" even though the device list showed them all
  connected. (A peer reached over the internet/relay reports `isLocal=false`, so
  it *was* counted — meaning the same device dropped in and out of the count as
  it moved between a LAN and a global connection.) The local device is now
  identified by its device ID only, so LAN and global peers are both counted.
- **The error header now takes you straight to the problem.** Tapping the
  "⚠ Error in N folders" header used to open *Status & conflicts* rendered as a
  bare list without the normal nested navigation. It now opens the erroring
  folder's dialog directly — or, when several folders have errors, a short list
  of just those folders — mirroring how tapping a conflict opens its resolver.

### Added
- **"Explain the error" button on folder errors.** When a folder has a
  non-transient error, its dialog now offers a plain-language explanation of
  what happened, why, and what to do, tailored to the kind of error: a remote
  deletion blocked by ignored files, out of disk space, no write permission, a
  missing path or `.stfolder` marker, or a generic fallback. The original
  Syncthing message is included. For the ignored-files case it points to
  deleting the folder from a file manager (warning that the files inside go
  too) and clarifies that *Remove folder* only stops tracking without deleting.

### Changed
- **Android: the plugin-update item is now labelled "Check for updates"** rather
  than "Check for plugin updates". Remote mode has no plugin-managed Syncthing
  binary, so there is nothing to disambiguate from. Kindle/Kobo keep "Check for
  plugin updates" (it sits next to the binary updater).
- **The device-connection count refreshes immediately after a sync,** so a peer
  that connected or dropped during the sync is reflected without waiting for the
  short connection cache to expire.

## [v1.1.7] — 2026-06-15

### Fixed
- **The plugin updater now works on Android.** v1.1.6 added a *Check for plugin
  updates* item to the Android remote-mode menu, but the updater wrote its
  downloaded release metadata to a hardcoded `/tmp/…` path, which does not exist
  on Android — so every check failed immediately with "No such file or
  directory" and reported "Could not check for updates". That temporary file now
  lives in the plugin folder (where the downloaded update archive already goes),
  so the check works on Android the same as on Kindle/Kobo. (Android has no
  `curl`/`wget` either, so the updater always uses KOReader's built-in network
  stack there — which now has a writable place for its temporary file.)

## [v1.1.6] — 2026-06-14

### Added
- **Update the plugin itself from GitHub.** Maintenance → **Check for updates** is
  now a submenu with **Update Syncthing binary** (the existing binary updater) and
  a new **Check for plugin updates**. The latter checks the plugin's GitHub
  releases, shows the release notes, downloads the new version and unpacks it in
  place, then offers to restart KOReader. Your settings, paired devices and the
  downloaded Syncthing binary are preserved. It prefers the release's install-zip
  asset and falls back to the source archive when none is attached.
- **Android remote mode can update the plugin too.** The dedicated Android menu
  now includes **Check for plugin updates**. Remote mode has no plugin-managed
  Syncthing binary, so there is no "Update Syncthing binary" item there — only
  the plugin updater, with help text that reflects the remote-mode setup.

### Fixed
- **The conflict menu no longer crashes on open.** Tapping **Status & conflicts**
  with one or more conflicts present could crash with an `ipairs(nil)` error in
  KOReader's `touchmenu.lua`. The conflict screens are flat item lists, so they
  now use KOReader's `Menu` widget instead of `TouchMenu` (which expects tabbed
  `tab_item_table` input).
- **`~`-separated conflict files are now detected.** Syncthing writes a conflict
  copy as either `name.sync-conflict-….ext` or `name~sync-conflict-….ext`; both
  scanners previously matched only the `.` form, so `~` conflicts were never
  surfaced (nor de-mangled on resolve). Both separators are handled everywhere now.
- **Auto-merge no longer runs while a book is open.** Reading-progress auto-merge
  (after Quick Sync, or the manual *Auto-merge progress* action) replaces a
  KOReader metadata sidecar on disk when the remote copy has higher progress. If
  that book is currently open, KOReader holds the sidecar (reading position and
  annotations) in memory and rewrites it on its next save — autosave, suspend, or
  close — with no external-change detection, so it would silently overwrite the
  merged-in progress and consume the conflict file so the conflict never
  reappeared. Auto-merge now defers the whole pass while any book is open; the
  conflicts are resolved on a later scan after the Reader is closed, when the
  on-disk sidecars are authoritative again.
- **The "devices online" count no longer includes this device.** Syncthing's
  `/system/connections` lists the local device itself (marked `isLocal`, keyed
  by the local device ID), so the status header and the Status submenu reported
  one device too many — e.g. "1/2 devices online" with a single online peer. The
  local device is now excluded from the count (by `isLocal`, falling back to a
  device-ID match for older daemons that predate that field).
- **Updates no longer crash on the LuaSocket fallback.** When neither curl nor
  wget could complete a GitHub request — e.g. an e-reader whose BusyBox wget
  cannot negotiate the `api.github.com` TLS — the download fell through to
  KOReader's built-in LuaSocket transport, which crashed with "attempt to use a
  closed file". KOReader's `socketutil.file_sink` closes the file handle itself
  when the request ends, and the code then closed it a second time. The
  redundant close is now defensive, so the LuaSocket path returns its result (or
  a clean error) instead of crashing. This affects both the Syncthing binary
  updater and the plugin updater, on any device that lacks a working curl/wget.

### Changed
- **IgnoreRegistry: a companion may register a LIST of patterns** (not just a
  single one), and the call REPLACES that plugin's set. A conflict copy is now
  matched by de-mangling it to its original name and testing the registered
  globs, so a companion registers plain names/globs (`state.lua`, `*.sdr`)
  without encoding Syncthing's `.sync-conflict-…` form. Both conflict scanners
  share this one matcher, which excludes only genuine conflict copies (a file
  that merely contains the text, with no `.`/`~` separator, is left alone). The companion API version is now `1.1.0`.
- **Enabling auto-merge now requires an explicit double confirmation** (on every
  device, including Android), mirroring the factory-reset flow. The first dialog
  spells out that the winner is chosen by reading position only — so a copy that
  is further ahead can overwrite annotations held by a copy that is not the
  furthest-read — with a concrete two-device example; a second dialog is the
  final confirm. Disabling stays a single tap.
- **More robust kernel detection for Legacy mode.** `kernelState()` still tries
  `uname -r` first, then falls back to the kernel's own procfs files
  (`/proc/sys/kernel/osrelease`, then `/proc/version`), so a stripped e-ink
  firmware with no `uname` binary is still classified instead of falling through
  to "unknown". KOReader already relies on procfs for device detection, so it is
  present wherever the plugin runs.
- **Legacy Syncthing is discoverable on an unprobeable kernel.** When the kernel
  version cannot be determined, the Legacy entry is shown neutrally (no ⚠) rather
  than hidden, so the rare old-but-unprobeable e-reader can still find it without
  implying a modern device needs to downgrade. The ⚠ now appears only for a
  genuinely old kernel.
- **Start-timeout guidance matches the likely cause.** On a start timeout an old
  kernel is pointed at Legacy mode; any other device is pointed at re-installing
  the binary (Maintenance → Check for updates, or a manual download) rather than
  presuming a kernel problem.
- Removed dead `syncthing_start_failed` machinery (a flag that was read and
  cleared but never set, plus three comments describing a writer that did not
  exist); the key is retained only in the reset list so a factory reset still
  clears any value left by an older version.

### Documentation
- README: the UI-string table and the menu tree show real singular/plural forms
  instead of the `(s)` shorthand; the IgnoreRegistry overview documents pattern
  lists and conflict-copy matching.
- API.md: `IgnoreRegistry:register` documents list input and replace semantics,
  `getAll` returns `{ plugin_id = { pattern, … } }`, and the new
  `matchesConflictBasename` method is described.
- README: the Android (remote mode) section documents the plugin self-updater
  (and why there is no binary updater there).
- spec/README: the test catalogue is updated to 508 tests across 16 spec files,
  adding the plugin-updater logic spec and the download-transport regression spec.

## [v1.1.5] — 2026-06-08

### Changed
- **New optional Start mode** replaces the single **Autostart Syncthing**
  on/off toggle. It offers two mutually exclusive automatic modes, and neither
  is on by default — without one, Syncthing runs only when you start it by
  hand or via Quick Sync/Periodic Sync:
  - **When Wi-Fi is on** — follows Wi-Fi: starts when Wi-Fi is already on,
    stops when it goes off, and never turns Wi-Fi on by itself.
  - **Always (brings Wi-Fi up)** — the previous behaviour: keeps Syncthing
    running whenever possible, turning Wi-Fi on when needed.
  Tapping the selected mode again turns it off. An existing "Autostart on"
  setting maps to **Always**.
- **Count-aware UI strings** — every message containing a number now uses proper
  singular/plural forms (`ngettext`) instead of the old "folder(s)" style. English
  reads naturally at any count ("1 folder up to date" / "5 folders up to date"),
  and Bulgarian uses the correct counting forms with verb/adjective agreement.

### Fixed
- **A Wi-Fi disconnect no longer stops a manually started daemon** when no
  start mode is selected — automatic stop-on-disconnect applies only to the
  Wi-Fi-coupled modes ("When Wi-Fi is on" / "Always").

### Documentation
- README overhaul: the **Status & conflicts** menu is documented as its current
  three-door layout (Folders / Devices / Conflicts); the settings reference now
  lists every `syncthing_*` key; the **Start mode** section and menu tree
  describe the two modes; the companion-API overview lists the periodic-sync
  and settings/legacy methods.
- API.md: clarified that `resolveConflictByPath` accepts only `keep_local` / `use_remote` (auto-merge is available on the bulk `resolveAllConflicts` only).
- Bulgarian translation completed (all UI strings translated).

### Development
- **`make build`** produces the clean install zip (runtime files only — tests,
  tools, and docs excluded).
- The translation tool (`tools/i18n.py`) now extracts `N_("one", "other", n)`
  plural calls and maintains the `Plural-Forms` header, alongside `_("...")`.

## [v1.1.4] — 2026-06-08

### Changed
- **Manual Stop is now session-only** — Syncthing starts again on the next
  KOReader launch; only turning off the Autostart toggle stops it for good.
- **Conflict list shows readable names** — book/file name and detection time
  instead of the raw `…sync-conflict-…` filename.
- **Redesigned Copy diagnostic info** — labelled sections and aligned columns;
  fixes wrapped/doubled separators on Kindle.

### Fixed
- **Reading-progress conflicts no longer swap "Mine" and "Theirs"** when this
  device wrote the moved-aside copy — the dialog now offers **Keep incoming** /
  **Restore mine** with the correct percentages.
- Conflict-resolution messages are now orientation-aware.
- Missing reading percentage shows **unknown** instead of **no date**.
- **Autostart now starts on a cold launch.**
- **Android: auto-merge after Rescan waits for the rescan to land** instead of
  running before any conflicts exist.

### Removed
- Dead `SyncthingStateChanged` event (no listener; the broadcasts did nothing).
  `SyncthingSyncCompleted` and `SyncthingConflictDetected` are unchanged.

## [v1.1.3] — 2026-06-07

### Added
- Richer **Copy diagnostic info** — binary ELF check, process RSS/threads/CPU,
  filesystem type & free space, network loopback & Kindle firewall ports
  (22000 TCP, 21027 UDP), folder/device counts.
- Kindle firewall now opens TCP 22000 (sync) and UDP 21027 (discovery)
  automatically, fixing pairing issues.
- **Autostart respects manual pause** — manually stopping Syncthing from the
  menu now pauses Autostart until you start it again. Previously Autostart
  would immediately restart the daemon after a manual stop.
- **LAN-only network support** — Autostart and sync timers now use
  `NetworkMgr:isConnected()` (has IP association) before falling back to
  `isOnline()` (has internet route). Syncthing can sync on local networks
  without internet access.

### Changed
- Binary download validates ELF & gzip magic and enforces a minimum file size
  before extraction.
- Binary installation is atomic (`.new` file replaced only after ELF check).
- Notifications say "network unavailable / disconnected" instead of
  "Wi‑Fi unavailable / disconnected" to match the new LAN-only behaviour.

### Fixed
- Text file named `syncthing` (Kobo app‑stream metadata) no longer accepted as
  a valid binary.
- Curl is tried before wget for more reliable GitHub downloads.
- Architecture detection now uses a single shared helper
  (`st_utils.detectArch`).
  
- **Autostart no longer breaks after network loss.** Automatic stops
  (network disconnect, app close) were incorrectly setting the `user_paused`
  flag, causing Autostart to stay disabled after reconnecting or restarting
  the app. Only an explicit manual stop now sets the flag.
  
- **Conflict dialog no longer shows "unknown" for older devices.** Older
  KOReader builds (pre-2022) write `last_percent` instead of
  `percent_finished`; both fields are now recognised when reading progress
  from metadata sidecar files.
- **Conflict dialog now appears when only one side has a percent field.**
  Previously the "reading progress conflict" dialog was suppressed when the
  conflict copy lacked `percent_finished` even though the local copy had it
  (or vice versa). The dialog now opens whenever either side carries progress
  data, showing the known percentage and "unknown" only for the side that
  genuinely has none.
- **`getConflictsDetailed` now reports `has_progress = true` when at least
  one side has a percent field** (previously required both sides). This
  affects the auto-merge menu display and any companion plugins that read
  conflict metadata.

## [v1.1.2] — 2026-06-06

### Added
- **Auto-merge conflicts after sync** — Android remote mode, menu.

## [v1.1.1] — 2026-06-06

### Added
- **Auto-merge conflicts after sync** — opt-in checkbox in `Automation` menu.
  After every Quick Sync, reading-progress conflicts are merged automatically
  (higher `percent_finished` wins). Off by default.

### Fixed
- Architecture detection unified into a single helper (`st_utils.detectArch`).
  LuaJIT is tried first, `uname -m` as fallback. Fixes potential mismatch on
  Libra Colour and similar devices where the two previous independent parsers
  (in `st_update.lua` and `legacy.lua`) could disagree.
- `InfoMessage` was used in `main.lua` without a local `require`, relying on
  load-order side effects. Now required explicitly.

---

## [v1.1.0] — 2026-05-01

Initial public release.

- **Quick Sync** — one-tap sync with automatic Wi-Fi on/off, disk-space check,
  progress notifications, and transfer summary.
- **Autostart & Periodic Sync** — background daemon management with Wi-Fi
  awareness, exponential backoff, and a charging gate.
- **Conflict resolution** — scan, auto-merge reading progress, keep-local, or
  use-remote; per-file and bulk actions.
- **Folder & device management** — pause, rescan, add/remove via the KOReader
  menu without opening the Syncthing web UI.
- **Pairing wizard** — guided setup for adding new devices.
- **Legacy mode** — runs an older Syncthing binary (v1.27.12 or v1.2.2) on
  devices with kernels ≤ 3.1 (Kindle PW2/PW3, Kobo Touch 2, etc.).
- **Android remote mode** — connects to an existing Syncthing app on Android
  instead of managing a local daemon.
- **Binary auto-update** — checks GitHub Releases and downloads the correct
  architecture binary over Wi-Fi.
- **Companion plugin API** — public Lua API for other KOReader plugins to
  query status and trigger sync actions.
- **Bulgarian translation** (`bg.po`).
