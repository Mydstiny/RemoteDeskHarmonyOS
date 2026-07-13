param([string]$RepositoryRoot = (Join-Path $PSScriptRoot '..'))

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path $RepositoryRoot).Path
$metadataJson = & cargo metadata --format-version 1 --locked --manifest-path (Join-Path $root 'rustdesk_ffi/Cargo.toml')
if ($LASTEXITCODE -ne 0) { throw 'cargo metadata failed.' }
$metadata = $metadataJson | ConvertFrom-Json
$commit = (& git -C $root rev-parse HEAD).Trim()

$packages = [System.Collections.Generic.List[object]]::new()
$packages.Add([ordered]@{
  name = 'RemoteDeskHarmonyOS'
  SPDXID = 'SPDXRef-Package-RemoteDeskHarmonyOS'
  versionInfo = '1.0.5'
  downloadLocation = 'https://github.com/Mydstiny/RemoteDeskHarmonyOS'
  filesAnalyzed = $false
  licenseConcluded = 'AGPL-3.0-or-later'
  licenseDeclared = 'AGPL-3.0-or-later'
  copyrightText = 'Copyright 2026 Li Jiong and contributors'
})
foreach ($package in ($metadata.packages | Sort-Object name, version)) {
  if ([string]::IsNullOrWhiteSpace($package.license)) {
    throw "Cargo package has no declared license: $($package.name) $($package.version)"
  }
  $safe = ($package.name + '-' + $package.version) -replace '[^A-Za-z0-9.-]', '-'
  $packages.Add([ordered]@{
    name = $package.name
    SPDXID = "SPDXRef-Cargo-$safe"
    versionInfo = [string]$package.version
    downloadLocation = if ($package.source) { [string]$package.source } else { 'NOASSERTION' }
    filesAnalyzed = $false
    licenseConcluded = [string]$package.license
    licenseDeclared = [string]$package.license
    copyrightText = 'NOASSERTION'
  })
}
$native = @(
  @('RustDesk-protocol','93d064a9b0eb58ab94db88ff727a877ef773c0d8','AGPL-3.0','https://github.com/rustdesk/rustdesk'),
  @('FreeRDP-WinPR','dae8276ac7361b8d14f7b87d41163fe03dbb944e','Apache-2.0','https://github.com/FreeRDP/FreeRDP'),
  @('OpenSSL','bundled-ohos','Apache-2.0','https://www.openssl.org/'),
  @('FFmpeg','bundled-ohos','LGPL-2.1-or-later','https://ffmpeg.org/'),
  @('libssh2','1.11.1','BSD-3-Clause','https://www.libssh2.org/'),
  @('Mbed-TLS','bundled-ohos','Apache-2.0','https://github.com/Mbed-TLS/mbedtls'),
  @('Opus','bundled-ohos-fixed-point','BSD-3-Clause','https://opus-codec.org/'),
  @('Huawei-AGConnect-Auth','1.0.2','LicenseRef-Huawei-AGConnect','https://developer.huawei.com/')
)
foreach ($item in $native) {
  $id = ($item[0] -replace '[^A-Za-z0-9.-]', '-')
  $packages.Add([ordered]@{
    name = $item[0]; SPDXID = "SPDXRef-Native-$id"; versionInfo = $item[1]
    downloadLocation = $item[3]; filesAnalyzed = $false
    licenseConcluded = $item[2]; licenseDeclared = $item[2]
    copyrightText = 'See THIRD_PARTY_NOTICES.md'
  })
}
$document = [ordered]@{
  spdxVersion = 'SPDX-2.3'
  dataLicense = 'CC0-1.0'
  SPDXID = 'SPDXRef-DOCUMENT'
  name = "RemoteDeskHarmonyOS-$commit"
  documentNamespace = "https://github.com/Mydstiny/RemoteDeskHarmonyOS/spdx/$commit"
  creationInfo = [ordered]@{
    created = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    creators = @('Tool: scripts/generate_sbom.ps1', 'Organization: RemoteDeskHarmonyOS')
  }
  packages = $packages
}
$output = Join-Path $root 'docs/compliance/SBOM.spdx.json'
$json = $document | ConvertTo-Json -Depth 12
[IO.File]::WriteAllText($output, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
Write-Host "Wrote SPDX SBOM with $($packages.Count) packages to $output"
