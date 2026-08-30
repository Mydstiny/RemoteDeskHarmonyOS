$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$expectedBaseRevision = 'dae8276ac7361b8d14f7b87d41163fe03dbb944e'
$expectedPatchedTree = '54cc9b12e3040bba73773a5439d4f8023d46ac7a'
$expectedVersion = "$expectedBaseRevision+tree.$expectedPatchedTree"
$expectedPatchSha256 = [ordered]@{
  'patches/freerdp-ohos/0001-fix-omit-TLS-SNI-for-IP-literals.patch' = '31b34d9da81d30faf223a9e919264ab2638e2c0f102a92fc976263d0a0fb6812'
  'patches/freerdp-ohos/0002-Add-bounded-dual-stack-TCP-racing.patch' = '577df010d9c75307f79fe7055b97ee41c8f91a25b42dbc3fdd0b97cb21a8948e'
  'patches/freerdp-ohos/0003-Add-gateway-safe-dual-stack-routing.patch' = '0b232174a4ff599bc0d5feff81d56c776ee9a2a1752c64b7badd64c272fa2c86'
  'patches/freerdp-ohos/0004-Fix-thread-termination-on-OHOS.patch' = '4f082d9358e0c11599977f24eacf092d2305f11825006061b13411213277c157'
}
$patches = @($expectedPatchSha256.Keys)

function Get-NormalizedTextSha256([string]$Path) {
  $text = [IO.File]::ReadAllText($Path)
  $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes($normalized)
  $stream = [IO.MemoryStream]::new($bytes, $false)
  try {
    return (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash.ToLowerInvariant()
  } finally {
    $stream.Dispose()
  }
}
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
if ($sourceRevision -ne $expectedBaseRevision) {
  throw "FreeRDP source revision mismatch: $sourceRevision"
}
$indexedGitlink = (& git -C $repo ls-files --stage -- freerdp).Trim()
if (-not $indexedGitlink.StartsWith("160000 $expectedBaseRevision ")) {
  throw "FreeRDP gitlink is not locked to public base $expectedBaseRevision"
}
$sourceStatus = @(& git -C (Join-Path $repo 'freerdp') status --porcelain)
if ($sourceStatus.Count -ne 0) {
  throw 'FreeRDP source worktree is dirty; artifacts cannot be attributed to one revision.'
}
foreach ($relative in $patches) {
  $path = Join-Path $repo $relative
  if (-not (Test-Path $path -PathType Leaf)) {
    throw "FreeRDP patch is missing: $relative"
  }
  if ((Get-NormalizedTextSha256 $path) -ne $expectedPatchSha256[$relative]) {
    throw "FreeRDP patch hash mismatch: $relative"
  }
}
$verificationRoot = Join-Path ([IO.Path]::GetTempPath()) (
  'remotedesk-freerdp-provenance-' + [Guid]::NewGuid().ToString('N'))
try {
  & git clone --quiet --no-checkout (Join-Path $repo 'freerdp') $verificationRoot
  if ($LASTEXITCODE -ne 0) { throw 'Unable to clone the pinned FreeRDP base for patch verification.' }
  & git -C $verificationRoot checkout --quiet --detach $expectedBaseRevision
  if ($LASTEXITCODE -ne 0) { throw 'Unable to check out the pinned FreeRDP public base.' }
  foreach ($relative in $patches) {
    & git -C $verificationRoot apply --index --whitespace=error-all (Join-Path $repo $relative)
    if ($LASTEXITCODE -ne 0) { throw "Unable to apply FreeRDP patch: $relative" }
  }
  $actualPatchedTree = (& git -C $verificationRoot write-tree).Trim()
  if ($LASTEXITCODE -ne 0 -or $actualPatchedTree -ne $expectedPatchedTree) {
    throw "FreeRDP patched tree mismatch: $actualPatchedTree"
  }
} finally {
  if (Test-Path $verificationRoot) {
    Remove-Item -LiteralPath $verificationRoot -Recurse -Force
  }
}
$expectedArtifacts = @{
  'libs/freerdp-ohos/arm64-v8a/libfreerdp3.a' = '26648c05c7f9689038d36bae1f37ad351e64abd4938cc16d587465dd8e6cf8e9'
  'libs/freerdp-ohos/arm64-v8a/libfreerdp-client-channels.a' = '6f17f1ce1b1955ccfa436fd891636290605c9475764e224228892dfaf09a3602'
  'libs/freerdp-ohos/arm64-v8a/libwinpr3.a' = 'e13b05ec24732d835a564fb99df43dbe0ed221f285469569958322b7cebedadf'
  'libs/freerdp-ohos/x86_64/libfreerdp3.a' = 'a7a2d5203a45c3ac8c49d42afcfa08a98597fa128691dd8001fe3f1aa1664072'
  'libs/freerdp-ohos/x86_64/libfreerdp-client-channels.a' = 'ff05605c6dea30e7f2b18f7495dcc20e119459c710033c9fb1b3b6a01ebab231'
  'libs/freerdp-ohos/x86_64/libwinpr3.a' = '4a63ba47876ea46d9158a8149c17f43be2d84b7b7239dfc89524d1d4281ccf1f'
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
  if ($relative.EndsWith('/libwinpr3.a') -and $archiveText.Contains('pthread_cancel')) {
    throw "FreeRDP WinPR artifact references unsupported OHOS symbol pthread_cancel: $relative"
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

$sbom = Get-Content -Raw (Join-Path $repo 'docs/compliance/SBOM.spdx.json') |
  ConvertFrom-Json
$freerdpPackages = @($sbom.packages | Where-Object {
  $_.SPDXID -eq 'SPDXRef-Native-FreeRDP-WinPR'
})
if ($freerdpPackages.Count -ne 1 -or
    $freerdpPackages[0].name -ne 'FreeRDP-WinPR' -or
    $freerdpPackages[0].versionInfo -ne $expectedVersion -or
    $freerdpPackages[0].downloadLocation -ne 'https://github.com/Mydstiny/RemoteDeskHarmonyOS' -or
    $freerdpPackages[0].licenseDeclared -ne 'Apache-2.0' -or
    $freerdpPackages[0].licenseConcluded -ne 'Apache-2.0') {
  throw 'FreeRDP SBOM package metadata is missing or stale.'
}

$sourceOffer = Get-Content -Raw (Join-Path $repo 'docs/compliance/SOURCE_OFFER.md')
foreach ($expectedSourceOfferValue in @(
  $expectedBaseRevision,
  $expectedPatchedTree,
  'patches/freerdp-ohos/',
  'docs/compliance/FREERDP_OHOS_PROVENANCE.md'
)) {
  if (-not $sourceOffer.Contains($expectedSourceOfferValue)) {
    throw "FreeRDP source offer is missing '$expectedSourceOfferValue'."
  }
}

$manifestSchema = Get-Content -Raw (
  Join-Path $repo 'docs/compliance/RELEASE_MANIFEST.schema.json') | ConvertFrom-Json
$manifestRequired = @($manifestSchema.required)
$manifestProperties = @($manifestSchema.properties.PSObject.Properties.Name)
$freerdpManifestFields = @(
  'freerdpSubmoduleCommit',
  'freerdpPatchedTree',
  'freerdpPatchSha256'
)
foreach ($field in $freerdpManifestFields) {
  if ($manifestRequired -notcontains $field -or $manifestProperties -notcontains $field) {
    throw "Release manifest schema does not require FreeRDP field '$field'."
  }
}
if ($manifestSchema.properties.freerdpSubmoduleCommit.pattern -ne '^[0-9a-f]{40}$' -or
    $manifestSchema.properties.freerdpPatchedTree.pattern -ne '^[0-9a-f]{40}$' -or
    $manifestSchema.properties.freerdpPatchSha256.minItems -ne 4 -or
    $manifestSchema.properties.freerdpPatchSha256.maxItems -ne 4 -or
    $manifestSchema.properties.freerdpPatchSha256.items.pattern -ne '^[0-9a-f]{64}$') {
  throw 'Release manifest FreeRDP field constraints are incomplete or stale.'
}

$manifestExample = Get-Content -Raw (
  Join-Path $repo 'docs/compliance/RELEASE_MANIFEST.example.json') | ConvertFrom-Json
if ($manifestExample.freerdpSubmoduleCommit -ne $expectedBaseRevision -or
    $manifestExample.freerdpPatchedTree -ne $expectedPatchedTree -or
    @($manifestExample.freerdpPatchSha256).Count -ne $patches.Count) {
  throw 'Release manifest example FreeRDP provenance is incomplete or stale.'
}
for ($index = 0; $index -lt $patches.Count; $index++) {
  if ($manifestExample.freerdpPatchSha256[$index] -ne
      $expectedPatchSha256[$patches[$index]]) {
    throw "Release manifest example FreeRDP patch hash mismatch at index $index."
  }
}
Write-Host 'FreeRDP public base + patch provenance test passed.'
