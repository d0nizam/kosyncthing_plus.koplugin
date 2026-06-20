<#
.SYNOPSIS
    One-command setup: install MinGW + LuaRocks + deps, then run tests.

.DESCRIPTION
    Installs (per-user, no admin needed unless winget requires it):
      1. MinGW-w64 UCRT   via winget (C compiler, needed for Lua C rocks)
      2. LuaRocks 3.12.2  standalone from luarocks.github.io (bundles LuaJIT)
      3. Rock: luafilesystem
    Then runs tests with bundled LuaJIT.

    Idempotent — already-installed components are skipped.

.PARAMETER SkipTests
    If set, installs everything but skips the test run.

.EXAMPLE
    .\spec\setup_windows.ps1
    .\spec\setup_windows.ps1 -SkipTests
#>

param([switch]$SkipTests)

$ErrorActionPreference = "Stop"
$start = Get-Date

# ---------- prerequisites ----------
$winget = Get-Command winget.exe -ErrorAction SilentlyContinue
if (-not $winget) {
    Write-Host ""
    Write-Host "ERROR: winget not found." -ForegroundColor Red
    Write-Host ""
    Write-Host "winget e nuzhen za instalirane na MinGW-w64 (C kompilator)."
    Write-Host "Instalirai go ot Microsoft Store:"
    Write-Host "  https://www.microsoft.com/p/app-installer/9nblggh4nns1"
    Write-Host ""
    Write-Host "Ili prez PowerShell (kato admin):"
    Write-Host "  Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe"
    Write-Host ""
    Write-Host "Sled tova probai rachniya setup ot spec/README.md."
    exit 1
}

# ---------- paths ----------
$rocksDir  = "$env:USERPROFILE\luarocks"
$rocksExe  = "$rocksDir\luarocks.exe"
$archRocks = if ([Environment]::Is64BitOperatingSystem) { "64" } else { "32" }

# LuaJIT is bundled with standalone LuaRocks; find the bin dir.
$luajitDir = if (Test-Path "$rocksDir\luajit.exe") {
    $rocksDir
} elseif (Test-Path "$env:USERPROFILE\AppData\Local\Programs\LuaJIT\bin\luajit.exe") {
    "$env:USERPROFILE\AppData\Local\Programs\LuaJIT\bin"
} else {
    $null
}

# ---------- helpers ----------
function Step($Title) {
    Write-Host ""
    Write-Host "--- $Title ---" -ForegroundColor Cyan
}

function Ok($Msg) {
    Write-Host "  [OK] $Msg" -ForegroundColor Green
}

function Wrn($Msg) {
    Write-Host "  [!] $Msg" -ForegroundColor Yellow
}

function Add-ToUserPath($Path) {
    $current = [Environment]::GetEnvironmentVariable("PATH", "User")
    $parts   = $current -split ";" | Where-Object { $_ -and $_ -ne $Path }
    $new     = "$Path;$($parts -join ';')"
    [Environment]::SetEnvironmentVariable("PATH", $new, "User")
    if ($env:PATH -split ";" -notcontains $Path) {
        $env:PATH = "$Path;$env:PATH"
    }
    Ok "Added $Path to PATH"
}

# =================================================================
# 1. MinGW-w64 (C compiler for Lua rocks)
# =================================================================
Step "MinGW-w64 (C compiler)"

$needGcc = $null -eq (Get-Command gcc.exe -ErrorAction SilentlyContinue)

if ($needGcc) {
    Write-Host "  Installing MinGW-w64 UCRT via winget ..."
    winget install -e --id BrechtSanders.WinLibs.POSIX.UCRT --accept-package-agreements 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "winget install MinGW failed (try running as admin)"
    }
    Ok "MinGW-w64 installed (restart shell or run: `$env:PATH = ...mingw64\bin` to use)"
} else {
    Ok "Already present: $(where.exe gcc 2>$null | Select-Object -First 1)"
}

# =================================================================
# 2. LuaRocks (standalone — bundles LuaJIT)
# =================================================================
Step "LuaRocks"

$needRocks = -not (Test-Path $rocksExe)

if ($needRocks) {
    New-Item -ItemType Directory -Path $rocksDir -Force | Out-Null
    $rocksUrl = "https://luarocks.github.io/luarocks/releases/luarocks-3.12.2-windows-${archRocks}.zip"
    $zip = "$env:TEMP\luarocks.zip"
    Write-Host "  Downloading ..." -NoNewline
    curl.exe -sSL -o $zip $rocksUrl 2>$null
    if ($LASTEXITCODE -ne 0) { throw "curl failed" }
    Write-Host " done" -ForegroundColor Green
    Expand-Archive -Path $zip -DestinationPath $rocksDir -Force
    Remove-Item -Force $zip
    $sub = Get-ChildItem "$rocksDir\luarocks-*" -Directory | Select-Object -First 1
    if ($sub) {
        Get-ChildItem $sub.FullName | Move-Item -Destination $rocksDir -Force
        Remove-Item -Recurse -Force $sub.FullName
    }
    Add-ToUserPath $rocksDir

    # Locate bundled LuaJIT
    $luajitDir = $rocksDir
} else {
    Ok "Already present: $rocksExe"
}

# Configure luarocks to use its bundled LuaJIT (not an external Lua).
$luajitDir = if (Test-Path "$rocksDir\luajit.exe") { $rocksDir } else { $luajitDir }
$configFile = if (Test-Path "$rocksDir\..\..\LuaJIT\etc\luarocks\config.lua") {
    Resolve-Path "$rocksDir\..\..\LuaJIT\etc\luarocks\config.lua"
} elseif (Test-Path "$env:APPDATA\luarocks\config.lua") {
    "$env:APPDATA\luarocks\config.lua"
} else { $null }

if ($configFile -and (Test-Path $configFile)) {
    $content = Get-Content $configFile -Raw
    if ($content -match 'lua_interpreter\s*=\s*"lua\.exe"') {
@'
lua_interpreter = "luajit"
lua_version = "5.1"
'@ | Set-Content $configFile
        Ok "LuaRocks configured for bundled LuaJIT"
    } else {
        Wrn "Config exists but lua_interpreter is not lua.exe — leaving as-is"
    }
}

if ($luajitDir) {
    $env:PATH = "$luajitDir;$rocksDir;$env:PATH"
} else {
    $env:PATH = "$rocksDir;$env:PATH"
}

# =================================================================
# 3. Rock: luafilesystem (the only C rock the tests need)
# =================================================================
Step "LuaRocks packages"

$rock = "luafilesystem"
$installed = & $rocksExe list --porcelain 2>$null |
    Where-Object { $_ -match "^$rock\s" }
if ($installed) {
    Ok "$rock already installed"
} else {
    Write-Host "  Installing $rock ..." -NoNewline
    & $rocksExe install $rock 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host " done" -ForegroundColor Green
    } else {
        Write-Host " FAILED" -ForegroundColor Red
        throw "luarocks install $rock failed"
    }
}

# Smoke test — use LuaJIT (bundled with luarocks), NOT Lua 5.4.
$ljExe = if ($luajitDir) { "$luajitDir\luajit.exe" } else { "$rocksDir\luajit.exe" }
if (-not (Test-Path $ljExe)) {
    $ljExe = Get-ChildItem -Recurse -Filter "luajit.exe" "$env:USERPROFILE\AppData\Local\Programs\LuaJIT" 2>$null |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $ljExe) { $ljExe = "luajit.exe" }

Write-Host "  Smoke test: " -NoNewline
$smokeFile = Join-Path $env:TEMP "lfs_smoke.lua"
@'
local ok, lfs = pcall(require, "lfs")
io.write(ok and "lfs OK" or "lfs FAIL")
'@ | Set-Content $smokeFile -Encoding ASCII
& $ljExe $smokeFile 2>&1 | ForEach-Object { Write-Host "$_" -NoNewline }
Remove-Item $smokeFile -Force
Write-Host ""

# =================================================================
# 4. Run tests
# =================================================================
if (-not $SkipTests) {
    Step "Running tests with $ljExe"
    $testRoot = Split-Path -Parent $PSScriptRoot
    Push-Location $testRoot

    $total = 0; $passed = 0; $failed = 0
    foreach ($spec in Get-ChildItem spec\*_spec.lua) {
        $total++
        $name = $spec.Name
        Write-Host "  $name ... " -NoNewline
        $output = & $ljExe spec/run_tests.lua $spec.FullName 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "OK" -ForegroundColor Green
            $passed++
        } else {
            Write-Host "FAIL" -ForegroundColor Red
            $output | ForEach-Object { Write-Host "    $_" }
            $failed++
        }
    }

    $elapsed = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
    Write-Host ""
    Write-Host "Total time: ${elapsed}s" -ForegroundColor Cyan
    Write-Host "Specs: $total, Passed: $passed, Failed: $failed" -ForegroundColor Cyan

    Pop-Location
    if ($failed -gt 0) { exit 1 } else { exit 0 }
} else {
    Write-Host ""
    Write-Host "Setup complete. Run tests with:" -ForegroundColor Cyan
    Write-Host "  for `$spec in Get-ChildItem spec\*_spec.lua { & $ljExe spec/run_tests.lua `$spec.FullName }" -ForegroundColor Yellow
}
