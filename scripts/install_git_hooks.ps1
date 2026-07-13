param([string]$RepositoryRoot = (Join-Path $PSScriptRoot '..'))
$root = (Resolve-Path $RepositoryRoot).Path
& git -C $root config core.hooksPath .githooks
if ($LASTEXITCODE -ne 0) { throw 'Unable to configure core.hooksPath.' }
Write-Host 'Installed repository-managed Git hooks.'
