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
$buildScriptPath = Join-Path $repo 'scripts/build_freerdp_ohos.sh'
$buildScript = Get-Content -LiteralPath $buildScriptPath -Raw
foreach ($required in @('-DCHANNEL_DRIVE=ON', 'drive-client')) {
  if (-not $buildScript.Contains($required)) {
    throw "FreeRDP OHOS build omits required drive redirection component: $required"
  }
}
Write-Host 'FreeRDP public provenance test passed.'
