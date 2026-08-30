$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$expectedRevision = 'fc914f5eb3c9def5f757469650f5b4cb2ae72cec'
$modules = Join-Path $repo '.gitmodules'
$url = (& git config -f $modules --get submodule.freerdp.url).Trim()
$branch = (& git config -f $modules --get submodule.freerdp.branch).Trim()
if ($url -ne 'https://github.com/Mydstiny/RemoteDeskHarmonyOS.git') {
  throw "FreeRDP submodule source is not the public repository: $url"
}
if ($branch -ne 'freerdp-ohos') {
  throw "FreeRDP submodule branch is not locked to freerdp-ohos: $branch"
}
$sourceRevision = (& git -C (Join-Path $repo 'freerdp') rev-parse HEAD).Trim()
if ($sourceRevision -ne $expectedRevision) {
  throw "FreeRDP source revision mismatch: $sourceRevision"
}
$indexedGitlink = (& git -C $repo ls-files --stage -- freerdp).Trim()
if (-not $indexedGitlink.StartsWith("160000 $expectedRevision ")) {
  throw "FreeRDP gitlink is not locked to $expectedRevision"
}
$sourceStatus = @(& git -C (Join-Path $repo 'freerdp') status --porcelain)
if ($sourceStatus.Count -ne 0) {
  throw 'FreeRDP source worktree is dirty; artifacts cannot be attributed to one revision.'
}
$expectedArtifacts = @{
  'libs/freerdp-ohos/arm64-v8a/libfreerdp3.a' = '26648c05c7f9689038d36bae1f37ad351e64abd4938cc16d587465dd8e6cf8e9'
  'libs/freerdp-ohos/arm64-v8a/libfreerdp-client-channels.a' = '6f17f1ce1b1955ccfa436fd891636290605c9475764e224228892dfaf09a3602'
  'libs/freerdp-ohos/arm64-v8a/libwinpr3.a' = '143d58beb75fb32fa4e7401fd8b7fd47c3ed6d129546a025480055ecd61d2853'
  'libs/freerdp-ohos/x86_64/libfreerdp3.a' = 'a7a2d5203a45c3ac8c49d42afcfa08a98597fa128691dd8001fe3f1aa1664072'
  'libs/freerdp-ohos/x86_64/libfreerdp-client-channels.a' = 'ff05605c6dea30e7f2b18f7495dcc20e119459c710033c9fb1b3b6a01ebab231'
  'libs/freerdp-ohos/x86_64/libwinpr3.a' = '494c6a5dd26f9b318ac8a35aab9782a197f4587649fef3feefa8bf293036e2fd'
}
$inventory = Get-Content (Join-Path $repo 'docs/compliance/THIRD_PARTY_ARTIFACTS.sha256')
$forbiddenPathMarkers = @(
  $repo.Replace('\', '/'),
  '/Users/',
  'C:/Users/',
  'C:\Users\',
  'RemoteDeskHarmonyOS',
  'remotedesk-freerdp-ohos.'
)
foreach ($relative in $expectedArtifacts.Keys) {
  $path = Join-Path $repo $relative
  if (-not (Test-Path $path -PathType Leaf)) {
    throw "FreeRDP prebuilt artifact is missing: $relative"
  }
  $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $expectedArtifacts[$relative]) {
    throw "FreeRDP prebuilt artifact hash mismatch: $relative"
  }
  $inventoryEntry = "$($expectedArtifacts[$relative]) *$relative"
  if ($inventory -notcontains $inventoryEntry) {
    throw "FreeRDP artifact inventory mismatch: $relative"
  }
  $archiveText = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($path))
  foreach ($marker in $forbiddenPathMarkers) {
    if ($archiveText.Contains($marker)) {
      throw "FreeRDP artifact contains a machine-specific path marker '$marker': $relative"
    }
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
  $settingsKeys = Join-Path $repo "libs/freerdp-ohos/$arch/include/freerdp/settings_keys.h"
  if ((Get-Content -Raw $settingsKeys) -notmatch '(?m)^\s*FreeRDP_GatewayConnectHostname = 2027,\s*$') {
    throw "FreeRDP gateway connect-host setting is missing for $arch"
  }
}
Write-Host 'FreeRDP public provenance test passed.'
