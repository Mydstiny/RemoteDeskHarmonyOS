param([string]$RepositoryRoot = (Join-Path $PSScriptRoot '..'))

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path $RepositoryRoot).Path
$output = Join-Path $root 'docs/compliance/THIRD_PARTY_ARTIFACTS.sha256'
$files = @(
  Get-ChildItem (Join-Path $root 'libs') -Recurse -File |
    Where-Object { $_.Extension -in @('.a', '.so', '.lib', '.dll') }
)
$files += @(
  Get-Item (Join-Path $root 'rustdesk_vendor/libs/hbb_common/protos/message.proto')
  Get-Item (Join-Path $root 'rustdesk_vendor/libs/hbb_common/protos/rendezvous.proto')
)
$moonlightVendorRoot = Join-Path $root 'entry/src/main/cpp/moonlight/upstream/moonlight-common-c'
if (Test-Path $moonlightVendorRoot) {
  $files += @(Get-ChildItem $moonlightVendorRoot -Recurse -File)
}
$totpAssetRoot = Join-Path $root 'entry/src/main/resources/rawfile/totp-brands'
if (Test-Path $totpAssetRoot) {
  $files += @(Get-ChildItem $totpAssetRoot -Recurse -File)
}
$totpManifest = Join-Path $root 'entry/src/main/resources/rawfile/totp_brand_manifest.json'
if (Test-Path $totpManifest) {
  $files += @(Get-Item $totpManifest)
}
$lines = foreach ($file in ($files | Sort-Object FullName -Unique)) {
  $relative = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
  $hash = (Get-FileHash $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  "$hash *$relative"
}
[IO.File]::WriteAllLines($output, $lines, [Text.UTF8Encoding]::new($false))
Write-Host "Wrote $($lines.Count) artifact hashes to $output"
