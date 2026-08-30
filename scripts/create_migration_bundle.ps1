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

function New-ExactGitBundle {
  param(
    [string]$Repository,
    [string]$Commit,
    [string]$OutputPath,
    [string]$BundleBranch,
    [string]$ScratchPath
  )

  # `git bundle create <file> <raw-commit>` produces an empty bundle because a
  # bundle must advertise a ref. Create that ref only in an isolated local
  # clone so the source checkout and its refs are never mutated.
  Invoke-GitText -Repository $Repository -Arguments @(
    'clone', '--quiet', '--shared', '--no-checkout', '--', $Repository, $ScratchPath
  ) | Out-Null
  try {
    Invoke-GitText -Repository $ScratchPath -Arguments @(
      'update-ref', "refs/heads/$BundleBranch", $Commit
    ) | Out-Null
    Invoke-GitText -Repository $ScratchPath -Arguments @(
      'bundle', 'create', $OutputPath, "refs/heads/$BundleBranch"
    ) | Out-Null
  } finally {
    if (Test-Path -LiteralPath $ScratchPath) {
      Remove-Item -LiteralPath $ScratchPath -Recurse -Force
    }
  }
}

try {
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  New-Item -ItemType Directory -Force -Path $output | Out-Null

  $refCommit = Invoke-GitText -Repository $root -Arguments @('rev-parse', "$Ref^{commit}")
  $submodulePath = Join-Path $root 'freerdp'
  $submoduleEntry = Invoke-GitText -Repository $root -Arguments @(
    'ls-tree', $refCommit, '--', 'freerdp'
  )
  if ($submoduleEntry -notmatch '^160000 commit ([0-9a-fA-F]{40,64})\s+freerdp$') {
    throw "Root commit $refCommit does not contain the expected freerdp gitlink."
  }
  $submoduleCommit = $Matches[1].ToLowerInvariant()
  if (-not (Test-Path -LiteralPath $submodulePath -PathType Container)) {
    throw "FreeRDP submodule checkout is missing at $submodulePath."
  }
  try {
    $availableSubmoduleCommit = Invoke-GitText -Repository $submodulePath -Arguments @(
      'rev-parse', "$submoduleCommit^{commit}"
    )
  } catch {
    throw "FreeRDP gitlink object $submoduleCommit for root $refCommit is unavailable in the local submodule. Run git submodule update --init before creating the migration bundle."
  }
  if ($availableSubmoduleCommit -ne $submoduleCommit) {
    throw "FreeRDP gitlink $submoduleCommit did not resolve to the same commit object."
  }
  $sourceZip = Join-Path $stage 'RemoteDeskHarmonyOS-source.zip'
  $bundle = Join-Path $stage 'RemoteDeskHarmonyOS-main.bundle'
  $submoduleZip = Join-Path $stage 'freerdp-ohos-source.zip'
  $submoduleBundle = Join-Path $stage 'freerdp-ohos.bundle'

  Invoke-GitText -Repository $root -Arguments @(
    'archive', '--format=zip', "--output=$sourceZip", $refCommit
  ) | Out-Null
  New-ExactGitBundle -Repository $root -Commit $refCommit -OutputPath $bundle `
    -BundleBranch 'remotedesk-migration' -ScratchPath (Join-Path $stage '.root-bundle-work')
  Invoke-GitText -Repository $submodulePath -Arguments @(
    'archive', '--format=zip', "--output=$submoduleZip", $submoduleCommit
  ) | Out-Null
  New-ExactGitBundle -Repository $submodulePath -Commit $submoduleCommit `
    -OutputPath $submoduleBundle -BundleBranch 'freerdp-ohos' `
    -ScratchPath (Join-Path $stage '.freerdp-bundle-work')

  $manifest = @(
    'RemoteDeskHarmonyOS migration bundle',
    "Generated: $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')",
    "Root ref: $Ref",
    "Root commit: $refCommit",
    "freerdp gitlink commit: $submoduleCommit",
    'freerdp patched tree: 24a880d801892e3d6f1b8c78534e51eaeca8b0d8',
    '',
    'Included:',
    '- RemoteDeskHarmonyOS-source.zip: tracked source snapshot, including docs/codex shared state and the FreeRDP OHOS patch series.',
    '- RemoteDeskHarmonyOS-main.bundle: Git history ending exactly at the requested root commit.',
    '- freerdp-ohos-source.zip: source snapshot of the exact FreeRDP gitlink in that root commit.',
    '- freerdp-ohos.bundle: Git history ending exactly at that FreeRDP gitlink commit.',
    '',
    'Not included:',
    '- untracked files, logs, screenshots, build output, SDKs, signing material, AGConnect secrets, local properties, user databases and private Codex memory.',
    '',
    'Restore outline on macOS:',
    '1. Extract this package outside an existing checkout.',
    '2. Clone RemoteDeskHarmonyOS-main.bundle into RemoteDeskHarmonyOS.',
    '3. Add https://github.com/Mydstiny/RemoteDeskHarmonyOS.git as origin and fetch --prune.',
    '4. Restore the FreeRDP public base from freerdp-ohos-source.zip or use git submodule update --init --recursive; keep patches/freerdp-ohos from the root source.',
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
