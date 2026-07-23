param(
  [ValidateSet('status', 'sync', 'start', 'doctor', 'finish-check')]
  [string]$Action = 'status',
  [string]$Task = ''
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Invoke-GitText {
  param([string[]]$GitArgs, [switch]$AllowFailure)
  $output = @(& git -C $root @GitArgs 2>&1)
  $exitCode = $LASTEXITCODE
  if (-not $AllowFailure -and $exitCode -ne 0) {
    throw "git $($GitArgs -join ' ') failed:`n$($output -join [Environment]::NewLine)"
  }
  return $output
}

function Get-GitValue {
  param([string[]]$GitArgs)
  return ((Invoke-GitText -GitArgs $GitArgs) -join "`n").Trim()
}

function Get-BranchesAheadOfMain {
  $result = [System.Collections.Generic.List[string]]::new()
  $branches = @(Invoke-GitText -GitArgs @('for-each-ref', '--format=%(refname:short)', 'refs/heads/codex'))
  foreach ($branch in $branches) {
    if ([string]::IsNullOrWhiteSpace($branch)) { continue }
    $ahead = [int](Get-GitValue -GitArgs @('rev-list', '--count', "main..$branch"))
    if ($ahead -gt 0) { $result.Add($branch) }
  }
  return $result
}

function Sync-PublicMain {
  $currentBranch = Get-GitValue -GitArgs @('branch', '--show-current')
  $currentChanges = @(Invoke-GitText -GitArgs @('status', '--porcelain'))
  if ($currentBranch -ne 'main') {
    throw "Sync must start from main; current branch is '$currentBranch'. Finish or hand off the active task first."
  }
  if ($currentChanges.Count -gt 0) {
    throw 'Sync refuses to overwrite local changes. Commit them on the task branch or move them aside intentionally before syncing.'
  }

  Invoke-GitText -GitArgs @('fetch', '--prune', 'origin') | ForEach-Object { Write-Host $_ }
  $localMain = Get-GitValue -GitArgs @('rev-parse', 'main')
  $remoteMain = Get-GitValue -GitArgs @('rev-parse', 'origin/main')
  if ($localMain -ne $remoteMain) {
    Invoke-GitText -GitArgs @('pull', '--ff-only', 'origin', 'main') | ForEach-Object { Write-Host $_ }
  }
  Invoke-GitText -GitArgs @('submodule', 'update', '--init', '--recursive') | ForEach-Object { Write-Host $_ }
  $syncedMain = Get-GitValue -GitArgs @('rev-parse', '--short=9', 'main')
  Write-Host "Synchronized main with origin/main at $syncedMain."
  if (Test-Path (Join-Path $root 'docs\codex\CURRENT.md')) {
    Write-Host 'Shared state: docs/codex/CURRENT.md'
    Write-Host 'Shared queue: docs/codex/QUEUE.md'
  }
}

$branch = Get-GitValue -GitArgs @('branch', '--show-current')
$head = Get-GitValue -GitArgs @('rev-parse', '--short=9', 'HEAD')
$main = Get-GitValue -GitArgs @('rev-parse', '--short=9', 'main')
$originMain = Get-GitValue -GitArgs @('rev-parse', '--short=9', 'origin/main')
$changes = @(Invoke-GitText -GitArgs @('status', '--porcelain'))
$worktreeLines = @(Invoke-GitText -GitArgs @('worktree', 'list', '--porcelain') | Where-Object { $_ -like 'worktree *' })
$activeBranches = @(Get-BranchesAheadOfMain)

switch ($Action) {
  'status' {
    Write-Host "workspace=$root"
    Write-Host "branch=$branch head=$head"
    Write-Host "main=$main origin/main=$originMain"
    if ($branch -ne 'main') {
      $ahead = Get-GitValue -GitArgs @('rev-list', '--count', "main..$branch")
      $behind = Get-GitValue -GitArgs @('rev-list', '--count', "$branch..main")
      Write-Host "relative-to-main=ahead:$ahead behind:$behind"
    }
    Write-Host "changes=$($changes.Count) worktrees=$($worktreeLines.Count) archive-refs=$(@(Invoke-GitText -GitArgs @('for-each-ref', '--format=%(refname)', 'refs/archive')).Count)"
    if ($activeBranches.Count -gt 0) {
      Write-Host "active-branches=$($activeBranches -join ',')"
    } else {
      Write-Host 'active-branches=none'
    }
    if ($changes.Count -gt 0) { $changes | ForEach-Object { Write-Host "change=$_" } }
  }

  'sync' {
    Sync-PublicMain
  }

  'start' {
    if ($Task -notmatch '^[a-z0-9][a-z0-9-]{2,60}$') {
      throw 'Task must be a lowercase kebab-case name between 3 and 61 characters.'
    }
    Sync-PublicMain
    $branch = Get-GitValue -GitArgs @('branch', '--show-current')
    $changes = @(Invoke-GitText -GitArgs @('status', '--porcelain'))
    $main = Get-GitValue -GitArgs @('rev-parse', 'main')
    $originMain = Get-GitValue -GitArgs @('rev-parse', 'origin/main')
    $activeBranches = @(Get-BranchesAheadOfMain)
    if ($branch -ne 'main') { throw "Cannot start a task while branch '$branch' is active." }
    if ($changes.Count -gt 0) { throw 'Cannot start a task with an uncommitted working tree.' }
    if ($main -ne $originMain) { throw 'Local main must exactly match origin/main before starting a task.' }
    if ($activeBranches.Count -gt 0) {
      throw "Unfinished task branches exist: $($activeBranches -join ', ')"
    }
    Invoke-GitText -GitArgs @('switch', '-c', "codex/$Task") | ForEach-Object { Write-Host $_ }
    Write-Host "Started codex/$Task. Update CURRENT.md before implementation."
  }

  'doctor' {
    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $hooks = (Get-GitValue -GitArgs @('config', '--get', 'core.hooksPath'))
    if ($hooks -ne '.githooks') { $errors.Add("core.hooksPath is '$hooks', expected .githooks") }
    if ($worktreeLines.Count -ne 1) { $errors.Add("$($worktreeLines.Count) persistent worktrees are registered; expected 1") }
    if ($main -ne $originMain) { $errors.Add('main does not match origin/main') }
    $otherActive = @($activeBranches | Where-Object { $_ -ne $branch })
    if ($otherActive.Count -gt 0) { $errors.Add("Other unfinished task branches: $($otherActive -join ', ')") }
    if ($changes.Count -gt 0) { $warnings.Add("Working tree contains $($changes.Count) change(s)") }
    $archiveCount = @(Invoke-GitText -GitArgs @('for-each-ref', '--format=%(refname)', 'refs/archive')).Count
    if ($archiveCount -eq 0) { $warnings.Add('No local refs/archive history is available') }
    $warnings | ForEach-Object { Write-Warning $_ }
    if ($errors.Count -gt 0) {
      $errors | ForEach-Object { Write-Error $_ }
      exit 1
    }
    Write-Host 'Workflow doctor passed.'
  }

  'finish-check' {
    if ($branch -eq 'main' -or [string]::IsNullOrWhiteSpace($branch)) { throw 'No feature branch is active.' }
    if ($changes.Count -gt 0) { throw 'Commit or intentionally discard working-tree changes before finishing.' }
    Invoke-GitText -GitArgs @('merge-base', '--is-ancestor', 'main', 'HEAD') | Out-Null
    $upstream = Get-GitValue -GitArgs @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}')
    if ([string]::IsNullOrWhiteSpace($upstream)) { throw 'Feature branch has no upstream; push it before finishing.' }
    & (Join-Path $root 'scripts\verify_open_source_release.ps1') -Mode Light
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Write-Host "Finish check passed for $branch -> main. Confirm PR/check/merge, then return to main."
  }
}
