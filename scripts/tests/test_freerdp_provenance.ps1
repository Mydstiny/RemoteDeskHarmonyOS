$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modules = Join-Path $repo '.gitmodules'
$url = (& git config -f $modules --get submodule.freerdp.url).Trim()
$branch = (& git config -f $modules --get submodule.freerdp.branch).Trim()
if ($url -ne 'https://github.com/Mydstiny/RemoteDeskHarmonyOS.git') {
  throw "FreeRDP submodule source is not the public repository: $url"
}
if ($branch -ne 'freerdp-ohos') {
  throw "FreeRDP submodule branch is not locked to freerdp-ohos: $branch"
}
$expectedArtifacts = @{
  'libs/freerdp-ohos/arm64-v8a/libfreerdp3.a' = 'af61519e06fb201970aa1d6dc79251b6432e7eeb7c75d806c529dbc41713e9fb'
  'libs/freerdp-ohos/arm64-v8a/libfreerdp-client-channels.a' = '23393361cdca6a22b5bfd19b98044777575bfea4a205bb81e1c2a1fffc49ec39'
  'libs/freerdp-ohos/arm64-v8a/libwinpr3.a' = '8fc0ea400753fd47566ee94b99967ff640c6a9c0880420ce4b5d0e4f33521e26'
  'libs/freerdp-ohos/x86_64/libfreerdp3.a' = '4322a39160a75b236d74a9fd35e76dc85775449fc0bc536fb067ecbac97dbacf'
  'libs/freerdp-ohos/x86_64/libfreerdp-client-channels.a' = '6590726ad8fa28860ebb773f240bd1487d4dcd4de5b06361933f06368df3c306'
  'libs/freerdp-ohos/x86_64/libwinpr3.a' = 'eebf286a6573245a97ff5a26cba20ad1141378229fa6ddfda93635da5752abcb'
}
foreach ($relative in $expectedArtifacts.Keys) {
  $path = Join-Path $repo $relative
  if (-not (Test-Path $path -PathType Leaf)) {
    throw "FreeRDP prebuilt artifact is missing: $relative"
  }
  $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $expectedArtifacts[$relative]) {
    throw "FreeRDP prebuilt artifact hash mismatch: $relative"
  }
}
foreach ($arch in @('arm64-v8a', 'x86_64')) {
  $config = Join-Path $repo "libs/freerdp-ohos/$arch/include/freerdp/config.h"
  if ((Get-Content -Raw $config) -notmatch '(?m)^#define CHANNEL_DISP_CLIENT\s*$') {
    throw "FreeRDP Display Control client is not enabled for $arch"
  }
  if ((Get-Content -Raw $config) -notmatch '(?m)^#define CHANNEL_DRIVE_CLIENT\s*$') {
    throw "FreeRDP drive client is not enabled for $arch"
  }
}
Write-Host 'FreeRDP public provenance test passed.'
