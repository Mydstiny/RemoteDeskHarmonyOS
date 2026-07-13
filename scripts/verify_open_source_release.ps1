param(
  [ValidateSet('Light', 'Release')]
  [string]$Mode = 'Light',
  [string]$RepositoryRoot = (Join-Path $PSScriptRoot '..')
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path $RepositoryRoot).Path
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure([string]$Message) {
  $script:failures.Add($Message)
}

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

$required = @(
  'LICENSE',
  'NOTICE',
  'THIRD_PARTY_NOTICES.md',
  'REUSE.toml',
  'LICENSES/AGPL-3.0-or-later.txt',
  'LICENSES/Apache-2.0.txt',
  'docs/compliance/SBOM.spdx.json',
  'docs/compliance/THIRD_PARTY_ARTIFACTS.sha256',
  'docs/compliance/OWNERSHIP_AND_RELICENSING.md',
  'docs/compliance/LICENSE_DECISION_RECORD.md',
  'docs/compliance/SOURCE_OFFER.md',
  'rustdesk_vendor/libs/hbb_common/protos/UPSTREAM.yml',
  'rustdesk_vendor/libs/hbb_common/protos/NOTICE'
)
foreach ($relative in $required) {
  if (-not (Test-Path (Join-Path $root $relative))) {
    Add-Failure "Missing required compliance file: $relative"
  }
}

if (Test-Path (Join-Path $root 'LICENSE')) {
  $license = Get-Content -Raw (Join-Path $root 'LICENSE')
  if ($license -notmatch 'GNU AFFERO GENERAL PUBLIC LICENSE' -or
      $license -notmatch 'Version 3, 19 November 2007') {
    Add-Failure 'Root LICENSE is not the complete AGPLv3 text.'
  }
}

$tracked = @(& git -C $root ls-files)
if ($LASTEXITCODE -ne 0) {
  Add-Failure 'Unable to enumerate tracked files.'
}
foreach ($relative in $required) {
  if ($tracked -notcontains $relative) {
    Add-Failure "Required compliance file is not tracked: $relative"
  }
}
$forbidden = @(
  'build-profile.json5',
  'local.properties',
  'entry/src/main/resources/rawfile/agconnect-services.json'
)
foreach ($relative in $forbidden) {
  if ($tracked -contains $relative) {
    Add-Failure "Private/local configuration is tracked: $relative"
  }
}
$localArtifactPatterns = @(
  '^\.planning/',
  '^\.superpowers/',
  '^logs/',
  '^(HANDOFF|findings|progress|task_plan)\.md$',
  '(^|/)ssh_log\.txt$'
)
foreach ($relative in $tracked) {
  foreach ($pattern in $localArtifactPatterns) {
    if ($relative -match $pattern) {
      Add-Failure "Local agent/session artifact is tracked: $relative"
    }
  }
}

$textExtensions = @('.ets','.ts','.js','.json','.json5','.toml','.yml','.yaml','.md','.ps1','.sh','.cpp','.c','.h','.hpp','.proto','.txt','.properties')
$tokenPatterns = @(
  'gh[pousr]_[A-Za-z0-9_]{20,}',
  'AKIA[0-9A-Z]{16}',
  '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----',
  '(?i)(client_secret|api_key|storePassword|keyPassword)\s*[:=]\s*["''][^"''\r\n]{12,}["'']'
)
$privateKeyAllow = @(
  'entry/src/main/cpp/ssh/ssh_key_tool.cpp',
  'entry/src/main/ets/model/SshKey.ets',
  'entry/src/ohosTest/ets/test/CloudSync.test.ets',
  'entry/src/test/CloudStore.test.ets',
  'scripts/verify_open_source_release.ps1'
)
foreach ($relative in $tracked) {
  $path = Join-Path $root $relative
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
  if ((Get-Item -LiteralPath $path).Length -gt 2MB) { continue }
  if ($textExtensions -notcontains ([IO.Path]::GetExtension($relative))) { continue }
  $content = Get-Content -Raw -LiteralPath $path -ErrorAction SilentlyContinue
  if ($null -eq $content) { continue }
  for ($i = 0; $i -lt $tokenPatterns.Count; $i++) {
    if ($content -match $tokenPatterns[$i]) {
      if ($i -eq 2 -and $privateKeyAllow -contains $relative) { continue }
      if ($relative -like '*.example.json' -or $relative -like '*.example.json5') { continue }
      Add-Failure "Potential secret pattern $($i + 1) in tracked file: $relative"
    }
  }
}

$protoExpectations = @{
  'rustdesk_vendor/libs/hbb_common/protos/message.proto' = 'f3c2c1e3478bc020337a80aa63d8091033d959a194401294a1cabae7472b4ceb'
  'rustdesk_vendor/libs/hbb_common/protos/rendezvous.proto' = 'ea98b0150971f226a0281f8aa5cfbecc404be3f12723ef6f20f919fb7819bd78'
}
foreach ($relative in $protoExpectations.Keys) {
  $path = Join-Path $root $relative
  if (-not (Test-Path $path)) {
    Add-Failure "Missing RustDesk protocol input: $relative"
    continue
  }
  $actual = Get-NormalizedTextSha256 $path
  if ($actual -ne $protoExpectations[$relative]) {
    Add-Failure "RustDesk protocol hash changed without provenance update: $relative"
  }
}

$cargoToml = Get-Content -Raw (Join-Path $root 'rustdesk_ffi/Cargo.toml')
if ($cargoToml -notmatch 'license\s*=\s*"AGPL-3.0-or-later"') {
  Add-Failure 'rustdesk_ffi Cargo license must be AGPL-3.0-or-later.'
}
$entryPackage = Get-Content -Raw (Join-Path $root 'entry/oh-package.json5')
if ($entryPackage -notmatch '"license"\s*:\s*"AGPL-3.0-or-later"') {
  Add-Failure 'entry package license metadata is missing.'
}
$gitmodules = Get-Content -Raw (Join-Path $root '.gitmodules')
if ($gitmodules -notmatch 'https://github.com/Mydstiny/RemoteDeskHarmonyOS.git' -or
    $gitmodules -notmatch 'branch\s*=\s*freerdp-ohos') {
  Add-Failure 'FreeRDP OHOS submodule does not have a public reproducible source.'
}
$about = Get-Content -Raw (Join-Path $root 'entry/src/main/ets/components/AboutSettingsSheet.ets')
if ($about -notmatch 'AGPL-3.0-or-later' -or
    $about -notmatch 'https://github.com/Mydstiny/RemoteDeskHarmonyOS') {
  Add-Failure 'About disclosure does not identify AGPL and the source repository.'
}

$sbomPath = Join-Path $root 'docs/compliance/SBOM.spdx.json'
if (Test-Path $sbomPath) {
  try {
    $sbom = Get-Content -Raw $sbomPath | ConvertFrom-Json
    if ($sbom.spdxVersion -ne 'SPDX-2.3' -or $sbom.packages.Count -lt 10) {
      Add-Failure 'SPDX SBOM is incomplete.'
    }
    if (@($sbom.packages | Where-Object { $_.licenseDeclared -eq 'NOASSERTION' }).Count -gt 0) {
      Add-Failure 'SPDX SBOM contains packages with NOASSERTION license.'
    }
  } catch {
    Add-Failure 'SPDX SBOM is not valid JSON.'
  }
}

$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$diffCheck = @(& git -C $root diff --check 2>&1)
$diffExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorAction
if ($diffExitCode -ne 0) {
  Add-Failure ('git diff --check failed: ' + ($diffCheck -join '; '))
}

if ($Mode -eq 'Release') {
  $approvalPath = Join-Path $root 'docs/compliance/RELEASE_APPROVAL.json'
  $approval = Get-Content -Raw $approvalPath | ConvertFrom-Json
  if (-not $approval.credentialsRotated) {
    Add-Failure 'Release blocked: exposed credentials have not been confirmed rotated.'
  }
  if (-not $approval.deviceMatrixVerified) {
    Add-Failure 'Release blocked: full device matrix is not verified.'
  }
  if (-not $env:REMOTE_DESKTOP_PRIVATE_BUILD_PROFILE) {
    Add-Failure 'Release blocked: REMOTE_DESKTOP_PRIVATE_BUILD_PROFILE is not set.'
  }
}

if ($failures.Count -gt 0) {
  Write-Error ("Open-source compliance gate failed:" + [Environment]::NewLine + ' - ' + ($failures -join ([Environment]::NewLine + ' - ')))
  exit 1
}

Write-Host "Open-source compliance gate passed ($Mode)."
exit 0
