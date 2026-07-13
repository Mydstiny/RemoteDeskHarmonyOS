# check_native_deps.ps1 — Native 依赖检查脚本 (T-231)
# 仅检查, 不下载/不修改/不联网. 所有检查通过返回 0, 否则返回非零.
# 用法: powershell -ExecutionPolicy Bypass -File .\scripts\check_native_deps.ps1

$ErrorActionPreference = "Stop"
$PROJECT = $PSScriptRoot ? (Resolve-Path "$PSScriptRoot\..") : (Resolve-Path ".")
$EXIT = 0

function Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow; $script:EXIT = 1 }
function Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:EXIT = 1 }

Write-Host "=== RemoteDesktop Native Dependency Check ===" -ForegroundColor Cyan
Write-Host "Project: $PROJECT`n"

# ---- FreeRDP submodule ----
Write-Host "[1/8] FreeRDP submodule"
$freerdpDir = Join-Path $PROJECT "freerdp"
if (Test-Path (Join-Path $freerdpDir "CMakeLists.txt")) {
    Pass "freerdp/ submodule present"
} else {
    Warn "freerdp/ submodule missing or incomplete (USE_REAL_FREERDP=OFF is default; not required for default build)"
}

# ---- FreeRDP prebuilt libs ----
Write-Host "[2/8] FreeRDP prebuilt static libs"
$frdpArm64 = Join-Path $PROJECT "libs\freerdp-ohos\arm64-v8a\libfreerdp3.a"
$frdpX64   = Join-Path $PROJECT "libs\freerdp-ohos\x86_64\libfreerdp3.a"
if ((Test-Path $frdpArm64) -and (Test-Path $frdpX64)) {
    Pass "libfreerdp3.a present for arm64-v8a and x86_64"
} elseif (Test-Path $frdpArm64) {
    Pass "libfreerdp3.a present for arm64-v8a (x86_64 missing — default build OK)"
} else {
    Warn "libfreerdp3.a not found (USE_REAL_FREERDP=OFF is default; run scripts/build_freerdp_ohos.sh arm64 to generate)"
}

# ---- CMakeLists ----
Write-Host "[3/8] CMakeLists.txt entries"
$cmake = Join-Path $PROJECT "entry\src\main\cpp\CMakeLists.txt"
if (Test-Path $cmake) {
    $cmakeContent = Get-Content $cmake -Raw
    $hasRdp = $cmakeContent -match "rdp/freerdp_adapter"
    $hasRsd = $cmakeContent -match "rustdesk/rustdesk_bridge"
    $hasRenderer = $cmakeContent -match "render/gl_renderer"
    $hasAudio = $cmakeContent -match "audio/audio_player"
    if ($hasRdp) { Pass "freerdp_adapter in CMakeLists" } else { Warn "freerdp_adapter missing from CMakeLists" }
    if ($hasRsd) { Pass "rustdesk_bridge in CMakeLists" } else { Warn "rustdesk_bridge missing from CMakeLists" }
    if ($hasRenderer) { Pass "gl_renderer in CMakeLists" } else { Warn "gl_renderer missing from CMakeLists" }
    if ($hasAudio) { Pass "audio_player in CMakeLists" } else { Warn "audio_player missing from CMakeLists" }
} else {
    Fail "CMakeLists.txt not found at $cmake"
}

# ---- RustDesk bridge sources ----
Write-Host "[4/8] RustDesk bridge sources"
$rsdCpp = Join-Path $PROJECT "entry\src\main\cpp\rustdesk\rustdesk_bridge.cpp"
$rsdH   = Join-Path $PROJECT "entry\src\main\cpp\rustdesk\rustdesk_bridge.h"
if ((Test-Path $rsdCpp) -and (Test-Path $rsdH)) {
    Pass "RustDesk bridge sources present"
} else {
    Warn "RustDesk bridge sources missing"
}

# ---- RustDesk FFI ----
Write-Host "[5/8] RustDesk FFI (Rust crate)"
$cargoToml = Join-Path $PROJECT "rustdesk_ffi\Cargo.toml"
if (Test-Path $cargoToml) {
    Pass "rustdesk_ffi Cargo.toml present"
} else {
    Warn "rustdesk_ffi missing"
}

# ---- OpenSSL static libs ----
Write-Host "[6/8] OpenSSL static libs"
$osslArm64 = Join-Path $PROJECT "libs\openssl\arm64-v8a\libssl.a"
$osslX64   = Join-Path $PROJECT "libs\openssl\x86_64\libssl.a"
# Check alternate path too
if (-not (Test-Path $osslArm64)) {
    $osslArm64 = Join-Path $PROJECT "libs\openssl-3.4.1\arm64-v8a\libssl.a"
    $osslX64   = Join-Path $PROJECT "libs\openssl-3.4.1\x86_64\libssl.a"
}
if ((Test-Path $osslArm64) -and (Test-Path $osslX64)) {
    Pass "OpenSSL static libs present for both ABIs"
} elseif (Test-Path $osslArm64) {
    Pass "OpenSSL static libs present for arm64 (x86_64 may be pending)"
} else {
    Warn "OpenSSL static libs not found at expected paths"
}

# ---- libssh2 static libs ----
Write-Host "[7/8] libssh2 static libs"
$ssh2Arm64 = Join-Path $PROJECT "libs\libssh2\arm64-v8a\libssh2.a"
$ssh2X64   = Join-Path $PROJECT "libs\libssh2\x86_64\libssh2.a"
if ((Test-Path $ssh2Arm64) -and (Test-Path $ssh2X64)) {
    Pass "libssh2 static libs present for both ABIs"
} elseif (Test-Path $ssh2Arm64) {
    Pass "libssh2 static libs present for arm64 (x86_64 may be pending)"
} else {
    Warn "libssh2 static libs not found"
}

# ---- DevEco SDK ----
Write-Host "[8/8] DevEco SDK environment"
$devecoSdk = $env:DEVECO_SDK_HOME
if (-not $devecoSdk) { $devecoSdk = "C:\Program Files\Huawei\DevEco Studio\sdk" }
if ($devecoSdk -and (Test-Path $devecoSdk)) {
    Pass "DevEco SDK found at $devecoSdk"
} else {
    Warn "DEVECO_SDK_HOME not set and default path not found. Set: `$env:DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'"
}

$nodePath = "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe"
$hvigorPath = "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js"
if (Test-Path $nodePath) { Pass "Node.exe found" } else { Warn "Node.exe not at $nodePath" }
if (Test-Path $hvigorPath) { Pass "hvigorw.js found" } else { Warn "hvigorw.js not at $hvigorPath" }

# ---- Summary ----
Write-Host ""
if ($EXIT -eq 0) {
    Write-Host "=== All checks passed ===" -ForegroundColor Green
} else {
    Write-Host "=== Some checks had warnings (see above). Default build (USE_REAL_FREERDP=OFF, default ABI) may still succeed. ===" -ForegroundColor Yellow
}
exit $EXIT
