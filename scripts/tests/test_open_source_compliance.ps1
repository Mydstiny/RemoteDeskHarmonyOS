$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$gate = Join-Path $repo 'scripts\verify_open_source_release.ps1'
$requiredTracked = @(
  'rustdesk_vendor/libs/hbb_common/protos/UPSTREAM.yml',
  'rustdesk_vendor/libs/hbb_common/protos/NOTICE'
)

if (-not (Test-Path $gate)) {
  throw 'Compliance gate is missing.'
}
foreach ($relative in $requiredTracked) {
  & git -C $repo ls-files --error-unmatch $relative *> $null
  if ($LASTEXITCODE -ne 0) {
    throw "Required provenance file is not tracked: $relative"
  }
}

$localArtifactPatterns = @(
  '^\.planning/',
  '^\.superpowers/',
  '^logs/',
  '^(HANDOFF|findings|progress|task_plan)\.md$',
  '(^|/)ssh_log\.txt$'
)
$tracked = @(& git -C $repo ls-files)
foreach ($relative in $tracked) {
  foreach ($pattern in $localArtifactPatterns) {
    if ($relative -match $pattern) {
      throw "Local agent/session artifact is tracked: $relative"
    }
  }
}

& $gate -Mode Light -RepositoryRoot $repo
if ($LASTEXITCODE -ne 0) {
  throw "Compliance gate returned exit code $LASTEXITCODE."
}

Write-Host 'Open-source compliance gate smoke test passed.'
