param(
  [string]$RepositoryRoot = (Join-Path $PSScriptRoot '..'),
  [string]$NativeSdkRoot = ''
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path $RepositoryRoot).Path
$lockPath = Join-Path $root 'entry/src/main/cpp/moonlight/upstream/UPSTREAM.lock.json'
$lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
$expectedApi = [string]$lock.buildReceipts.sdkApi

function Test-ApiNativeRoot([string]$Candidate) {
  if ([string]::IsNullOrWhiteSpace($Candidate) -or -not (Test-Path -LiteralPath $Candidate -PathType Container)) {
    return $null
  }
  $resolved = (Resolve-Path -LiteralPath $Candidate).Path
  $toolchain = Join-Path $resolved 'build/cmake/ohos.toolchain.cmake'
  if (-not (Test-Path -LiteralPath $toolchain -PathType Leaf)) {
    return $null
  }
  $metadataPath = Join-Path $resolved 'oh-uni-package.json'
  if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
    $metadata = Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json
    if ([string]$metadata.apiVersion -ne $expectedApi) {
      return $null
    }
  } elseif ((Split-Path (Split-Path $resolved -Parent) -Leaf) -ne $expectedApi) {
    return $null
  }
  return $resolved
}

function Find-ApiNativeRoot {
  $candidates = [System.Collections.Generic.List[string]]::new()
  foreach ($candidate in @($NativeSdkRoot, $env:OHOS_SDK_HOME, $env:DEVECO_SDK_HOME)) {
    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
      $candidates.Add($candidate)
    }
  }
  $userHome = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
  if (-not [string]::IsNullOrWhiteSpace($userHome)) {
    $candidates.Add((Join-Path $userHome 'Library/OpenHarmony/Sdk'))
    $candidates.Add((Join-Path $userHome 'Library/Huawei/DevEco Studio/sdk'))
    $candidates.Add((Join-Path $userHome 'Library/DevEco-Studio/sdk'))
  }
  $candidates.Add('/Applications/DevEco-Studio.app/Contents/sdk')
  if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
    $candidates.Add((Join-Path $env:ProgramFiles 'Huawei/DevEco Studio/sdk'))
  }
  if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $candidates.Add((Join-Path $env:LOCALAPPDATA 'Huawei/DevEco Studio/sdk'))
  }

  foreach ($candidate in ($candidates | Select-Object -Unique)) {
    $layouts = @(
      $candidate,
      (Join-Path $candidate 'native'),
      (Join-Path $candidate "$expectedApi/native"),
      (Join-Path $candidate 'default/openharmony/native')
    )
    foreach ($layout in $layouts) {
      $match = Test-ApiNativeRoot $layout
      if ($match) {
        return $match
      }
    }
  }
  throw "Moonlight vendor build: HarmonyOS/OpenHarmony API $expectedApi native SDK was not found. Set OHOS_SDK_HOME or -NativeSdkRoot."
}

function Find-SdkExecutable([string]$SdkRelativePath, [string]$CommandName) {
  $candidate = Join-Path $nativeRoot $SdkRelativePath
  foreach ($path in @($candidate, "$candidate.exe")) {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      return (Resolve-Path -LiteralPath $path).Path
    }
  }
  $command = Get-Command $CommandName -ErrorAction SilentlyContinue
  if ($command) {
    return $command.Source
  }
  throw "Moonlight vendor build: required executable not found: $CommandName"
}

function Invoke-Checked([string]$Executable, [string[]]$Arguments, [string]$Description) {
  & $Executable @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Moonlight vendor build: $Description failed with exit code $LASTEXITCODE"
  }
}

$nativeRoot = Find-ApiNativeRoot
$toolchainFile = Join-Path $nativeRoot 'build/cmake/ohos.toolchain.cmake'
$cmake = Find-SdkExecutable 'build-tools/cmake/bin/cmake' 'cmake'
$ninja = Find-SdkExecutable 'build-tools/cmake/bin/ninja' 'ninja'
$llvmAr = Find-SdkExecutable 'llvm/bin/llvm-ar' 'llvm-ar'
$python = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $python) {
  $python = Get-Command python -ErrorAction SilentlyContinue
}
if (-not $python) {
  throw 'Moonlight vendor build: Python 3 is required for the source-integrity gate.'
}

$verifier = Join-Path $root 'scripts/verify_moonlight_vendor.py'
Invoke-Checked $python.Source @($verifier) 'source-integrity gate'

$sourceDir = Join-Path $root 'entry/src/main/cpp/moonlight/vendor-build'
$opensslRoot = Join-Path $root 'libs/openssl/install'
$buildRoot = Join-Path ([IO.Path]::GetTempPath()) ('remotedesk-moonlight-common.' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $buildRoot)

foreach ($abi in @('arm64-v8a', 'x86_64')) {
  $buildDir = Join-Path $buildRoot $abi
  $configureArguments = @(
    '-S', $sourceDir,
    '-B', $buildDir,
    '-G', 'Ninja',
    "-DCMAKE_MAKE_PROGRAM=$ninja",
    "-DCMAKE_TOOLCHAIN_FILE=$toolchainFile",
    '-DCMAKE_BUILD_TYPE=Release',
    "-DOHOS_ARCH=$abi",
    '-DOHOS_STL=c++_shared',
    "-DREMOTEDESK_OPENSSL_ROOT=$opensslRoot"
  )
  Invoke-Checked $cmake $configureArguments "CMake configure for $abi"
  Invoke-Checked $cmake @('--build', $buildDir, '--target', 'moonlight_vendor_static', '--parallel') "CMake build for $abi"

  $commonArchive = Join-Path $buildDir 'moonlight-common-c-build/libmoonlight-common-c.a'
  $enetArchive = Join-Path $buildDir 'moonlight-common-c-build/enet/libenet.a'
  foreach ($archive in @($commonArchive, $enetArchive)) {
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
      throw "Moonlight vendor build: missing static output for ${abi}: $archive"
    }
  }

  $members = @(& $llvmAr t $commonArchive)
  if ($LASTEXITCODE -ne 0) {
    throw "Moonlight vendor build: unable to inspect common-c archive for $abi"
  }
  foreach ($required in @('Connection.c.o', 'PlatformCrypto.c.o', 'VideoStream.c.o', 'AudioStream.c.o', 'InputStream.c.o', 'rs.c.o')) {
    if ($members -notcontains $required) {
      throw "Moonlight vendor build: $abi archive misses $required"
    }
  }

  $commonSha = (Get-FileHash -LiteralPath $commonArchive -Algorithm SHA256).Hash.ToLowerInvariant()
  $enetSha = (Get-FileHash -LiteralPath $enetArchive -Algorithm SHA256).Hash.ToLowerInvariant()
  $receipt = $lock.buildReceipts.archives.PSObject.Properties[$abi].Value
  $expectedCommonSha = [string]$receipt.PSObject.Properties['libmoonlight-common-c.a'].Value
  $expectedEnetSha = [string]$receipt.PSObject.Properties['libenet.a'].Value
  if ($commonSha -ne $expectedCommonSha -or $enetSha -ne $expectedEnetSha) {
    throw @"
Moonlight vendor build: deterministic receipt mismatch for $abi
  common-c actual=$commonSha expected=$expectedCommonSha
  enet actual=$enetSha expected=$expectedEnetSha
"@
  }

  Write-Host "Moonlight vendor build: $abi PASS"
  Write-Host "  common-c sha256=$commonSha"
  Write-Host "  enet sha256=$enetSha"
}

Write-Host "Moonlight vendor build root: $buildRoot"
