param(
  [ValidateSet('list', 'find', 'show', 'diff', 'restore', 'verify-bundle')]
  [string]$Action = 'list',
  [string]$Revision = '',
  [string]$Module = '',
  [string]$Task = '',
  [string]$HistoryRoot = ''
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($HistoryRoot)) {
  $HistoryRoot = Join-Path (Split-Path $root -Parent) 'RemoteDesktopHistory'
}

function Invoke-Git {
  param([string[]]$GitArgs)
  & git -C $root @GitArgs
  if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed." }
}

function Require-Revision {
  if ([string]::IsNullOrWhiteSpace($Revision)) { throw '-Revision is required.' }
  & git -C $root cat-file -e "$Revision^{commit}" 2>$null
  if ($LASTEXITCODE -ne 0) { throw "Revision '$Revision' is not a commit." }
}

function Require-Module {
  if ([string]::IsNullOrWhiteSpace($Module)) { throw '-Module is required.' }
  if ([IO.Path]::IsPathRooted($Module) -or $Module -match '(^|[\\/])\.\.([\\/]|$)') {
    throw 'Module must be a repository-relative path without parent traversal.'
  }
}

switch ($Action) {
  'list' {
    Invoke-Git -GitArgs @(
      'for-each-ref', '--sort=-creatordate',
      '--format=%(refname:short) | %(objectname:short) | %(creatordate:short) | %(subject)',
      'refs/archive'
    )
  }

  'find' {
    Require-Module
    Invoke-Git -GitArgs @(
      'log', '--all', '--date=short',
      '--format=%h | %ad | %d | %s', '--', $Module
    )
  }

  'show' {
    Require-Revision
    Invoke-Git -GitArgs @('show', '--stat', '--summary', '--decorate=full', $Revision)
  }

  'diff' {
    Require-Revision
    Require-Module
    Invoke-Git -GitArgs @('diff', "$Revision..HEAD", '--', $Module)
  }

  'restore' {
    Require-Revision
    Require-Module
    if ($Task -notmatch '^[a-z0-9][a-z0-9-]{2,60}$') {
      throw '-Task must be a lowercase kebab-case name between 3 and 61 characters.'
    }
    $branch = (& git -C $root branch --show-current).Trim()
    if ($branch -ne 'main') { throw "Restore must start from main, not '$branch'." }
    if (@(& git -C $root status --porcelain).Count -gt 0) { throw 'Restore requires a clean working tree.' }
    $main = (& git -C $root rev-parse main).Trim()
    $originMain = (& git -C $root rev-parse origin/main).Trim()
    if ($main -ne $originMain) { throw 'main must match origin/main before restoring history.' }
    & git -C $root cat-file -e "$Revision`:$Module" 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Path '$Module' does not exist at '$Revision'." }
    Invoke-Git -GitArgs @('switch', '-c', "codex/rollback-$Task")
    Invoke-Git -GitArgs @('restore', "--source=$Revision", '--', $Module)
    Write-Host "Restored '$Module' from '$Revision' into codex/rollback-$Task."
    Write-Host 'Review the diff, reconcile current interfaces, run scoped tests/build, then commit through a PR.'
  }

  'verify-bundle' {
    if (-not (Test-Path -LiteralPath $HistoryRoot -PathType Container)) {
      throw "History root does not exist: $HistoryRoot"
    }
    $bundle = Get-ChildItem -LiteralPath $HistoryRoot -Recurse -Filter '*.bundle' -File |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $bundle) { throw "No .bundle file found under $HistoryRoot" }
    & git bundle verify $bundle.FullName
    if ($LASTEXITCODE -ne 0) { throw "Bundle verification failed: $($bundle.FullName)" }
    $hash = Get-FileHash -LiteralPath $bundle.FullName -Algorithm SHA256
    Write-Host "Bundle verified: $($bundle.FullName)"
    Write-Host "SHA256=$($hash.Hash)"
  }
}
