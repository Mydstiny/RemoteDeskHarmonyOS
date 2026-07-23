$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$hook = Join-Path $repo '.githooks\pre-push'
if ($IsWindows) {
  $bash = 'C:\Program Files\Git\bin\bash.exe'
} else {
  $bash = (Get-Command bash -ErrorAction Stop).Source
}
if (-not (Test-Path -LiteralPath $bash)) {
  throw "Bash executable not found: $bash"
}
$zero = '0' * 40

Push-Location $repo

$tree = (& git -C $repo rev-parse 'HEAD^{tree}').Trim()
$publicHead = (& git -C $repo rev-parse HEAD).Trim()
$oldAuthorName = $env:GIT_AUTHOR_NAME
$oldAuthorEmail = $env:GIT_AUTHOR_EMAIL
$oldCommitterName = $env:GIT_COMMITTER_NAME
$oldCommitterEmail = $env:GIT_COMMITTER_EMAIL
try {
  $env:GIT_AUTHOR_NAME = 'Compliance Test'
  $env:GIT_AUTHOR_EMAIL = 'compliance-test@example.invalid'
  $env:GIT_COMMITTER_NAME = $env:GIT_AUTHOR_NAME
  $env:GIT_COMMITTER_EMAIL = $env:GIT_AUTHOR_EMAIL
  $unrelated = (& git -C $repo commit-tree $tree -m 'test: unrelated public history').Trim()
} finally {
  $env:GIT_AUTHOR_NAME = $oldAuthorName
  $env:GIT_AUTHOR_EMAIL = $oldAuthorEmail
  $env:GIT_COMMITTER_NAME = $oldCommitterName
  $env:GIT_COMMITTER_EMAIL = $oldCommitterEmail
}

$publicLine = "refs/heads/codex/public-test $publicHead refs/heads/codex/public-test $zero"
$publicLine | & $bash $hook origin 'https://github.com/Mydstiny/RemoteDeskHarmonyOS.git'
if ($LASTEXITCODE -ne 0) {
  throw 'Pre-push history guard rejected a branch based on public main.'
}

$tagLine = "refs/tags/v-test $publicHead refs/tags/v-test $zero"
$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  $tagOutput = @($tagLine | & $bash $hook origin 'https://github.com/Mydstiny/RemoteDeskHarmonyOS.git' 2>&1)
  $tagExit = $LASTEXITCODE
} finally {
  $ErrorActionPreference = $previousErrorAction
}
if ($tagExit -eq 0) {
  throw 'Pre-push history guard allowed a release tag without the Release gate.'
}
if (($tagOutput -join "`n") -notmatch 'Release blocked') {
  throw 'Pre-push history guard rejected the tag for an unexpected reason.'
}

$unrelatedLine = "refs/heads/codex/private-history $unrelated refs/heads/codex/private-history $zero"
$ErrorActionPreference = 'Continue'
try {
  $unrelatedOutput = @($unrelatedLine | & $bash $hook origin 'https://github.com/Mydstiny/RemoteDeskHarmonyOS.git' 2>&1)
  $unrelatedExit = $LASTEXITCODE
} finally {
  $ErrorActionPreference = $previousErrorAction
}
if ($unrelatedExit -eq 0) {
  throw 'Pre-push history guard allowed an unrelated private-history branch.'
}
if (($unrelatedOutput -join "`n") -notmatch 'unrelated to public main') {
  throw 'Pre-push history guard rejected unrelated history for an unexpected reason.'
}

$archiveLine = "refs/archive/heads/legacy $publicHead refs/archive/heads/legacy $zero"
$ErrorActionPreference = 'Continue'
try {
  $archiveOutput = @($archiveLine | & $bash $hook origin 'https://github.com/Mydstiny/RemoteDeskHarmonyOS.git' 2>&1)
  $archiveExit = $LASTEXITCODE
} finally {
  $ErrorActionPreference = $previousErrorAction
}
if ($archiveExit -eq 0) {
  throw 'Pre-push history guard allowed a local archive ref.'
}
if (($archiveOutput -join "`n") -notmatch 'archive/session refs') {
  throw 'Pre-push history guard rejected an archive ref for an unexpected reason.'
}

Pop-Location
Write-Host 'Pre-push public-history guard test passed.'
exit 0
