$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$files = @(
  'scripts/build_opus_ohos.sh',
  'scripts/build_rustdesk_ffi_ohos.sh',
  'entry/src/main/cpp/CMakeLists.txt'
)
foreach ($relative in $files) {
  $content = Get-Content -Raw (Join-Path $repo $relative)
  if ($content -notmatch 'libs/opus-ohos') {
    throw "Durable Opus artifact path missing from $relative"
  }
}
Write-Host 'Durable Opus artifact location test passed.'
