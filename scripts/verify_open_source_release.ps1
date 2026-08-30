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
  'LICENSES/GPL-3.0-only.txt',
  'LICENSES/Apache-2.0.txt',
  'docs/compliance/SBOM.spdx.json',
  'docs/compliance/THIRD_PARTY_ARTIFACTS.sha256',
  'docs/compliance/OWNERSHIP_AND_RELICENSING.md',
  'docs/compliance/LICENSE_DECISION_RECORD.md',
  'docs/compliance/SOURCE_OFFER.md',
  'docs/compliance/FREERDP_OHOS_PROVENANCE.md',
  'docs/compliance/MOONLIGHT_COMMON_C_PROVENANCE.md',
  'docs/compliance/MOONLIGHT_ICON_PROVENANCE.md',
  'entry/src/main/cpp/moonlight/upstream/UPSTREAM.lock.json',
  'scripts/build_moonlight_common_vendor.sh',
  'scripts/build_moonlight_common_vendor.ps1',
  'scripts/verify_moonlight_vendor.py',
  'scripts/tests/test_freerdp_provenance.ps1',
  'rustdesk_vendor/libs/hbb_common/protos/UPSTREAM.yml',
  'rustdesk_vendor/libs/hbb_common/protos/NOTICE'
)
foreach ($relative in $required) {
  if (-not (Test-Path (Join-Path $root $relative))) {
    Add-Failure "Missing required compliance file: $relative"
  }
}

$moonlightIconRelative = 'entry/src/main/resources/base/media/icon_moonlight.svg'
$moonlightIconPath = Join-Path $root $moonlightIconRelative
$moonlightIconExpectedSha256 = '4f5ef547e33767287e3438a6d1598a1bdef6e49df4678a5f7f214ec58c9e5886'
if (-not (Test-Path $moonlightIconPath -PathType Leaf)) {
  Add-Failure "Missing Moonlight protocol icon: $moonlightIconRelative"
} elseif ((Get-NormalizedTextSha256 $moonlightIconPath) -ne
    $moonlightIconExpectedSha256) {
  Add-Failure 'Moonlight protocol icon changed without provenance review.'
}
$moonlightIconProvenancePath = Join-Path $root 'docs/compliance/MOONLIGHT_ICON_PROVENANCE.md'
if (Test-Path $moonlightIconProvenancePath -PathType Leaf) {
  $moonlightIconProvenance = Get-Content -Raw $moonlightIconProvenancePath
  if ($moonlightIconProvenance -notmatch '2e13ed9977bc31c73caf8428f08f58d793313ece' -or
      $moonlightIconProvenance -notmatch '6fd0ee4fe5b4aad5abaa5d5c9acb9f7d1bda0abadfe9d1582115de9b4ba16aa2' -or
      $moonlightIconProvenance -notmatch $moonlightIconExpectedSha256) {
    Add-Failure 'Moonlight protocol icon provenance is incomplete or stale.'
  }
}
$artifactHashPath = Join-Path $root 'docs/compliance/THIRD_PARTY_ARTIFACTS.sha256'
if (Test-Path $artifactHashPath -PathType Leaf) {
  $moonlightIconHashRecord = $moonlightIconExpectedSha256 + ' *' + $moonlightIconRelative
  $artifactHashLines = @(Get-Content $artifactHashPath)
  if (@($artifactHashLines | Where-Object { $_ -eq $moonlightIconHashRecord }).Count -ne 1) {
    Add-Failure 'Moonlight protocol icon artifact hash record is missing or duplicated.'
  }
}
$reusePath = Join-Path $root 'REUSE.toml'
if (Test-Path $reusePath -PathType Leaf) {
  $reuseMetadata = Get-Content -Raw $reusePath
  $moonlightReusePattern = '(?s)\[\[annotations\]\]\s*path\s*=\s*"entry/src/main/resources/base/media/icon_moonlight\.svg"\s*precedence\s*=\s*"override"\s*SPDX-FileCopyrightText\s*=\s*"Moonlight Game Streaming Project contributors"\s*SPDX-License-Identifier\s*=\s*"GPL-3\.0-only"'
  if ($reuseMetadata -notmatch $moonlightReusePattern) {
    Add-Failure 'Moonlight protocol icon REUSE override is missing or inconsistent.'
  }
}
$gpl3LicensePath = Join-Path $root 'LICENSES/GPL-3.0-only.txt'
if (Test-Path $gpl3LicensePath -PathType Leaf) {
  $gpl3ExpectedSha256 = '589ed823e9a84c56feb95ac58e7cf384626b9cbf4fda2a907bc36e103de1bad2'
  if ((Get-NormalizedTextSha256 $gpl3LicensePath) -ne
      $gpl3ExpectedSha256) {
    Add-Failure 'GPL-3.0-only license text is missing or changed.'
  }
}
$thirdPartyNoticePath = Join-Path $root 'THIRD_PARTY_NOTICES.md'
if (Test-Path $thirdPartyNoticePath -PathType Leaf) {
  $thirdPartyNotice = Get-Content -Raw $thirdPartyNoticePath
  if ($thirdPartyNotice -notmatch 'MOONLIGHT_ICON_NOTICE_BEGIN' -or
      $thirdPartyNotice -notmatch 'Moonlight Game Streaming Project contributors' -or
      $thirdPartyNotice -notmatch 'GPL-3\.0-only' -or
      $thirdPartyNotice -notmatch '2e13ed9977bc31c73caf8428f08f58d793313ece' -or
      $thirdPartyNotice -notmatch '6fd0ee4fe5b4aad5abaa5d5c9acb9f7d1bda0abadfe9d1582115de9b4ba16aa2' -or
      $thirdPartyNotice -notmatch 'MOONLIGHT_ICON_NOTICE_END') {
    Add-Failure 'Moonlight protocol icon NOTICE entry is missing or inconsistent.'
  }
}
$sourceOfferPath = Join-Path $root 'docs/compliance/SOURCE_OFFER.md'
if (Test-Path $sourceOfferPath -PathType Leaf) {
  $sourceOffer = Get-Content -Raw $sourceOfferPath
  if ($sourceOffer -notmatch 'entry/src/main/resources/base/media/icon_moonlight\.svg' -or
      $sourceOffer -notmatch 'GPL-3\.0-only' -or
      $sourceOffer -notmatch '2e13ed9977bc31c73caf8428f08f58d793313ece' -or
      $sourceOffer -notmatch '6fd0ee4fe5b4aad5abaa5d5c9acb9f7d1bda0abadfe9d1582115de9b4ba16aa2' -or
      $sourceOffer -notmatch $moonlightIconExpectedSha256) {
    Add-Failure 'Moonlight protocol icon source offer is missing or inconsistent.'
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
$cloudSchemaOverride = 'entry/src/main/resources/rawfile/arkdata/cloud/cloud_schema.json'
if (Test-Path (Join-Path $root $cloudSchemaOverride)) {
  Add-Failure 'A bundled ArkData cloud schema overrides the authoritative Huawei Cloud Space container schema.'
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
  if ((Get-Item -Force -LiteralPath $path).Length -gt 2MB) { continue }
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
$freerdpBaseRevision = 'dae8276ac7361b8d14f7b87d41163fe03dbb944e'
$freerdpPatchedTree = '24a880d801892e3d6f1b8c78534e51eaeca8b0d8'
$freerdpGitlink = (& git -C $root ls-files --stage -- freerdp).Trim()
if (-not $freerdpGitlink.StartsWith("160000 $freerdpBaseRevision ")) {
  Add-Failure 'FreeRDP gitlink is not locked to the public patch base.'
}
$freerdpPatchExpectations = @{
  'patches/freerdp-ohos/0001-fix-omit-TLS-SNI-for-IP-literals.patch' = '31b34d9da81d30faf223a9e919264ab2638e2c0f102a92fc976263d0a0fb6812'
  'patches/freerdp-ohos/0002-Add-bounded-dual-stack-TCP-racing.patch' = '577df010d9c75307f79fe7055b97ee41c8f91a25b42dbc3fdd0b97cb21a8948e'
  'patches/freerdp-ohos/0003-Add-gateway-safe-dual-stack-routing.patch' = '0b232174a4ff599bc0d5feff81d56c776ee9a2a1752c64b7badd64c272fa2c86'
  'patches/freerdp-ohos/0004-Fix-thread-termination-on-OHOS.patch' = '4f082d9358e0c11599977f24eacf092d2305f11825006061b13411213277c157'
  'patches/freerdp-ohos/0005-Add-deterministic-IPv6-gateway-and-resolver-tests.patch' = '17c5a149ac1feed76f0ae26fb09248472fdc9b2ab2d543ddb69e7d23d1ddc23c'
}
foreach ($relative in $freerdpPatchExpectations.Keys) {
  $path = Join-Path $root $relative
  if (-not (Test-Path $path -PathType Leaf) -or
      (Get-NormalizedTextSha256 $path) -ne $freerdpPatchExpectations[$relative]) {
    Add-Failure "FreeRDP patch is missing or changed without provenance review: $relative"
  }
}
$freerdpProvenancePath = Join-Path $root 'docs/compliance/FREERDP_OHOS_PROVENANCE.md'
if (-not (Test-Path $freerdpProvenancePath -PathType Leaf)) {
  Add-Failure 'FreeRDP OHOS provenance document is missing.'
} else {
  $freerdpProvenance = Get-Content -Raw $freerdpProvenancePath
  if ($freerdpProvenance -notmatch $freerdpBaseRevision -or
      $freerdpProvenance -notmatch $freerdpPatchedTree -or
      $freerdpProvenance -notmatch 'patches/freerdp-ohos') {
    Add-Failure 'FreeRDP OHOS base and patch provenance is incomplete or stale.'
  }
}
$thirdPartyNotices = Get-Content -Raw (Join-Path $root 'THIRD_PARTY_NOTICES.md')
if ($thirdPartyNotices -notmatch $freerdpBaseRevision -or
    $thirdPartyNotices -notmatch $freerdpPatchedTree -or
    $thirdPartyNotices -notmatch 'patches/freerdp-ohos/') {
  Add-Failure 'Third-party notices do not identify the effective FreeRDP patch inputs.'
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
    $moonlightIconPackage = @($sbom.packages | Where-Object {
      $_.SPDXID -eq 'SPDXRef-Package-Moonlight-Qt-Icon'
    })
    if ($moonlightIconPackage.Count -ne 1 -or
        $moonlightIconPackage[0].versionInfo -ne '2e13ed9977bc31c73caf8428f08f58d793313ece' -or
        $moonlightIconPackage[0].filesAnalyzed -ne $true -or
        $moonlightIconPackage[0].packageVerificationCode.packageVerificationCodeValue -ne
          'b87433cda9e9811ef51c3a784e6c31c3a3b00a82' -or
        $moonlightIconPackage[0].licenseDeclared -ne 'GPL-3.0-only' -or
        $moonlightIconPackage[0].licenseConcluded -ne 'GPL-3.0-only' -or
        $moonlightIconPackage[0].copyrightText -ne 'Moonlight Game Streaming Project contributors') {
      Add-Failure 'SPDX Moonlight icon package metadata is missing or inconsistent.'
    }
    $moonlightIconFile = @($sbom.files | Where-Object {
      $_.SPDXID -eq 'SPDXRef-File-Moonlight-Qt-Icon'
    })
    $moonlightIconChecksums = @()
    $moonlightIconLicenses = @()
    if ($moonlightIconFile.Count -eq 1) {
      $moonlightIconChecksums = @($moonlightIconFile[0].checksums | Where-Object {
        $_.algorithm -eq 'SHA256' -and $_.checksumValue -eq $moonlightIconExpectedSha256
      })
      $moonlightIconLicenses = @($moonlightIconFile[0].licenseInfoInFiles | Where-Object {
        $_ -eq 'GPL-3.0-only'
      })
    }
    if ($moonlightIconFile.Count -ne 1 -or
        $moonlightIconFile[0].fileName -ne $moonlightIconRelative -or
        $moonlightIconFile[0].licenseConcluded -ne 'GPL-3.0-only' -or
        $moonlightIconFile[0].copyrightText -ne 'Moonlight Game Streaming Project contributors' -or
        $moonlightIconChecksums.Count -ne 1 -or $moonlightIconLicenses.Count -ne 1) {
      Add-Failure 'SPDX Moonlight icon file metadata is missing or inconsistent.'
    }
    $moonlightIconContains = @($sbom.relationships | Where-Object {
      $_.spdxElementId -eq 'SPDXRef-Package-Moonlight-Qt-Icon' -and
      $_.relationshipType -eq 'CONTAINS' -and
      $_.relatedSpdxElement -eq 'SPDXRef-File-Moonlight-Qt-Icon'
    })
    $moonlightIconDepends = @($sbom.relationships | Where-Object {
      $_.spdxElementId -eq 'SPDXRef-Package-RemoteDeskHarmonyOS' -and
      $_.relationshipType -eq 'DEPENDS_ON' -and
      $_.relatedSpdxElement -eq 'SPDXRef-Package-Moonlight-Qt-Icon'
    })
    if ($moonlightIconContains.Count -ne 1 -or $moonlightIconDepends.Count -ne 1) {
      Add-Failure 'SPDX Moonlight icon relationships are missing or duplicated.'
    }
  } catch {
    Add-Failure 'SPDX SBOM is not valid JSON.'
  }
}

$moonlightVerifier = Join-Path $root 'scripts/verify_moonlight_vendor.py'
$pythonCommand = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $pythonCommand) {
  $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
}
if (-not $pythonCommand) {
  Add-Failure 'Python is required for the Moonlight vendored-source gate.'
} elseif (Test-Path $moonlightVerifier) {
  $moonlightOutput = @(& $pythonCommand.Source $moonlightVerifier 2>&1)
  if ($LASTEXITCODE -ne 0) {
    Add-Failure ('Moonlight vendored-source gate failed: ' + ($moonlightOutput -join '; '))
  }
} else {
  Add-Failure 'Moonlight vendored-source verifier is missing.'
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
  $freerdpProvenanceGate = Join-Path $root 'scripts/tests/test_freerdp_provenance.ps1'
  try {
    $freerdpProvenanceOutput = @(& $freerdpProvenanceGate 2>&1)
    if ($LASTEXITCODE -ne 0) {
      Add-Failure ('Release blocked: FreeRDP provenance gate failed: ' +
        ($freerdpProvenanceOutput -join '; '))
    }
  } catch {
    Add-Failure ('Release blocked: FreeRDP provenance gate failed: ' + $_.Exception.Message)
  }
  $moonlightBuildScript = Join-Path $root 'scripts/build_moonlight_common_vendor.ps1'
  try {
    $moonlightBuildOutput = @(& $moonlightBuildScript -RepositoryRoot $root 2>&1)
    if ($LASTEXITCODE -ne 0) {
      Add-Failure ('Release blocked: Moonlight dual-ABI build gate failed: ' + ($moonlightBuildOutput -join '; '))
    }
  } catch {
    Add-Failure ('Release blocked: Moonlight dual-ABI build gate failed: ' + $_.Exception.Message)
  }
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
