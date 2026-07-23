param(
  [string]$OutputDirectory = (Join-Path (Get-Location) 'migration-bundle'),
  [string]$Ref = 'main'
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$output = [System.IO.Path]::GetFullPath($OutputDirectory)
$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("remotedesk-migration-" + [Guid]::NewGuid().ToString('N'))

function Invoke-GitText {
  param([string]$Repository, [string[]]$Arguments)
  $result = @(& git -C $Repository @Arguments 2>&1)
  if ($LASTEXITCODE -ne 0) { throw "git -C $Repository $($Arguments -join ' ') failed:`n$($result -join [Environment]::NewLine)" }
  return ($result -join [Environment]::NewLine).Trim()
}

try {
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  New-Item -ItemType Directory -Force -Path $output | Out-Null

  $refCommit = Invoke-GitText -Repository $root -Arguments @('rev-parse', "$Ref^{commit}")
  $submodulePath = Join-Path $root 'freerdp'
  $submoduleCommit = Invoke-GitText -Repository $submodulePath -Arguments @('rev-parse', 'HEAD')
  $sourceZip = Join-Path $stage 'RemoteDeskHarmonyOS-source.zip'
  $bundle = Join-Path $stage 'RemoteDeskHarmonyOS-main.bundle'
  $submoduleZip = Join-Path $stage 'freerdp-ohos-source.zip'
  $submoduleBundle = Join-Path $stage 'freerdp-ohos.bundle'

  Invoke-GitText -Repository $root -Arguments @('archive', '--format=zip', "--output=$sourceZip", $Ref) | Out-Null
  Invoke-GitText -Repository $root -Arguments @('bundle', 'create', $bundle, $Ref) | Out-Null
  Invoke-GitText -Repository $submodulePath -Arguments @('archive', '--format=zip', "--output=$submoduleZip", 'HEAD') | Out-Null
  Invoke-GitText -Repository $submodulePath -Arguments @('bundle', 'create', $submoduleBundle, 'HEAD') | Out-Null

  $manifest = @(
    'RemoteDeskHarmonyOS migration bundle',
    "Generated: $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')",
    "Root ref: $Ref",
    "Root commit: $refCommit",
    "freerdp submodule commit: $submoduleCommit",
    '',
    'Included:',
    '- RemoteDeskHarmonyOS-source.zip: tracked source snapshot, including docs/codex shared state.',
    '- RemoteDeskHarmonyOS-main.bundle: public main Git history.',
    '- freerdp-ohos-source.zip: tracked submodule source snapshot.',
    '- freerdp-ohos.bundle: submodule Git history.',
    '',
    'Not included:',
    '- untracked files, logs, screenshots, build output, SDKs, signing material, AGConnect secrets, local properties, user databases and private Codex memory.',
    '',
    'Restore outline on macOS:',
    '1. Extract this package outside an existing checkout.',
    '2. Clone RemoteDeskHarmonyOS-main.bundle into RemoteDeskHarmonyOS.',
    '3. Add https://github.com/Mydstiny/RemoteDeskHarmonyOS.git as origin and fetch --prune.',
    '4. Restore the freerdp submodule from freerdp-ohos-source.zip or use git submodule update --init --recursive.',
    '5. Configure core.hooksPath=.githooks, install pwsh, then run scripts/sync_workspace.sh status.'
  )
  $manifestPath = Join-Path $stage 'MIGRATION_MANIFEST.txt'
  $manifest | Set-Content -LiteralPath $manifestPath -Encoding utf8

  $packageName = "RemoteDeskHarmonyOS-migration-$($refCommit.Substring(0, 9)).zip"
  $packagePath = Join-Path $output $packageName
  if (Test-Path -LiteralPath $packagePath) { Remove-Item -LiteralPath $packagePath -Force }
  Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $packagePath -CompressionLevel Optimal
  Write-Host "Migration package: $packagePath"
  Write-Host "Root commit: $refCommit"
  Write-Host "freerdp commit: $submoduleCommit"
}
finally {
  if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
