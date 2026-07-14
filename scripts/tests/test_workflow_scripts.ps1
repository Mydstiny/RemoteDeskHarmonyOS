$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$scripts = @(
  (Join-Path $repo 'scripts\dev_workflow.ps1'),
  (Join-Path $repo 'scripts\history_tool.ps1')
)

foreach ($script in $scripts) {
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors.Count -gt 0) {
    throw "PowerShell parse failed for $script`: $($errors.Message -join '; ')"
  }
}

$workflow = Get-Content -Raw -LiteralPath (Join-Path $repo 'scripts\dev_workflow.ps1')
foreach ($required in @('main must exactly match origin/main', 'Unfinished task branches exist', 'core.hooksPath', 'verify_open_source_release.ps1')) {
  if ($workflow -notmatch [regex]::Escape($required)) {
    throw "dev_workflow.ps1 is missing guard: $required"
  }
}

$history = Get-Content -Raw -LiteralPath (Join-Path $repo 'scripts\history_tool.ps1')
foreach ($required in @('refs/archive', 'Restore must start from main', 'main must match origin/main', 'git bundle verify')) {
  if ($history -notmatch [regex]::Escape($required)) {
    throw "history_tool.ps1 is missing guard: $required"
  }
}

Write-Host 'Workflow and history tool policy tests passed.'
exit 0
