$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
  'remotedesk-migration-test-' + [Guid]::NewGuid().ToString('N'))

function Invoke-TestGit {
  param([string]$Repository, [string[]]$GitArgs)
  $result = @(& git -C $Repository @GitArgs 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "git -C $Repository $($GitArgs -join ' ') failed:`n$($result -join [Environment]::NewLine)"
  }
  return ($result -join [Environment]::NewLine).Trim()
}

function Initialize-TestRepository {
  param([string]$Path, [string]$Branch)
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
  Invoke-TestGit -Repository $Path -GitArgs @('init', '--quiet') | Out-Null
  Invoke-TestGit -Repository $Path -GitArgs @('config', 'user.name', 'Migration Test') | Out-Null
  Invoke-TestGit -Repository $Path -GitArgs @('config', 'user.email', 'migration-test@example.invalid') | Out-Null
  Invoke-TestGit -Repository $Path -GitArgs @('checkout', '--quiet', '-b', $Branch) | Out-Null
}

try {
  $fixtureRepo = Join-Path $fixtureRoot 'fixture-repo'
  $fixtureScripts = Join-Path $fixtureRepo 'scripts'
  $fixtureSubmodule = Join-Path $fixtureRepo 'freerdp'
  $fixtureOutput = Join-Path $fixtureRoot 'output'
  $patchedTreeA = '1111111111111111111111111111111111111111'
  $patchedTreeB = '2222222222222222222222222222222222222222'
  New-Item -ItemType Directory -Force -Path $fixtureScripts | Out-Null
  Copy-Item -LiteralPath (Join-Path $repo 'scripts\create_migration_bundle.ps1') `
    -Destination (Join-Path $fixtureScripts 'create_migration_bundle.ps1')

  Initialize-TestRepository -Path $fixtureSubmodule -Branch 'freerdp-ohos'
  Set-Content -LiteralPath (Join-Path $fixtureSubmodule 'version.txt') `
    -Value 'gitlink-version-a' -Encoding utf8NoBOM
  Invoke-TestGit -Repository $fixtureSubmodule -GitArgs @('add', 'version.txt') | Out-Null
  Invoke-TestGit -Repository $fixtureSubmodule -GitArgs @('commit', '--quiet', '-m', 'version a') | Out-Null
  $submoduleCommitA = Invoke-TestGit -Repository $fixtureSubmodule -GitArgs @('rev-parse', 'HEAD')
  Set-Content -LiteralPath (Join-Path $fixtureSubmodule 'version.txt') `
    -Value 'gitlink-version-b' -Encoding utf8NoBOM
  Invoke-TestGit -Repository $fixtureSubmodule -GitArgs @('commit', '--quiet', '-am', 'version b') | Out-Null
  $submoduleCommitB = Invoke-TestGit -Repository $fixtureSubmodule -GitArgs @('rev-parse', 'HEAD')

  Initialize-TestRepository -Path $fixtureRepo -Branch 'main'
  Set-Content -LiteralPath (Join-Path $fixtureRepo 'root.txt') `
    -Value 'root-version-a' -Encoding utf8NoBOM
  Set-Content -LiteralPath (Join-Path $fixtureScripts 'build_freerdp_ohos.sh') `
    -Value "FREERDP_PATCHED_TREE=`"$patchedTreeA`"" -Encoding utf8NoBOM
  Invoke-TestGit -Repository $fixtureRepo -GitArgs @(
    'add', 'root.txt', 'scripts/build_freerdp_ohos.sh'
  ) | Out-Null
  Invoke-TestGit -Repository $fixtureRepo -GitArgs @(
    'update-index', '--add', '--cacheinfo', '160000', $submoduleCommitA, 'freerdp'
  ) | Out-Null
  Invoke-TestGit -Repository $fixtureRepo -GitArgs @('commit', '--quiet', '-m', 'root a') | Out-Null
  $rootCommitA = Invoke-TestGit -Repository $fixtureRepo -GitArgs @('rev-parse', 'HEAD')
  Set-Content -LiteralPath (Join-Path $fixtureScripts 'build_freerdp_ohos.sh') `
    -Value "FREERDP_PATCHED_TREE=`"$patchedTreeB`"" -Encoding utf8NoBOM
  Invoke-TestGit -Repository $fixtureRepo -GitArgs @(
    'add', 'scripts/build_freerdp_ohos.sh'
  ) | Out-Null
  Invoke-TestGit -Repository $fixtureRepo -GitArgs @(
    'update-index', '--cacheinfo', '160000', $submoduleCommitB, 'freerdp'
  ) | Out-Null
  Invoke-TestGit -Repository $fixtureRepo -GitArgs @('commit', '--quiet', '-m', 'root b') | Out-Null

  $fixtureScript = Join-Path $fixtureScripts 'create_migration_bundle.ps1'
  $fixtureScriptSource = Get-Content -Raw -LiteralPath $fixtureScript
  $windowsNewLineScript = $fixtureScriptSource.Replace(
    '[Environment]::NewLine', '"`r`n"')
  if ($windowsNewLineScript -eq $fixtureScriptSource) {
    throw 'Migration fixture could not enable Windows CRLF output simulation.'
  }
  Set-Content -LiteralPath $fixtureScript -Value $windowsNewLineScript `
    -Encoding utf8NoBOM -NoNewline
  & $fixtureScript -OutputDirectory $fixtureOutput -Ref $rootCommitA
  if ($LASTEXITCODE -ne 0) {
    throw 'Migration bundle fixture command failed.'
  }

  $packages = @(Get-ChildItem -LiteralPath $fixtureOutput -Filter '*.zip')
  if ($packages.Count -ne 1) {
    throw "Expected one migration package, found $($packages.Count)."
  }
  $expandedPackage = Join-Path $fixtureRoot 'expanded-package'
  Expand-Archive -LiteralPath $packages[0].FullName -DestinationPath $expandedPackage
  $manifest = Get-Content -Raw -LiteralPath (
    Join-Path $expandedPackage 'MIGRATION_MANIFEST.txt')
  if ($manifest -notmatch [regex]::Escape("Root commit: $rootCommitA") -or
      $manifest -notmatch [regex]::Escape("freerdp gitlink commit: $submoduleCommitA") -or
      $manifest -match [regex]::Escape("freerdp gitlink commit: $submoduleCommitB") -or
      $manifest -notmatch [regex]::Escape("freerdp patched tree: $patchedTreeA") -or
      $manifest -match [regex]::Escape("freerdp patched tree: $patchedTreeB")) {
    throw 'Migration manifest is not bound to the requested root FreeRDP inputs.'
  }

  $expandedSubmodule = Join-Path $fixtureRoot 'expanded-submodule'
  Expand-Archive -LiteralPath (Join-Path $expandedPackage 'freerdp-ohos-source.zip') `
    -DestinationPath $expandedSubmodule
  $archivedVersion = (Get-Content -Raw -LiteralPath (
    Join-Path $expandedSubmodule 'version.txt')).Trim()
  if ($archivedVersion -ne 'gitlink-version-a') {
    throw "FreeRDP archive used '$archivedVersion' instead of the requested gitlink."
  }

  $submoduleBundleHeads = @(git bundle list-heads (
    Join-Path $expandedPackage 'freerdp-ohos.bundle'))
  if ($LASTEXITCODE -ne 0 -or $submoduleBundleHeads.Count -ne 1 -or
      $submoduleBundleHeads[0] -ne "$submoduleCommitA refs/heads/freerdp-ohos") {
    throw 'FreeRDP bundle head is not the exact requested gitlink.'
  }
  $rootBundleHeads = @(git bundle list-heads (
    Join-Path $expandedPackage 'RemoteDeskHarmonyOS-main.bundle'))
  if ($LASTEXITCODE -ne 0 -or $rootBundleHeads.Count -ne 1 -or
      $rootBundleHeads[0] -ne "$rootCommitA refs/heads/remotedesk-migration") {
    throw 'Root bundle head is not the exact requested commit.'
  }
  $currentSubmoduleCommit = Invoke-TestGit -Repository $fixtureSubmodule `
    -GitArgs @('rev-parse', 'HEAD')
  if ($currentSubmoduleCommit -ne $submoduleCommitB) {
    throw 'Migration bundle creation mutated the source submodule checkout.'
  }

  Write-Host 'Migration bundle exact-gitlink integration test passed.'
} finally {
  if (Test-Path -LiteralPath $fixtureRoot) {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
  }
}
