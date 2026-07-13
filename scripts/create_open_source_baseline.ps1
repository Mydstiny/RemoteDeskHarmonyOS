param([string]$RepositoryRoot = (Join-Path $PSScriptRoot '..'))

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path $RepositoryRoot).Path
$output = Join-Path $root 'docs/compliance/baselines/1.0.5-agpl/INPUT_SHA256.json'
$excluded = '(^|/)(build-profile\.json5|local\.properties|agconnect-services\.json)$|\.(p12|p7b|pem|key|jks)$'
$items = foreach ($relative in (& git -C $root ls-files)) {
  $unix = $relative.Replace('\', '/')
  if ($unix -match $excluded) { continue }
  $path = Join-Path $root $relative
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
  [ordered]@{
    path = $unix
    sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
  }
}
$record = [ordered]@{
  sourceRevision = (& git -C $root rev-parse HEAD).Trim()
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  files = @($items)
}
[IO.File]::WriteAllText($output, ($record | ConvertTo-Json -Depth 6) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
Write-Host "Wrote baseline for $($items.Count) tracked files."
