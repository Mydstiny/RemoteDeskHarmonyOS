param(
  [Parameter(Mandatory = $true)][string]$SourceRef,
  [Parameter(Mandatory = $true)][string]$PrivateBuildProfile,
  [Parameter(Mandatory = $true)][string]$PrivateAgConnectConfig,
  [string]$RepositoryUrl = 'https://github.com/Mydstiny/RemoteDeskHarmonyOS.git'
)

$ErrorActionPreference = 'Stop'
$temp = Join-Path ([IO.Path]::GetTempPath()) ("remotedesk-clean-" + [guid]::NewGuid().ToString('N'))
try {
  & git clone --recurse-submodules --branch $SourceRef $RepositoryUrl $temp
  if ($LASTEXITCODE -ne 0) { throw 'Clean clone failed.' }
  Copy-Item -LiteralPath $PrivateBuildProfile -Destination (Join-Path $temp 'build-profile.json5')
  Copy-Item -LiteralPath $PrivateAgConnectConfig -Destination (Join-Path $temp 'entry/src/main/resources/rawfile/agconnect-services.json')
  & (Join-Path $temp 'scripts/verify_open_source_release.ps1') -Mode Light -RepositoryRoot $temp
  if ($LASTEXITCODE -ne 0) { throw 'Compliance gate failed in clean clone.' }
  $env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'
  $env:OHOS_SDK_HOME = $env:DEVECO_SDK_HOME
  & 'C:\Program Files\Git\bin\bash.exe' (Join-Path $temp 'scripts/build_rustdesk_ffi_ohos.sh') all
  if ($LASTEXITCODE -ne 0) { throw 'Clean-clone RustDesk FFI build failed.' }
  & 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel
  if ($LASTEXITCODE -ne 0) { throw 'Clean-clone HAP build failed.' }
} finally {
  if (Test-Path $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
