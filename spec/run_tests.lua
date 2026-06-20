-- run_tests.lua — a tiny, dependency-free Busted-compatible runner.
--
-- The spec suite was written for the `busted` framework. When busted (and
-- luarocks) are not installed, this runner provides just enough of the
-- describe/it/before_each/after_each API and the luassert matchers the specs
-- actually use, so the suite can run under plain lua5.3 / luajit.
--
-- Usage:
--   lua5.3 spec/run_tests.lua spec/st_utils_spec.lua      (one file)
--   for f in spec/*_spec.lua; do lua5.3 spec/run_tests.lua "$f"; done
--
-- It is NOT a full busted replacement — it implements only what these specs
-- need. If you have busted installed, `busted spec` still works unchanged.

table.unpack = table.unpack or unpack

local target = arg[1]
if not target then io.stderr:write("usage: run_tests.lua <spec_file>\n"); os.exit(2) end

-- make `require("spec.xxx")` and the plugin modules resolvable
package.path = "./?.lua;" .. package.path

-- Windows compat: patch os.execute and io.open so that Unix shell idioms
-- (mkdir -p, rm -rf, touch) and /tmp/ paths work from the test suite without
-- touching any spec file.  Zero effect on Linux — the if is never entered.
if package.config:sub(1,1) == "\\" then
    -- Add luarocks paths so C modules (lfs, cjson) are found on Windows.
    -- luarocks installs under %APPDATA%\luarocks; the exact version sub-path
    -- depends on which Lua interpreter is in use.
    local lua_version = (_VERSION:match("%d+%.%d+$")) or "5.1"
    local appdata = (os.getenv("APPDATA") or os.getenv("LOCALAPPDATA") or ""):gsub("\\", "/")
    if appdata ~= "" then
        local rocks_share = appdata .. "/luarocks/share/lua/" .. lua_version
        local rocks_lib   = appdata .. "/luarocks/lib/lua/" .. lua_version
        package.path  = package.path  .. ";" .. rocks_share .. "/?.lua;" .. rocks_share .. "/?/init.lua"
        package.cpath = package.cpath .. ";" .. rocks_lib .. "/?.dll"
    end
    local tmp = (os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp"):gsub("\\", "/")

    local function translate_path(path)
        if not path then return nil end
        local translated = path:gsub("^/tmp/", tmp .. "/")
        -- On Windows, os.tmpname() returns bare names like "\sems." (root-relative).
        -- Redirect them to the real temp directory so they don't litter the driveroot.
        if translated:match("^\\[^\\]+$") and not translated:match("^[A-Za-z]:") then
            translated = tmp .. translated
        end
        return translated
    end

    local function translate(path)
        return path:gsub("^['\"](.*)['\"]$", "%1"):gsub("^/tmp/", tmp .. "/")
    end

    local orig_execute
    local orig_open
    local orig_dofile
    local orig_loadfile
    local orig_remove
    local orig_rename
    local orig_popen

    local function win_path(p)
        return p:gsub("/", "\\")
    end

    orig_execute = os.execute
    os.execute = function(cmd)
        -- Handle chained commands (e.g. "rm -rf 'x'; mkdir -p 'x'")
        local function process_sub_commands(c)
            c = c:gsub("^%s*(.-)%s*$", "%1")
            -- 2>/dev/null suffix
            c = c:gsub("%s+2>/dev/null%s*$", "")
            if c:match("^mkdir%s+-p%s+") then
                local rest = c:match("^mkdir%s+-p%s+(.+)$")
                local paths = {}
                for p in rest:gmatch("'([^']+)'") do
                    table.insert(paths, translate_path(p))
                end
                if #paths == 0 then
                    table.insert(paths, translate_path(rest:gsub("^['\"](.*)['\"]$", "%1")))
                end
                for _, p in ipairs(paths) do
                    orig_execute('cmd /c md "' .. win_path(p) .. '" 2>nul')
                end
            elseif c:match("^rm%s+-rf%s+") then
                local rest = c:match("^rm%s+-rf%s+(.+)$")
                local path = win_path(translate(rest))
                orig_execute('cmd /c if exist "' .. path .. '\\*" (rmdir /s /q "' .. path .. '" 2>nul ) else (if exist "' .. path .. '" del /f /q "' .. path .. '" 2>nul )')
            elseif c:match("^touch%s+") then
                local rest = c:match("^touch%s+(.+)$")
                local path = win_path(translate(rest))
                orig_execute('cmd /c if exist "' .. path .. '\\*" (copy /b nul +,,"' .. path .. '" >nul ) else (type nul > "' .. path .. '" 2>nul )')
            elseif c:match("^echo%s+.+%s*>%s+") then
                local content = c:match("^echo%s+(.-)%s*>%s+")
                local rest = c:match("^echo%s+.-%s*>%s+(.+)$")
                if content and rest then
                    local path = win_path(translate(rest))
                    orig_execute('cmd /c echo ' .. content .. ' > "' .. path .. '"')
                else
                    orig_execute(c)
                end
            elseif c:match("^find%s+'") and c:match("%-exec%s+rm%s+-rf") then
                -- find 'DIR' -maxdepth 1 -name 'GLOB' -exec rm -rf {} + 2>/dev/null
                local dir = c:match("^find%s+'([^']+)'")
                local glob = c:match("%-name%s+'([^']+)'")
                if dir and glob then
                    local tdir = win_path(translate_path(dir))
                    if c:match("%-type%s+d") then
                        orig_execute('cmd /c for /d %f in ("' .. tdir .. '\\' .. glob .. '") do if exist "%f" rmdir /s /q "%f" 2>nul')
                    else
                        orig_execute('cmd /c del /f /q "' .. tdir .. '\\' .. glob .. '" 2>nul')
                    end
                else
                    orig_execute(c)
                end
            else
                orig_execute(c)
            end
        end

        -- Split on ';' to handle chained commands
        local first = cmd:match("^(.-);(.*)$")
        if first then
            local chain = {}
            for part in cmd:gmatch("[^;]+") do
                table.insert(chain, part)
            end
            for _, part in ipairs(chain) do
                process_sub_commands(part)
            end
            return true
        else
            process_sub_commands(cmd)
            return true
        end
    end

    orig_open = io.open
    io.open = function(path, mode)
        return orig_open(translate_path(path), mode)
    end

    orig_popen = io.popen
    io.popen = function(cmd, mode)
        local function cmd_translate_path(c)
            return c:gsub("/tmp/", tmp .. "/")
        end
        local translated = cmd_translate_path(cmd)
        -- Translate "test -e 'path' && echo yes" to Windows if exist
        if translated:match("^test%s+%-e%s+") then
            local path = translated:match("^test%s+%-e%s+'([^']+)'.*$")
            if path then
                translated = 'if exist "' .. win_path(path) .. '" (echo yes)'
            end
        end
        -- Translate "find 'DIR' -maxdepth 1 -name 'GLOB' ..." to dir /b
        if translated:match("^find%s+'") then
            local dir = translated:match("^find%s+'([^']+)'")
            local glob = translated:match("%-name%s+'([^']+)'")
            if dir and glob then
                local tdir = win_path(translate_path(dir))
                translated = 'cmd /c dir /b "' .. tdir .. '\\' .. glob .. '" 2>nul'
            end
        end
        if mode == nil then mode = "r" end
        return orig_popen(translated, mode)
    end

    orig_dofile = dofile
    dofile = function(path)
        local translated = translate_path(path)
        -- Explicit env avoids Lua 5.4 _ENV nil when loadfile is called from a wrapper
        return orig_dofile(translated)
    end
    orig_loadfile = loadfile
    loadfile = function(path, mode, env)
        env = env or _ENV
        return orig_loadfile(translate_path(path), mode, env)
    end

    orig_remove = os.remove
    os.remove = function(path)
        path = win_path(translate_path(path))
        local ok, err = orig_remove(path)
        if ok then return ok end
        return orig_execute('cmd /c rmdir /s /q "' .. path .. '" 2>nul')
    end

    do
        local lfs_loaded = false
        local orig_require = require
        require = function(name)
            local mod = orig_require(name)
            if name == "lfs" and not lfs_loaded then
                lfs_loaded = true
                local function wrap_lfs_fn(fn)
                    return function(...)
                        local args = {...}
                        for i = 1, #args do
                            if type(args[i]) == "string" then
                                args[i] = translate_path(args[i])
                            end
                        end
                        return fn(table.unpack(args))
                    end
                end
                mod.attributes = wrap_lfs_fn(mod.attributes)
                mod.dir        = wrap_lfs_fn(mod.dir)
                mod.mkdir      = wrap_lfs_fn(mod.mkdir)
                mod.rmdir      = wrap_lfs_fn(mod.rmdir)
            end
            return mod
        end
    end

    orig_rename = os.rename
    os.rename = function(old, new)
        old = translate_path(old)
        new = translate_path(new)
        orig_remove(new)
        return orig_rename(old, new)
    end
end

-- Lua 5.1 shim: package.searchpath was added in Lua 5.2.
-- LuaJIT (used on-device by KOReader) has it; plain lua5.1 does not.
--
-- IMPORTANT: capture io.open NOW, before spec stubs replace it.
-- Some specs call stubIO() which swaps io.open with a test double that only
-- recognises paths in their io_open_map.  If the polyfill used the global
-- io.open at call-time it would return nil for every real source file,
-- causing loadfile(nil) → require returns true → "attempt to index boolean".
if not package.searchpath then
    local _real_io_open = io.open          -- captured once, immutable from here
    package.searchpath = function(name, path, sep, rep)
        sep = sep or "."
        rep = rep or "/"
        -- replace module-name separator (usually ".") with path separator
        name = name:gsub("%" .. sep, rep)
        local msg = {}
        for p in path:gmatch("[^;]+") do
            local fname = p:gsub("%?", name)
            local f = _real_io_open(fname, "r")
            if f then f:close(); return fname end
            msg[#msg + 1] = "\n\tno file '" .. fname .. "'"
        end
        return nil, table.concat(msg)
    end
end

-- ── busted-style structure: collect a tree, then run it ──────────────────
local root = { name = "", before = {}, after = {}, teardown = nil, children = {} }
local current = root
local function push_block(name)
    local b = { name = name, before = {}, after = {}, teardown = nil, children = {} }
    table.insert(current.children, b)
    local parent = current; current = b
    return parent
end
function describe(name, fn) local parent = push_block(name); fn(); current = parent end
function it(name, fn) table.insert(current.children, { test = true, name = name, fn = fn }) end
function before_each(fn) table.insert(current.before, fn) end
function after_each(fn) table.insert(current.after, fn) end
function setup(fn) table.insert(current.before, fn) end          -- not used, kept for safety
function teardown(fn) current.teardown = fn end
function pending() end                                            -- not used

-- ── luassert-style matchers (only the ones the specs use) ────────────────
local function fail(msg) error(msg, 2) end
local assert_t = {}
setmetatable(assert_t, { __call = function(_, v, msg)
    if v == nil or v == false then fail(msg or "assertion failed") end
    return v
end })
local function tos(v) return type(v) == "string" and ('"'..v..'"') or tostring(v) end
assert_t.are      = {
    equal = function(a, b) if a ~= b then fail("are.equal: "..tos(a).." ~= "..tos(b)) end end,
    same  = function(a, b) if a ~= b then fail("are.same: "..tos(a).." ~= "..tos(b)) end end,
}
assert_t.are_not  = { equal = function(a, b) if a == b then fail("are_not.equal: both "..tos(a)) end end }
assert_t.is_true     = function(v) if v ~= true  then fail("is_true: got "..tos(v)) end end
assert_t.is_false    = function(v) if v ~= false then fail("is_false: got "..tos(v)) end end
assert_t.is_truthy   = function(v) if not v      then fail("is_truthy: got "..tos(v)) end end
assert_t.is_falsy    = function(v) if v          then fail("is_falsy: got "..tos(v)) end end
assert_t.is_nil      = function(v) if v ~= nil   then fail("is_nil: got "..tos(v)) end end
assert_t.is_not_nil  = function(v) if v == nil   then fail("is_not_nil: got nil") end end
assert_t.is_string   = function(v) if type(v) ~= "string"   then fail("is_string: got "..type(v)) end end
assert_t.is_function = function(v) if type(v) ~= "function" then fail("is_function: got "..type(v)) end end
assert_t.has_no = { errors = function(fn)
    local ok, err = pcall(fn)
    if not ok then fail("has_no.errors: "..tostring(err)) end
end }
function assert_t.has_error(fn, expected)
    local ok, err = pcall(fn)
    if ok then fail("has_error: no error was raised") end
    if expected ~= nil and type(expected) == "string" then
        if not tostring(err):find(expected, 1, true) then
            fail("has_error: expected '"..expected.."' in '"..tostring(err).."'")
        end
    end
end
_G.assert = assert_t

-- ── load the spec file (registers the tree) ──────────────────────────────
local chunk, lerr = loadfile(target)
if not chunk then io.stderr:write("LOAD ERROR ("..target.."): "..tostring(lerr).."\n"); os.exit(1) end
local ok, rerr = pcall(chunk)
if not ok then
    print(("%-26s  LOAD-FAIL  %s"):format(target:match("([^/]+)$"), tostring(rerr)))
    os.exit(1)
end

-- ── run the tree ─────────────────────────────────────────────────────────
local pass, fail_n, fails = 0, 0, {}
local function run_block(block, befores, afters, path)
    local befores2 = {}
    for _, f in ipairs(befores)       do befores2[#befores2+1] = f end
    for _, f in ipairs(block.before)  do befores2[#befores2+1] = f end
    local afters2 = {}
    for _, f in ipairs(block.after)   do afters2[#afters2+1] = f end
    for _, f in ipairs(afters)        do afters2[#afters2+1] = f end
    local here = (path == "" and block.name) or (path .. " › " .. block.name)
    for _, child in ipairs(block.children) do
        if child.test then
            local fullname = here .. " :: " .. child.name
            local okh, eh
            for _, b in ipairs(befores2) do
                okh, eh = pcall(b); if not okh then break end
            end
            if okh ~= false then
                local okt, et = pcall(child.fn)
                if okt then pass = pass + 1
                else fail_n = fail_n + 1; fails[#fails+1] = fullname .. "  —  " .. tostring(et) end
            else
                fail_n = fail_n + 1; fails[#fails+1] = fullname .. "  — (before_each) " .. tostring(eh)
            end
            for _, a in ipairs(afters2) do pcall(a) end
        else
            run_block(child, befores2, afters2, here)
        end
    end
    if block.teardown then pcall(block.teardown) end
end
run_block(root, {}, {}, "")

-- Clean up artifacts left behind by mock_koreader and spec files.
-- The /tmp/koreader/ tree is created by datastorage stubs; /tmp/st_*_spec_*
-- dirs are created by individual specs.  All cleaned here in case a spec
-- crashed before its after_each could run.
do
    local roots = { "/tmp/koreader" }
    for _, dir in ipairs(roots) do
        if package.config:sub(1,1) == "\\" then
            local tmp = (os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp"):gsub("\\", "/")
            os.execute('cmd /c rmdir /s /q "' .. dir:gsub("^/tmp/", tmp .. "/"):gsub("/", "\\") .. '" 2>nul')
        else
            os.execute("rm -rf '" .. dir .. "' 2>/dev/null")
        end
    end
end

local short = target:match("([^/]+)$")
print(("%-28s  %3d passed, %3d failed"):format(short, pass, fail_n))
if fail_n > 0 then
    for _, f in ipairs(fails) do print("      ✗ " .. f) end
    os.exit(1)
end
os.exit(0)
