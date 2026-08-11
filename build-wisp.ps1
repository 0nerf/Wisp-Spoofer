# ==============================================================
# Wisp Build Script
# Builds the app AND patches the NSIS uninstaller icon
# Usage: powershell -ExecutionPolicy Bypass -File build-wisp.ps1
# ==============================================================

$ErrorActionPreference = "Stop"
$rootDir = $PSScriptRoot
$makensisPath = "$env:LOCALAPPDATA\tauri\NSIS\makensis.exe"
$nsisScriptPath = "$rootDir\src-tauri\target\release\nsis\x64\installer.nsi"
$nsisOutDir    = "$rootDir\src-tauri\target\release\nsis\x64"
$bundleOutDir  = "$rootDir\src-tauri\target\release\bundle\nsis"
$iconPath      = "$rootDir\src-tauri\icons\icon.ico" -replace '\\', '\\'

Write-Host ""
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "  Wisp Build Script" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: Build with Tauri
Write-Host "[1/3] Building Wisp with Tauri..." -ForegroundColor Yellow
pnpm tauri build
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Tauri build failed!" -ForegroundColor Red
    exit 1
}
Write-Host "      Tauri build complete." -ForegroundColor Green

# Step 2: Patch the NSIS script to set UNINSTALLERICON
Write-Host "[2/3] Patching NSIS script for uninstaller icon..." -ForegroundColor Yellow

if (-not (Test-Path $nsisScriptPath)) {
    Write-Host "ERROR: NSIS script not found at: $nsisScriptPath" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $makensisPath)) {
    Write-Host "ERROR: makensis.exe not found at: $makensisPath" -ForegroundColor Red
    exit 1
}

$iconPathForNsis = (Resolve-Path "$rootDir\src-tauri\icons\icon.ico").Path

# Read, patch, write back
$content = Get-Content $nsisScriptPath -Raw -Encoding UTF8
$patched = $content -replace '!define UNINSTALLERICON ""', "!define UNINSTALLERICON `"$iconPathForNsis`""

if ($patched -eq $content) {
    Write-Host "      WARNING: UNINSTALLERICON line not found, trying alternative patch..." -ForegroundColor Yellow
    # Fallback: inject MUI_UNICON directly after MUI_ICON block
    $patched = $content -replace '(; Uninstaller icon\r?\n!if "\$\{UNINSTALLERICON\}" != ""\r?\n  !define MUI_UNICON "\$\{UNINSTALLERICON\}"\r?\n!endif)', "; Uninstaller icon (patched)`n!define MUI_UNICON `"$iconPathForNsis`""
}

Set-Content $nsisScriptPath $patched -Encoding UTF8
Write-Host "      NSIS script patched with icon: $iconPathForNsis" -ForegroundColor Green

# Step 3: Recompile NSIS
Write-Host "[3/3] Recompiling NSIS installer with patched icon..." -ForegroundColor Yellow

Push-Location $nsisOutDir
try {
    & $makensisPath "installer.nsi"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: makensis compilation failed!" -ForegroundColor Red
        exit 1
    }
} finally {
    Pop-Location
}

# Move output to bundle directory
$nsisOutput = "$nsisOutDir\nsis-output.exe"
if (Test-Path $nsisOutput) {
    # Find existing setup.exe name
    $existing = Get-ChildItem "$bundleOutDir\*.exe" | Select-Object -First 1
    if ($existing) {
        Copy-Item $nsisOutput $existing.FullName -Force
        Write-Host "      Patched installer saved to: $($existing.FullName)" -ForegroundColor Green
    } else {
        $outName = "$bundleOutDir\Wisp_setup.exe"
        Copy-Item $nsisOutput $outName -Force
        Write-Host "      Patched installer saved to: $outName" -ForegroundColor Green
    }
} else {
    Write-Host "WARNING: makensis output not found at $nsisOutput" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=====================================" -ForegroundColor Green
Write-Host "  BUILD COMPLETE!" -ForegroundColor Green
Write-Host "=====================================" -ForegroundColor Green
Write-Host ""
Write-Host "Installer: $bundleOutDir" -ForegroundColor Cyan
Write-Host ""
