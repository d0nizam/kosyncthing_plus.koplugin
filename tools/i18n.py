#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
i18n.py — translation maintenance for the KOSyncthing+ KOReader plugin.

ONE tool for everything related to the plugin's gettext-style locale files
(locale/syncthing.pot and locale/<lang>.po). It is built on `polib` for robust,
spec-correct .po reading/writing, plus a small Lua-aware extractor for the
plugin's own `_("...")` calls — something xgettext cannot do (it has no Lua mode).

    Requires: python3 + polib   (pip install polib --break-system-packages)
    Optional: a `lua` interpreter — enables a ground-truth cross-check that every
              translation actually resolves under the real syncthing_i18n parser.

Subcommands
-----------
  check    Validate source vs .pot vs every .po and exit non-zero on problems.
           Reports: strings in code but missing from .pot/.po (new), strings in
           the files but not in code (obsolete), untranslated/empty msgstr,
           duplicate msgids, CRLF bytes, and — if `lua` is available — confirms
           each .po resolves under syncthing_i18n.parsePO. Read-only.
  sync     Make the locale files match the source: rebuild .pot from the extracted
           msgids (with #: refs), then merge into every .po preserving existing
           translations and adding new (empty) entries. Use --prune to drop
           obsolete entries (default: keep + report them).
  refs     Refresh only the #: source references (use when code moved but the
           strings themselves did not change).
  reword   Carry a translation across a string edit. --map "OLD=NEW" rewrites the
           msgid in the .lua source, the .pot and every .po, keeping the msgstr.
           Repeatable. Use --from-file FILE for many (one OLD=NEW per line).
  stats    Print translated / untranslated counts per language.

Design / conventions honoured
------------------------------
  * msgids are taken ONLY from `_(...)` — the plugin's gettext alias
    (`local _ = require("syncthing_i18n").gettext`). `..` concatenation across
    lines and \\n \\t \\r \\" \\\\ escapes are handled.
  * the source is comment-stripped (a tiny Lua lexer that preserves strings,
    long-bracket strings and line numbers) before scanning, so a commented-out
    or quoted `_(` is never mistaken for a real string.
  * entries are written msgid-sorted with wrapped #: lines, matching the file
    style already in the repo.
  * CRLF is kept at 0 (the loader and KOReader both expect LF-only).

The first `sync`/`refs` run may reformat a few entries to one canonical style
(e.g. normalising single-line vs multi-line msgids). `check --lua` proves the
result parses to the SAME map as before, so the reformat is behaviour-preserving.
"""

import argparse
import datetime
import difflib
import os
import re
import shutil
import subprocess
import sys
import tempfile

try:
    import polib
except ImportError:
    sys.exit("error: polib is required.  Install it with:\n"
             "    pip install polib --break-system-packages")

# --------------------------------------------------------------------------- #
# Paths
# --------------------------------------------------------------------------- #
# tools/i18n.py  ->  plugin root is the parent of this file's directory.
PLUGIN_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCALE_DIR  = os.path.join(PLUGIN_ROOT, "locale")
POT_PATH    = os.path.join(LOCALE_DIR, "syncthing.pot")

# Directories whose .lua files never contain user-facing `_()` strings.
SKIP_DIRS = {"spec", "tools", ".git"}

PO_WRAPWIDTH = 0    # polib: 0 = do NOT wrap msgid/msgstr (keep them off the
                    # canonical 79-col split, matching the repo's long single
                    # lines). #: reference lines are re-wrapped separately below.
REF_WIDTH    = 79   # wrap #: source-reference lines at this column (GNU style)


# --------------------------------------------------------------------------- #
# Lua source handling
# --------------------------------------------------------------------------- #
def strip_lua_comments(src):
    """Return `src` with every comment replaced by spaces/newlines.

    String literals (short '...' / "..." and long [[ ... ]] / [==[ ... ]==]) are
    preserved verbatim.  Comment bytes become spaces and embedded newlines are
    kept, so byte offsets and line numbers stay identical to the original — which
    is what lets the extractor report accurate file:line references.
    """
    out = []
    i, n = 0, len(src)

    def blank(text):
        # keep newlines, turn everything else into spaces (preserves line numbers)
        return "".join("\n" if c == "\n" else " " for c in text)

    while i < n:
        c = src[i]

        # short string
        if c == '"' or c == "'":
            q = c
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == q:
                    j += 1
                    break
                if src[j] == "\n":      # unterminated; bail defensively
                    break
                j += 1
            out.append(src[i:j])
            i = j
            continue

        # long bracket — string OR comment opener  [[ , [=[ , [==[ ...
        if c == "[":
            m = re.match(r"\[(=*)\[", src[i:])
            if m:
                level = m.group(1)
                close = "]" + level + "]"
                end = src.find(close, i + len(m.group(0)))
                end = (end + len(close)) if end != -1 else n
                out.append(src[i:end])   # long string is content — keep it
                i = end
                continue

        # comment
        if c == "-" and i + 1 < n and src[i + 1] == "-":
            # long comment?  --[[ ... ]]  /  --[==[ ... ]==]
            m = re.match(r"--\[(=*)\[", src[i:])
            if m:
                level = m.group(1)
                close = "]" + level + "]"
                end = src.find(close, i + len(m.group(0)))
                end = (end + len(close)) if end != -1 else n
                out.append(blank(src[i:end]))
                i = end
                continue
            # line comment -> to end of line (keep the newline)
            end = src.find("\n", i)
            end = end if end != -1 else n
            out.append(blank(src[i:end]))
            i = end
            continue

        out.append(c)
        i += 1

    return "".join(out)


_LUA_ESC = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b",
            "f": "\f", "v": "\v", "\\": "\\", '"': '"', "'": "'", "\n": ""}


def lua_unescape(raw):
    """Unescape a Lua short-string literal body to its real string value."""
    out = []
    i, n = 0, len(raw)
    while i < n:
        c = raw[i]
        if c != "\\":
            out.append(c)
            i += 1
            continue
        nxt = raw[i + 1] if i + 1 < n else ""
        if nxt == "x":                       # \xHH — may be a multi-byte UTF-8 run
            # Collect consecutive \xHH escapes and decode them together as UTF-8,
            # so a sequence like \xe2\x80\x93 round-trips to – (U+2013) rather than
            # three Latin-1 code points whose re-encoded bytes never match the key
            # Lua produces at runtime. An invalid byte run falls back to per-byte.
            j = i
            buf = bytearray()
            while j + 3 < n and raw[j] == "\\" and raw[j + 1] == "x":
                buf.append(int(raw[j + 2:j + 4], 16))
                j += 4
            if buf:
                try:
                    out.append(buf.decode("utf-8"))
                except UnicodeDecodeError:
                    out.extend(chr(b) for b in buf)
                i = j
            else:                            # malformed \x — keep original behaviour
                out.append(chr(int(raw[i + 2:i + 4], 16)))
                i += 4
        elif nxt.isdigit():                  # \ddd decimal byte — same multi-byte rule
            j = i
            buf = bytearray()
            while j < n and raw[j] == "\\" and j + 1 < n and raw[j + 1].isdigit():
                k = j + 1
                while k < n and k < j + 4 and raw[k].isdigit():
                    k += 1
                v = int(raw[j + 1:k])
                if v > 255:                  # not a byte (invalid Lua); stop the run
                    break
                buf.append(v)
                j = k
            if buf:
                try:
                    out.append(buf.decode("utf-8"))
                except UnicodeDecodeError:
                    out.extend(chr(b) for b in buf)
                i = j
            else:                            # \ddd > 255 — keep original behaviour
                k = i + 1
                while k < n and k < i + 4 and raw[k].isdigit():
                    k += 1
                out.append(chr(int(raw[i + 1:k])))
                i = k
        else:
            out.append(_LUA_ESC.get(nxt, nxt))
            i += 2
    return "".join(out)


def _read_string_literal(s, i):
    """If s[i] starts a Lua string literal — short '...'/"..." or long
    [[...]]/[=[...]=]/[==[...]==] — return (value, index_after). Otherwise
    (None, i). Short strings are unescaped; long-bracket strings are verbatim."""
    if i >= len(s):
        return None, i
    c = s[i]
    if c in ('"', "'"):
        q = c
        j = i + 1
        buf = []
        while j < len(s):
            if s[j] == "\\":
                buf.append(s[j:j + 2])
                j += 2
                continue
            if s[j] == q:
                j += 1
                break
            buf.append(s[j])
            j += 1
        return lua_unescape("".join(buf)), j
    m = re.match(r"\[(=*)\[", s[i:])
    if m:
        close = "]" + m.group(1) + "]"
        start = i + len(m.group(0))
        if start < len(s) and s[start] == "\n":   # Lua drops a leading newline
            start += 1
        end = s.find(close, start)
        if end == -1:
            return None, i
        return s[start:end], end + len(close)      # long strings: no unescape
    return None, i


def extract_calls(src):
    """Yield (msgid, lineno) for every `_( "..."[ .. "..."] )` call in `src`
    (which must already be comment-stripped).

    The scan walks character by character and SKIPS over string literals, so a
    `_(` that appears inside the text of some other string is never mistaken for
    a call. `..` concatenation (short and/or long-bracket pieces) is followed
    across whitespace and newlines."""
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        # Skip any code string literal so its contents are not scanned.
        if c in ('"', "'") or re.match(r"\[=*\[", src[i:]):
            val, j = _read_string_literal(src, i)
            if val is not None and j > i:
                i = j
                continue
            i += 1
            continue
        # Standalone gettext call: `_(` not preceded by an identifier char/'.'/':'.
        if c == "_" and i + 1 < n and src[i + 1] == "(":
            prev = src[i - 1] if i > 0 else ""
            if not (prev.isalnum() or prev in "_.:"):
                lineno = src.count("\n", 0, i) + 1
                k = i + 2
                parts, ok = [], True
                while True:
                    while k < n and src[k] in " \t\r\n":
                        k += 1
                    val, j = _read_string_literal(src, k)
                    if val is None:
                        ok = False
                        break
                    parts.append(val)
                    k = j
                    while k < n and src[k] in " \t\r\n":
                        k += 1
                    if src[k:k + 2] == "..":
                        k += 2
                        continue
                    if k < n and src[k] == ")":
                        break
                    ok = False
                    break
                if ok and parts:
                    yield "".join(parts), lineno
                    i = k + 1
                    continue
        i += 1


def collect_from_sources(root):
    """Scan every runtime .lua file under `root`; return {msgid: [ 'file:line', ... ]}
    with refs sorted by (file, line)."""
    refs = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in sorted(filenames):
            if not fn.endswith(".lua"):
                continue
            path = os.path.join(dirpath, fn)
            rel = os.path.relpath(path, root).replace("\\", "/")
            with open(path, encoding="utf-8") as fh:
                src = strip_lua_comments(fh.read())
            for msgid, line in extract_calls(src):
                if not msgid:
                    continue
                refs.setdefault(msgid, []).append((rel, line))
    out = {}
    for msgid, occ in refs.items():
        occ = sorted(set(occ), key=lambda t: (t[0], t[1]))
        out[msgid] = ["%s:%d" % (f, l) for f, l in occ]
    return out


def _read_concat(src, k):
    """From index k, read a run of `"..".."..."` string literals separated by
    `..` (whitespace allowed). Returns (joined_value or None, index_after)."""
    n = len(src)
    parts = []
    while True:
        while k < n and src[k] in " \t\r\n":
            k += 1
        val, j = _read_string_literal(src, k)
        if val is None:
            return (("".join(parts)) if parts else None), k
        parts.append(val)
        k = j
        while k < n and src[k] in " \t\r\n":
            k += 1
        if src[k:k + 2] == "..":
            k += 2
            continue
        return "".join(parts), k


def extract_plural_calls(src):
    """Yield (singular, plural, lineno) for every `N_( "..", ".." )` call in
    `src` (comment-stripped). String literals are skipped so an `N_(` inside a
    string is never mistaken for a call; each argument may be `..`-concatenated."""
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c in ('"', "'") or re.match(r"\[=*\[", src[i:]):
            val, j = _read_string_literal(src, i)
            if val is not None and j > i:
                i = j
                continue
            i += 1
            continue
        if c == "N" and src[i + 1:i + 3] == "_(":
            prev = src[i - 1] if i > 0 else ""
            if not (prev.isalnum() or prev in "_.:"):
                lineno = src.count("\n", 0, i) + 1
                a1, k = _read_concat(src, i + 3)
                if a1 is not None and k < n and src[k] == ",":
                    a2, k = _read_concat(src, k + 1)
                    if a2 is not None and k < n and src[k] in ",)":
                        yield a1, a2, lineno
                        i = k + 1
                        continue
        i += 1


def collect_plurals(root):
    """Scan runtime .lua files; return ({singular: plural}, {singular: ['f:l', ...]})
    for every N_() plural call."""
    pmap, prefs = {}, {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in sorted(filenames):
            if not fn.endswith(".lua"):
                continue
            path = os.path.join(dirpath, fn)
            rel = os.path.relpath(path, root).replace("\\", "/")
            with open(path, encoding="utf-8") as fh:
                src = strip_lua_comments(fh.read())
            for sing, plur, line in extract_plural_calls(src):
                if not sing:
                    continue
                pmap[sing] = plur
                prefs.setdefault(sing, []).append((rel, line))
    out = {}
    for sing, occ in prefs.items():
        occ = sorted(set(occ), key=lambda t: (t[0], t[1]))
        out[sing] = ["%s:%d" % (f, l) for f, l in occ]
    return pmap, out


def collect_all(root):
    """Singular refs (from _()) merged with plural-singular refs (from N_()),
    plus the {singular: plural} map. Returns (code, plurals)."""
    def _key(r):
        f, _, l = r.rpartition(":")
        try:
            return (f, int(l))
        except ValueError:
            return (f, 0)
    code = collect_from_sources(root)
    pmap, prefs = collect_plurals(root)
    for sing, refs in prefs.items():
        merged = list(code.get(sing, []))
        for r in refs:
            if r not in merged:
                merged.append(r)
        code[sing] = sorted(set(merged), key=_key)
    return code, pmap


# --------------------------------------------------------------------------- #
# polib helpers
# --------------------------------------------------------------------------- #
def po_paths():
    return sorted(p for p in
                  (os.path.join(LOCALE_DIR, f) for f in os.listdir(LOCALE_DIR))
                  if p.endswith(".po"))


def load_po(path):
    po = polib.pofile(path, wrapwidth=PO_WRAPWIDTH)
    po.wrapwidth = PO_WRAPWIDTH
    return po


def occurrences_for(msgid_refs, msgid):
    """polib wants occurrences as (file, line) tuples."""
    out = []
    for ref in msgid_refs.get(msgid, []):
        f, _, l = ref.rpartition(":")
        out.append((f, l))
    return out


def write_po(po, path):
    po.wrapwidth = PO_WRAPWIDTH
    po.save(path)            # entry order preserved (no re-sort => no churn)
    _rewrap_refs(path)
    _strip_crlf(path)


def _rewrap_refs(path, width=REF_WIDTH):
    """Re-wrap '#:' source-reference lines at `width` columns (GNU style), to
    match the repo's existing layout — polib writes all refs on a single line."""
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    out, i = [], 0
    while i < len(lines):
        if lines[i].startswith("#:"):
            refs = []
            while i < len(lines) and lines[i].startswith("#:"):
                refs.extend(lines[i][2:].split())
                i += 1
            cur = "#:"
            for r in refs:
                if cur != "#:" and len(cur) + 1 + len(r) > width:
                    out.append(cur)
                    cur = "#: " + r
                else:
                    cur = cur + " " + r
            out.append(cur)
        else:
            out.append(lines[i])
            i += 1
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(out))


def _insert_sorted(po, entry):
    """Insert `entry` at its msgid-sorted position (the files are msgid-sorted)."""
    for idx, e in enumerate(po):
        if e.msgid and e.msgid > entry.msgid:
            po.insert(idx, entry)
            return
    po.append(entry)


def reconcile(po, code, is_pot, prune, plurals=None):
    """Bring `po` in line with the source `code` ({msgid: [refs]}) IN PLACE:
    refresh occurrences, insert new msgids in sorted position, drop obsolete
    entries (always for a .pot; for a .po only when `prune`), and keep each
    entry's plural-ness in step with `plurals` ({singular: plural}). Unchanged
    entries keep their position, so a no-op run produces a minimal diff. Returns
    (added, obsolete_msgids)."""
    plurals = plurals or {}
    code_ids = set(code)
    obsolete = []
    for e in list(po):
        if not e.msgid:
            continue
        if e.msgid in code_ids:
            e.occurrences = occurrences_for(code, e.msgid)
            if e.msgid in plurals:
                if not e.msgid_plural:
                    e.msgid_plural = plurals[e.msgid]
                    if e.msgstr and not e.msgstr_plural:
                        e.msgstr_plural = {0: e.msgstr, 1: ""}
                        e.msgstr = ""
                    elif not e.msgstr_plural:
                        e.msgstr_plural = {0: "", 1: ""}
                elif e.msgid_plural != plurals[e.msgid]:
                    e.msgid_plural = plurals[e.msgid]
            elif e.msgid_plural:
                # No longer plural in the source — demote, keeping form 0.
                e.msgstr = (e.msgstr_plural or {}).get(0, "")
                e.msgid_plural = ""
                e.msgstr_plural = {}
        else:
            obsolete.append(e.msgid)
            if is_pot or prune:
                po.remove(e)
    have = set(e.msgid for e in po if e.msgid)
    added = 0
    for msgid in sorted(code_ids):
        if msgid not in have:
            if msgid in plurals:
                entry = polib.POEntry(
                    msgid=msgid, msgid_plural=plurals[msgid],
                    msgstr_plural={0: "", 1: ""},
                    occurrences=occurrences_for(code, msgid))
            else:
                entry = polib.POEntry(
                    msgid=msgid, msgstr="",
                    occurrences=occurrences_for(code, msgid))
            _insert_sorted(po, entry)
            added += 1
    return added, obsolete


def _strip_crlf(path):
    with open(path, "rb") as f:
        data = f.read()
    if b"\r" in data:
        with open(path, "wb") as f:
            f.write(data.replace(b"\r\n", b"\n").replace(b"\r", b"\n"))


# --------------------------------------------------------------------------- #
# Safe-write helpers: backups, dry-run previews, placeholder checking
# --------------------------------------------------------------------------- #
def _placeholders(s):
    """The %N positional placeholders (e.g. %1, %2) used by ffiutil.template."""
    return set(re.findall(r"%\d+", s or ""))


def _is_translated(e):
    """True if a PO entry carries a usable translation. For a plural entry the
    forms live in msgstr_plural, so treat form 0 as the 'is it translated?'
    signal — the same signal the Lua parser uses to decide whether to load the
    entry, which keeps the two counts in agreement."""
    if e.msgid_plural:
        return bool((e.msgstr_plural or {}).get(0))
    return bool(e.msgstr)


def _ensure_plural_forms(po, path, plurals):
    """Make sure a catalogue that will hold plural entries declares Plural-Forms
    in its header (gettext requires it; the Lua parser reads it to pick forms)."""
    if not plurals or po.metadata.get("Plural-Forms"):
        return
    if os.path.basename(path).endswith(".pot"):
        po.metadata["Plural-Forms"] = "nplurals=INTEGER; plural=EXPRESSION;"
    else:
        # The plugin currently ships Bulgarian only (2 forms).
        po.metadata["Plural-Forms"] = "nplurals=2; plural=(n != 1);"


def _render(po):
    """Exactly what write_po would write, produced in a throwaway temp file so a
    dry run can diff it without touching the real file."""
    fd, tmp = tempfile.mkstemp(suffix=".po")
    os.close(fd)
    try:
        write_po(po, tmp)
        with open(tmp, encoding="utf-8") as f:
            return f.read()
    finally:
        os.unlink(tmp)


def _changed_lines(path, new_text):
    """How many lines would change if `new_text` were written to `path`."""
    old = (open(path, encoding="utf-8").read().split("\n")
           if os.path.exists(path) else [])
    diff = difflib.unified_diff(old, new_text.split("\n"), n=0)
    return sum(1 for ln in diff
               if ln[:1] in "+-" and ln[:3] not in ("+++", "---"))


def _backup(paths):
    """Copy the existing `paths` into a fresh timestamped folder under the system
    temp dir. Returns that folder, or None if there was nothing to copy."""
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    dest = os.path.join(tempfile.gettempdir(), "kosyncthing-i18n-backup-" + stamp)
    made = False
    for p in paths:
        if os.path.exists(p):
            os.makedirs(dest, exist_ok=True)
            shutil.copy2(p, os.path.join(dest, os.path.basename(p)))
            made = True
    return dest if made else None


def _maybe_backup(args):
    """Save a backup before any write, unless --dry-run or --no-backup."""
    if getattr(args, "dry_run", False) or getattr(args, "no_backup", False):
        return
    folder = _backup([POT_PATH] + po_paths())
    if folder:
        print("Backup saved (in case you want to undo): %s\n" % folder)


def apply_changes(po, path, args, added=0, obsolete=0):
    """Write `po` to `path`, or — with --dry-run — only report what would change."""
    name = os.path.basename(path)
    tail = " (+%d new, -%d obsolete)" % (added, obsolete) if (added or obsolete) else ""
    if getattr(args, "dry_run", False):
        print("  would update %s: ~%d line(s)%s"
              % (name, _changed_lines(path, _render(po)), tail))
    else:
        write_po(po, path)
        print("  updated %s%s" % (name, tail))


# --------------------------------------------------------------------------- #
# Lua ground-truth cross-check (optional)
# --------------------------------------------------------------------------- #
def lua_parse_count(po_path):
    """Number of entries syncthing_i18n.parsePO resolves from `po_path`, or None
    if no lua interpreter is available."""
    lua = next((c for c in ("lua5.3", "lua5.4", "luajit", "lua") if _which(c)), None)
    if not lua:
        return None
    return _lua_count_via_patch(lua, po_path)


def _lua_count_via_patch(lua, po_path):
    src_path = os.path.join(PLUGIN_ROOT, "syncthing_i18n.lua")
    with open(src_path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    # Drop the module's top-level `return ...` (it sits in column 0; returns
    # inside functions are indented) so we can append an accessor that reaches
    # the file-local parsePO and count what it resolves.
    for idx in range(len(lines) - 1, -1, -1):
        if re.match(r"^return\b", lines[idx]):
            del lines[idx]
            break
    safe_path = po_path.replace("\\", "\\\\").replace('"', '\\"')
    root = PLUGIN_ROOT.replace("\\", "\\\\")
    patched = (
        'package.path="%s/?.lua;"..package.path\n'
        # Any KOReader module syncthing_i18n pulls in (logger, gettext, …) is not
        # present standalone; return a permissive stub for whatever is missing so
        # the file loads and parsePO becomes callable.
        'local __rr = require\n'
        'require = function(n)\n'
        '  local ok, m = pcall(__rr, n); if ok then return m end\n'
        '  return setmetatable({}, {__index=function() return function() end end,\n'
        '                          __call=function() return nil end})\n'
        'end\n' % root
        + "\n".join(lines)
        + ('\nlocal __map = parsePO("%s")\n'
           'local __c = 0\n'
           'if __map then for _k in pairs(__map) do __c = __c + 1 end end\n'
           'io.write(tostring(__c))\n') % safe_path
    )
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False,
                                     encoding="utf-8") as tf:
        tf.write(patched)
        tmp = tf.name
    try:
        r = subprocess.run([lua, tmp], capture_output=True, text=True, timeout=30)
        out = r.stdout.strip()
        return int(out) if out.isdigit() else None
    except Exception:
        return None
    finally:
        os.unlink(tmp)


def _which(name):
    from shutil import which
    return which(name)


# --------------------------------------------------------------------------- #
# Subcommands
# --------------------------------------------------------------------------- #
def cmd_check(args):
    problems = 0
    notes = 0
    code, _plurals = collect_all(PLUGIN_ROOT)
    code_ids = set(code)

    pot = load_po(POT_PATH)
    pot_ids = set(e.msgid for e in pot if e.msgid)

    print("Checking translations for KOSyncthing+ ...\n")
    print("  strings in the code      : %d" % len(code_ids))
    print("  strings in template .pot : %d" % len(pot_ids))

    missing_in_pot = code_ids - pot_ids
    obsolete_in_pot = pot_ids - code_ids
    if missing_in_pot:
        problems += 1
        print("\nNEW: %d string(s) are in the code but not in the .pot yet:"
              % len(missing_in_pot))
        for s in sorted(missing_in_pot)[:30]:
            print("       \"%s\"   (%s)" % (s[:64], ", ".join(code[s][:3])))
        print("     -> add them with:  python3 tools/i18n.py sync")
    if obsolete_in_pot:
        notes += 1
        print("\nOBSOLETE: %d string(s) are in the .pot but no longer in the code:"
              % len(obsolete_in_pot))
        for s in sorted(obsolete_in_pot)[:30]:
            print("       \"%s\"" % (s[:64],))
        print("     -> remove them with:  python3 tools/i18n.py sync --prune")

    seen, dups = set(), set()
    for e in pot:
        if e.msgid in seen:
            dups.add(e.msgid)
        seen.add(e.msgid)
    if dups:
        problems += 1
        print("\nPROBLEM: %d duplicate msgid(s) in the .pot:" % len(dups))
        for d in list(dups)[:10]:
            print("       \"%s\"" % (d[:64],))

    for po_path in po_paths():
        po = load_po(po_path)
        po_ids = set(e.msgid for e in po if e.msgid)
        empties = sorted(e.msgid for e in po if e.msgid and not _is_translated(e))
        name = os.path.basename(po_path)
        print("\n%s : %d of %d strings translated"
              % (name, len(po_ids) - len(empties), len(po_ids)))

        miss = pot_ids - po_ids
        if miss:
            problems += 1
            print("  PROBLEM: %d template string(s) are missing here:" % len(miss))
            for s in sorted(miss)[:20]:
                print("         \"%s\"" % (s[:64],))
            print("     -> add them with:  python3 tools/i18n.py sync")
        if po_ids - pot_ids:
            notes += 1
            print("  OBSOLETE: %d string(s) here are no longer in the code"
                  " (sync --prune to remove)" % len(po_ids - pot_ids))
        if empties:
            notes += 1
            print("  TODO: %d string(s) still need a translation:" % len(empties))
            for s in empties[:15]:
                print("         \"%s\"" % (s[:64],))
            print("     -> open %s and fill in the matching msgstr lines" % name)

        # %1/%2 placeholders must match between the original and the translation
        ph_bad = [(e.msgid, _placeholders(e.msgid), _placeholders(e.msgstr))
                  for e in po
                  if e.msgid and e.msgstr
                  and _placeholders(e.msgid) != _placeholders(e.msgstr)]
        if ph_bad:
            problems += 1
            print("  PROBLEM: %d translation(s) use different %%N placeholders than"
                  " the original (this breaks the text at runtime):" % len(ph_bad))
            for msgid, a, b in ph_bad[:10]:
                print("         \"%s\"  original=%s translation=%s"
                      % (msgid[:48], sorted(a) or "{}", sorted(b) or "{}"))

        crlf = _crlf_count(po_path)
        if crlf:
            problems += 1
            print("  PROBLEM: %d Windows line-ending(s) (CR) — must be 0" % crlf)

        if args.lua:
            cnt = lua_parse_count(po_path)
            if cnt is None:
                print("  (skipped the extra Lua check — no 'lua' command found)")
            elif cnt == len(po_ids) - len(empties):
                print("  OK: the plugin's own parser loads all %d translation(s)" % cnt)
            else:
                problems += 1
                print("  PROBLEM: the plugin's parser loaded %d but %d were expected"
                      % (cnt, len(po_ids) - len(empties)))

    if _crlf_count(POT_PATH):
        problems += 1
        print("\nPROBLEM: the .pot has Windows line-endings (CR) — must be 0")

    print("")
    if problems:
        print("Found %d problem(s)%s. Most are fixed by running:  "
              "python3 tools/i18n.py sync"
              % (problems, (" and %d note(s)" % notes) if notes else ""))
        return 1
    if notes:
        print("No errors. There are %d optional note(s) above"
              " (NEW / TODO / OBSOLETE)." % notes)
        return 0
    print("All good — code, template and translations are in sync. Nothing to do.")
    return 0


def cmd_sync(args):
    code, plurals = collect_all(PLUGIN_ROOT)
    _maybe_backup(args)

    print("Template (.pot):")
    pot = load_po(POT_PATH)
    _ensure_plural_forms(pot, POT_PATH, plurals)
    added, obsolete = reconcile(pot, code, is_pot=True, prune=True, plurals=plurals)
    apply_changes(pot, POT_PATH, args, added, len(obsolete))

    print("Translations:")
    for po_path in po_paths():
        po = load_po(po_path)
        _ensure_plural_forms(po, po_path, plurals)
        added, obsolete = reconcile(po, code, is_pot=False, prune=args.prune, plurals=plurals)
        apply_changes(po, po_path, args, added, len(obsolete) if args.prune else 0)
        if obsolete and not args.prune:
            print("    (%d obsolete entry/entries kept — use --prune to remove)"
                  % len(obsolete))

    if getattr(args, "dry_run", False):
        print("\nThis was a dry run — nothing was written."
              " Re-run without --dry-run to apply.")
    else:
        print("\nDone. If you added new strings, run 'check' to see what still"
              " needs translating.")
    return 0


def cmd_refs(args):
    code, _ = collect_all(PLUGIN_ROOT)
    _maybe_backup(args)
    for path in [POT_PATH] + po_paths():
        po = load_po(path)
        changed = 0
        for e in po:
            if not e.msgid:
                continue
            occ = occurrences_for(code, e.msgid)
            if [tuple(o) for o in e.occurrences] != occ:
                e.occurrences = occ
                changed += 1
        apply_changes(po, path, args)
        if changed:
            print("    (%d entry/entries had outdated line numbers)" % changed)
    if getattr(args, "dry_run", False):
        print("\nThis was a dry run — nothing was written.")
    return 0


def cmd_reword(args):
    pairs = []
    for spec in args.map or []:
        old, sep, new = spec.partition("=")
        if not sep:
            sys.exit("error: --map needs the form OLD=NEW (got %r)" % spec)
        pairs.append((old, new))
    if args.from_file:
        with open(args.from_file, encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if line and not line.startswith("#"):
                    old, sep, new = line.partition("=")
                    if sep:
                        pairs.append((old, new))
    if not pairs:
        sys.exit("error: nothing to do — pass --map OLD=NEW or --from-file FILE")

    dry = getattr(args, "dry_run", False)
    if not dry:
        _maybe_backup(args)

    # 1) source .lua — replace the exact literal text inside the code.
    print("Source files:")
    touched = 0
    for dirpath, dirnames, filenames in os.walk(PLUGIN_ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in sorted(filenames):
            if not fn.endswith(".lua"):
                continue
            path = os.path.join(dirpath, fn)
            with open(path, encoding="utf-8") as fh:
                txt = fh.read()
            new_txt = txt
            for old, new in pairs:
                new_txt = new_txt.replace('"%s"' % old, '"%s"' % new)
            if new_txt != txt:
                touched += 1
                rel = os.path.relpath(path, PLUGIN_ROOT)
                if dry:
                    print("  would edit %s" % rel)
                else:
                    with open(path, "w", encoding="utf-8") as fh:
                        fh.write(new_txt)
                    print("  edited %s" % rel)
    if not touched:
        print("  (no source file contained the old text — check the spelling,"
              " including any \\n escapes)")

    # 2) .pot + .po — rename the msgid, keep the translation, refresh refs.
    code, _ = collect_all(PLUGIN_ROOT)   # reflects the renamed source
    print("Template + translations:")
    for path in [POT_PATH] + po_paths():
        po = load_po(path)
        n = 0
        for old, new in pairs:
            e = po.find(lua_unescape(old))
            if e:
                e.msgid = lua_unescape(new)
                n += 1
        if not dry:                            # keep #: refs correct after rename
            for e in po:
                if e.msgid:
                    e.occurrences = occurrences_for(code, e.msgid)
        apply_changes(po, path, args)
        print("    (%d msgid(s) renamed)" % n)

    if dry:
        print("\nThis was a dry run — nothing was written.")
    else:
        print("\nDone. Run 'python3 tools/i18n.py check --lua' to confirm.")
    return 0


def cmd_stats(args):
    pot = load_po(POT_PATH)
    total = len([e for e in pot if e.msgid])
    print("Template has %d translatable string(s).\n" % total)
    for po_path in po_paths():
        po = load_po(po_path)
        ids = [e for e in po if e.msgid]
        done = [e for e in ids if _is_translated(e)]
        pct = (100.0 * len(done) / len(ids)) if ids else 0.0
        filled = int(pct // 5)
        bar = "#" * filled + "." * (20 - filled)
        print("  %-12s [%s] %d/%d (%.0f%%)"
              % (os.path.basename(po_path), bar, len(done), len(ids), pct))
    return 0


# --------------------------------------------------------------------------- #
def _crlf_count(path):
    with open(path, "rb") as f:
        return f.read().count(b"\r")


GUIDE = """\
i18n.py  —  keep the KOSyncthing+ translations in good shape.

First time?  Install the one dependency:
    pip install polib --break-system-packages

Everyday workflow:
    1. Add or change _("...") strings in the .lua code as usual.
    2. python3 tools/i18n.py sync          # add the new strings to .pot / .po
    3. Open locale/bg.po and translate the new (empty) lines.
    4. python3 tools/i18n.py check --lua    # confirm everything is consistent

Commands (add -h to any for details):
    check    See what is missing, untranslated, or broken. Changes nothing.
    sync     Make the .pot and .po match the code (add new, refresh refs).
    refs     Only refresh the '#: file:line' references.
    reword   Rename a string everywhere and keep its translation.
    stats    Show how much is translated.

Safety net:
    * Write commands first save a backup of your files to a temp folder.
    * Add --dry-run to any write command to preview without changing a thing.
"""


def main():
    ap = argparse.ArgumentParser(
        prog="i18n.py",
        description="Translation maintenance for the KOSyncthing+ plugin.",
        epilog="Run 'i18n.py' with no command to see a short getting-started guide.")
    sub = ap.add_subparsers(dest="cmd")

    def add_write_flags(pp):
        pp.add_argument("--dry-run", action="store_true",
                        help="preview the changes without writing any file")
        pp.add_argument("--no-backup", action="store_true",
                        help="do not save a backup before writing")

    p = sub.add_parser("check", help="see what needs doing (changes nothing)")
    p.add_argument("--lua", action="store_true",
                   help="also load each .po with the plugin's real parser")
    p.set_defaults(func=cmd_check)

    p = sub.add_parser("sync", help="make .pot/.po match the code")
    p.add_argument("--prune", action="store_true",
                   help="also delete strings that are no longer in the code")
    add_write_flags(p)
    p.set_defaults(func=cmd_sync)

    p = sub.add_parser("refs", help="refresh #: source references only")
    add_write_flags(p)
    p.set_defaults(func=cmd_refs)

    p = sub.add_parser("reword", help="rename a string and keep its translation")
    p.add_argument("--map", action="append", metavar="OLD=NEW",
                   help="rename a string (use the exact source spelling; repeatable)")
    p.add_argument("--from-file", metavar="FILE",
                   help="a file with one OLD=NEW per line")
    add_write_flags(p)
    p.set_defaults(func=cmd_reword)

    p = sub.add_parser("stats", help="show translation progress")
    p.set_defaults(func=cmd_stats)

    args = ap.parse_args()
    if not args.cmd:
        print(GUIDE)
        return
    sys.exit(args.func(args))


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        # output was piped into something like `head` that closed early
        try:
            sys.stdout.close()
        except Exception:
            pass
        os._exit(0)
