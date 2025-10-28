Param(
  [Parameter(Mandatory = $true)]
  [string]$Tag,

  [string]$WorkspaceRoot = "C:\electron-work-win2\electron-work\src",

  [string]$DepotToolsDir = "C:\depot_tools",

  [string]$VcVarsBat = "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat",

  [string]$WinSdkBin = "C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64",

  [switch]$SkipSync
)

$ErrorActionPreference = "Stop"

function Invoke-VcVars64 {
  param(
    [string]$BatchPath,
    [string]$AdditionalPath
  )

  if (-not (Test-Path $BatchPath)) {
    throw "vcvars64.bat not found at $BatchPath"
  }

  $cmd = "`"$BatchPath`" && set"
  $envLines = cmd.exe /c $cmd

  foreach ($line in $envLines) {
    if ($line -match "=") {
      $parts = $line.Split("=", 2)
      [System.Environment]::SetEnvironmentVariable($parts[0], $parts[1])
    }
  }

  if ($AdditionalPath) {
    $env:PATH = "$AdditionalPath;$($env:PATH)"
  }
}

function Invoke-Patch {
  param(
    [string]$RepoPath,
    [string]$PatchPath
  )

  if (-not (Test-Path $PatchPath)) {
    throw "Patch not found at $PatchPath"
  }

  $patchName = Split-Path $PatchPath -Leaf

  $reverseApplied = $false
  try {
    & git -C $RepoPath apply --reverse --check $PatchPath *> $null
    if ($LASTEXITCODE -eq 0) {
      $reverseApplied = $true
    }
  } catch {
    $reverseApplied = $false
  }

  if ($reverseApplied) {
    Write-Host "Patch already applied: $patchName"
    return
  }

  & git -C $RepoPath apply --check $PatchPath | Out-Null
  & git -C $RepoPath apply $PatchPath | Out-Null
  Write-Host "Applied patch: $patchName"
}

if (-not (Test-Path $WorkspaceRoot)) {
  throw "Workspace root not found at $WorkspaceRoot"
}

$env:PATH = "$DepotToolsDir;$($env:PATH)"
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = "0"
$env:CHROMIUM_BUILDTOOLS_PATH = Join-Path $WorkspaceRoot "buildtools"

$electronDir = Join-Path $WorkspaceRoot "electron"
$patchDir = Join-Path $electronDir "patches\qp-cap"
$chromiumPatch = Join-Path $patchDir "chromium-max-qp.patch"
$webrtcPatch = Join-Path $patchDir "webrtc-max-qp.patch"
$ffmpegPatch = Join-Path $electronDir "patches\ffmpeg\enable-nvenc.patch"

Push-Location $WorkspaceRoot
try {
  if ($SkipSync) {
    Write-Host "Skipping depot_tools sync (requested)"
  } else {
    Write-Host "Syncing Chromium/Electron dependencies"
    & "$DepotToolsDir\gclient.bat" sync --with_branch_heads --with_tags
  }

  Write-Host "Applying quantizer/NVENC patches"
  Invoke-Patch -RepoPath $WorkspaceRoot -PatchPath $chromiumPatch
  Invoke-Patch -RepoPath (Join-Path $WorkspaceRoot "third_party\webrtc") -PatchPath $webrtcPatch
  Invoke-Patch -RepoPath (Join-Path $WorkspaceRoot "third_party\ffmpeg") -PatchPath $ffmpegPatch

  Write-Host "Setting up MSVC environment"
  Invoke-VcVars64 -BatchPath $VcVarsBat -AdditionalPath "$DepotToolsDir;$WinSdkBin"
  $env:RC_COMPILER = Join-Path $WinSdkBin "rc.exe"
  $env:PATH = "$WinSdkBin;$($env:PATH)"

  Write-Host "Generating debug build files"
  $testingOutDir = Join-Path $WorkspaceRoot "out\Testing-win"
  New-Item -ItemType Directory -Path $testingOutDir -Force | Out-Null
  $testingArgsPath = Join-Path $testingOutDir "args.gn"
  Set-Content -Path $testingArgsPath -Value @"
import("//electron/build/args/testing.gn")
is_debug=true
enterprise_content_analysis=false
enterprise_cloud_content_analysis=false
enterprise_local_content_analysis=false
target_cpu="x64"
use_precompiled_headers=false
node_path="//third_party/electron_node"
"@
  & "$WorkspaceRoot\buildtools\win\gn.exe" gen "$testingOutDir"

  Write-Host "Building debug Electron"
  & ninja -C "$WorkspaceRoot\out\Testing-win" electron

  Write-Host "Generating release build files"
  $releaseOutDir = Join-Path $WorkspaceRoot "out\Release-win"
  New-Item -ItemType Directory -Path $releaseOutDir -Force | Out-Null
  $releaseArgsPath = Join-Path $releaseOutDir "args.gn"
  Set-Content -Path $releaseArgsPath -Value @"
import("//electron/build/args/release.gn")
symbol_level=1
proprietary_codecs=true
ffmpeg_branding="Chrome"
target_cpu="x64"
chrome_pgo_phase=0
use_precompiled_headers=false
node_path="//third_party/electron_node"
"@
  & "$WorkspaceRoot\buildtools\win\gn.exe" gen "$releaseOutDir"

  Write-Host "Building release Electron"
  & ninja -C "$WorkspaceRoot\out\Release-win" electron electron:electron_dist_zip

  $releaseZip = Join-Path "$WorkspaceRoot\out\Release-win" ("electron-{0}-win32-x64.zip" -f $Tag)
  Copy-Item "$WorkspaceRoot\out\Release-win\dist.zip" $releaseZip -Force
  Write-Host "Windows artefact ready: $releaseZip"
  Write-Output ("WINDOWS_RELEASE_ZIP={0}" -f $releaseZip)
}
finally {
  Pop-Location
}
