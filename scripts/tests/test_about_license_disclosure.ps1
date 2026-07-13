$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$aboutPath = Join-Path $repo 'entry/src/main/ets/components/AboutSettingsSheet.ets'
$about = Get-Content -Raw $aboutPath

if ($about -notmatch 'AGPL-3.0-or-later 开源协议') {
  throw 'About does not disclose AGPL-3.0-or-later.'
}
if ($about -notmatch '完整对应源码与第三方许可声明见 GitHub 仓库') {
  throw 'About does not describe corresponding source and third-party notices.'
}
if ($about -notmatch 'https://github.com/Mydstiny/RemoteDeskHarmonyOS') {
  throw 'About source repository URL changed or is missing.'
}
Write-Host 'About AGPL disclosure test passed.'
