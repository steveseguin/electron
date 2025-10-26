## Custom QP-Capped Electron Build

This guide documents how to reproduce the high-quality Electron build that
ships with a tightened quantizer window (min QP = 0, max QP ≤ 20) for VPx, AV1,
and H26x encoders. The flow keeps Chromium pristine by applying small patches
on top of upstream sources before invoking the standard Electron build.

### Prerequisites

- Ubuntu 22.04+ (WSL2 or native) with at least 16 GiB RAM and 200 GiB disk
- Depot tools already bootstrapped (`~/tools/depot_tools` on `PATH`)
- Node.js ≥ 18 for Electron tooling (nvm recommended)
- An Electron checkout created with `gclient` at `~/electron-work`
- NVIDIA GPUs + drivers for NVENC (Windows driver 522+ exposes `nvEncodeAPI64.dll`, Linux driver 520+ exposes `libnvidia-encode.so.1`; include the DLL in the release bundle if you ship to machines without NVIDIA drivers).
- Windows builds additionally require:
  - Windows 11 with the *Desktop development with C++* workload (VS 2022 17.4+)
    including the Windows 10 SDK (10.0.26100.0) and the latest MSVC v143 tools.
  - A native `depot_tools` clone at `C:\depot_tools` placed on the PATH in your
    Developer Command Prompt/PowerShell session.
  - `CHROMIUM_BUILDTOOLS_PATH` pointing at the Chromium copy of `buildtools`
    (for example `C:\electron-work-win\electron-work\src\buildtools`) so that
    `gn` does not rely on the solution name in `.gclient`.

### Update sources

```bash
cd ~/electron-work
gclient sync --with_branch_heads --with_tags
```

### Apply the patches

1. Chromium quantizer patch:

   ```bash
   cd ~/electron-work/src
   git apply ../electron/patches/qp-cap/chromium-max-qp.patch
   ```

2. WebRTC quantizer patch:

   ```bash
   cd ~/electron-work/src/third_party/webrtc
   git apply ../../../electron/patches/qp-cap/webrtc-max-qp.patch
   ```

3. FFmpeg NVENC enablement patch:

   ```bash
   cd ~/electron-work/src/third_party/ffmpeg
   git apply ../electron/patches/ffmpeg/enable-nvenc.patch
   ```

> **Tip:** To discard the patches later, run `git reset --hard` in the
> respective repositories (Chromium root, `third_party/webrtc`, and
> `third_party/ffmpeg`).

Applying these patches clamps the encoder window to 0 ≤ QP ≤ 20 for VPx, AV1,
and H26x across both Chromium and WebRTC stacks while rebuilding FFmpeg with
NVENC/NVDEC headers and CUDA hooks, which unlocks near-lossless output at high
bitrates and enables NVIDIA hardware encode offload when the runtime driver is
present.

### Build debug and release artifacts

Use the helper script that lives in the Electron repo:

```bash
cd ~/electron-work/src/electron
./script/build_custom_electron.sh
```

The script generates:

- Debug binary: `~/electron-work/src/out/Testing/electron`
- Release bundle: `~/electron-work/src/out/Release/dist.zip`

### Windows workspace bootstrap

> The fastest path is to reuse the Linux/WSL checkout so that patches and the
> Chromium cache remain in sync.

1. From WSL, archive the synced tree and extract it onto NTFS:

   ```bash
   tar -cf /mnt/c/electron-work.tar -C ~ electron-work
   tar -xf /mnt/c/electron-work.tar -C /mnt/c/electron-work-win
   ```

   The Windows path for the sources will be
   `C:\electron-work-win\electron-work\src`.

2. Install `depot_tools` for Windows and ensure it is on the PATH:

   ```powershell
   git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git `
     C:\depot_tools
   ```

3. Fetch the Windows-only toolchain bits that are not present in the Linux
   checkout:

   ```powershell
   # In a Developer PowerShell, inside C:\electron-work-win\electron-work\src
   $env:PATH  = "C:\electron-work-win\electron-work\src\third_party\depot_tools;$env:PATH"

   # GN + esbuild binaries via CIPD.
   cipd ensure -root . -ensure-file tools\win\qp-build.ensure

   # Rust toolchain (Win) – replaces third_party\rust-toolchain with the
   # Windows archive referenced in DEPS.
   curl -L -o $env:TEMP\rust-win.tar.xz `
     https://storage.googleapis.com/chromium-browser-clang/Win/`
     rust-toolchain-15283f6fe95e5b604273d13a428bab5fc0788f5a-1-`
     llvmorg-22-init-8940-g4d4cb757.tar.xz
   Remove-Item -Recurse -Force third_party\rust-toolchain
   New-Item -ItemType Directory third_party\rust-toolchain | Out-Null
   tar -xf $env:TEMP\rust-win.tar.xz -C third_party\rust-toolchain

   # Node executable + prebuilt node_modules required by devtools tooling.
   curl -L -o third_party\node\win\node.exe `
     https://storage.googleapis.com/chromium-nodejs/907d7e104e7389dc74cec7d32527c1db704b7f96
   curl -L -o $env:TEMP\node_modules.tar.gz `
     https://storage.googleapis.com/chromium-nodejs/98801808b75afb8221eff1c0cfbf3190363279b6
   Remove-Item -Recurse -Force third_party\node\node_modules -ErrorAction SilentlyContinue
   New-Item -ItemType Directory third_party\node\node_modules | Out-Null
   tar -xzf $env:TEMP\node_modules.tar.gz -C third_party\node\node_modules

   # Windows resource compiler shim shipped by Chromium.
   python third_party\depot_tools\download_from_google_storage.py `
     --no_resume --bucket chromium-browser-clang/rc `
     -s build\toolchain\win\rc\win\rc.exe.sha1

   # Git-based Windows-only dependencies.
   git clone https://chromium.googlesource.com/external/github.com/microsoft/DirectX-Headers.git `
     third_party\microsoft_dxheaders\src
   git -C third_party\microsoft_dxheaders\src checkout 8287305d36a2f717260dbbba7b6f5fae36f0f88a

   git clone https://chromium.googlesource.com/external/github.com/microsoft/webauthn.git `
     third_party\microsoft_webauthn\src
   git -C third_party\microsoft_webauthn\src checkout c3ed95fd7603441a0253c55c14e79239cb556a9f

   git clone https://chromium.googlesource.com/chromium/deps/gperf.git `
     third_party\gperf
   git -C third_party\gperf checkout e9eeea862a18e77b945d98eff7e1bf065d3daf8e
   ```

4. Install Electron’s Node tooling once (the build will invoke `npm run`
   targets):

   ```cmd
   cd C:\electron-work-win\electron-work\src\electron
   set HUSKY=0
   npm install
   ```

### Build debug and release artifacts (Windows)

Use a Developer Command Prompt or PowerShell so that Visual Studio tooling is
available. The example below mirrors the helper `.cmd` scripts used to produce
the current build:

```cmd
set DEPOT_TOOLS_WIN_TOOLCHAIN=0
set VPYTHON_BYPASS=https://chromium.org/deps/vpython
set CHROMIUM_BUILDTOOLS_PATH=C:\electron-work-win\electron-work\src\buildtools
set PATH=C:\depot_tools;%PATH%
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
set PATH=%PATH%;C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64
cd /d C:\electron-work-win\electron-work\src

rem --- Debug ---
buildtools\win\gn.exe gen out\Testing-win ^
  --args="import(\"//electron/build/args/testing.gn\") is_debug=true ^
          enterprise_content_analysis=false ^
          enterprise_cloud_content_analysis=false ^
          enterprise_local_content_analysis=false ^
          target_cpu=\"x64\""
ninja -C out\Testing-win electron

rem --- Release ---
buildtools\win\gn.exe gen out\Release-win ^
  --args="import(\"//electron/build/args/release.gn\") symbol_level=1 ^
          proprietary_codecs=true ffmpeg_branding=\"Chrome\" ^
          target_cpu=\"x64\" chrome_pgo_phase=0"
ninja -C out\Release-win electron electron:electron_dist_zip
```

Important paths:

- Debug binary: `C:\electron-work-win\electron-work\src\out\Testing-win\electron.exe`
- Release bundle: `C:\electron-work-win\electron-work\src\out\Release-win\dist.zip`

To publish release zips with platform-specific names, copy the archives:

```bash
# Linux
cd ~/electron-work/src
cp out/Release/dist.zip out/Release/electron-v38.4.0-qp20-linux-x64.zip
cp out/Release/dist.zip out/Release/electron-v38.4.0-linux-x64.zip
```

```powershell
# Windows
cd C:\electron-work-win\electron-work\src
Copy-Item out\Release-win\dist.zip `
  out\Release-win\electron-v38.4.0-qp20-win32-x64.zip
Copy-Item out\Release-win\dist.zip `
  out\Release-win\electron-v38.4.0-win32-x64.zip
```

After the Windows copies complete, mirror the zips back into the WSL checkout so
the checksum step can see them:

```bash
cp /mnt/c/electron-work-win*/electron-work/src/out/Release-win/electron-v38.4.0-*.zip \
  ~/electron-work/src/out/Release-win/
```

Once both archives exist under your WSL checkout, generate a checksum manifest
with binary markers so npm's downloader accepts it:

```bash
cd ~/electron-work/src
sha256sum --binary \
  out/Release/electron-v38.4.0-qp20-linux-x64.zip \
  out/Release/electron-v38.4.0-linux-x64.zip \
  out/Release-win/electron-v38.4.0-qp20-win32-x64.zip \
  out/Release-win/electron-v38.4.0-win32-x64.zip \
  | awk '{print $1 " *" $2}' > out/Release/SHASUMS256.txt
```

> **NVENC runtime:** Before zipping, copy the redistributable `nvEncodeAPI64.dll`
> (either from `%SystemRoot%\System32` or the NVIDIA Video Codec SDK `Redistrib`
> directory) into `out\Release-win` so machines without a pre-installed NVIDIA
> driver can still load the encoder. Linux builds rely on the system's
> `libnvidia-encode.so.1`, so no extra files are required there.

### Create or update a GitHub release

```bash
cd ~/electron-work/src/electron
gh release create v38.4.0-qp20 \
  ../out/Release/electron-v38.4.0-qp20-linux-x64.zip \
  ../out/Release-win/electron-v38.4.0-qp20-win32-x64.zip \
  ../out/Release/SHASUMS256.txt \
  --title "Electron v38.4.0-qp20 (Lossless-cap build)" \
  --notes "Custom build with encoder window clamped to 0-20 QP."
```

Use `gh release upload` to attach the default-named archives so installers that
do not set `ELECTRON_CUSTOM_FILENAME` continue to work:

```bash
cd ~/electron-work/src/electron
gh release upload v38.4.0-qp20 \
  ../out/Release/electron-v38.4.0-linux-x64.zip \
  ../out/Release-win/electron-v38.4.0-win32-x64.zip \
  --clobber
```

Subsequent rebuilds can re-use `gh release upload` (with `--clobber`) to replace
any of the assets in-place.

### Fast rebuild loop after patch edits

Once the initial checkout and toolchains are in place you can iterate on the
encoder changes without re-downloading Chromium:

1. Edit the relevant source under `~/electron-work/src/...` (or the Windows tree)
   and rebuild directly with:
   ```bash
   cd ~/electron-work/src
   ninja -C out/Testing electron
   ninja -C out/Release electron electron:electron_dist_zip
   ```
   On Windows reuse the existing GN output directories:
   ```cmd
   cd C:\electron-work-win\electron-work\src
   ninja -C out\Testing-win electron
   ninja -C out\Release-win electron electron:electron_dist_zip
   ```
2. When satisfied, regenerate the patch files from the modified repos so the
   changes remain portable:
   ```bash
   cd ~/electron-work/src
   git diff --binary media/... > electron/patches/qp-cap/chromium-max-qp.patch

   cd ~/electron-work/src/third_party/webrtc
   git diff --binary media/... > ../../electron/patches/qp-cap/webrtc-max-qp.patch
   ```
   (Replace `media/...` with the actual paths you touched.) This keeps the patch
   workflow in sync with your local edits.
3. Re-run the `ninja` steps to confirm the refreshed patches still build cleanly,
   zip the release artefacts if they changed, and use `gh release upload` to push
   replacements when ready.

### Wiring the build into npm

Consumers can point `electron@38.4.0` at the GitHub release by exporting the
following variables before `npm install`:

```bash
export ELECTRON_MIRROR="https://github.com/steveseguin/electron/releases/download/"
export ELECTRON_CUSTOM_DIR="v38.4.0-qp20"
export electron_use_remote_checksums=1
npm install --save-dev electron@38.4.0
```

> Our release ships a `SHASUMS256.txt` alongside the ZIPs so checksum
> verification succeeds once `electron_use_remote_checksums=1` is set. If you
> prefer to pull the `*-qp20-*.zip` filenames instead of the upstream naming,
> add `ELECTRON_CUSTOM_FILENAME="electron-v38.4.0-qp20-linux-x64.zip"` (Windows
> users should pick the `win32-x64` variant).

On Windows, the same flow can run inside `cmd` or PowerShell:

```powershell
Set-Location C:\path\to\app
$env:ELECTRON_MIRROR = "https://github.com/steveseguin/electron/releases/download/"
$env:ELECTRON_CUSTOM_DIR = "v38.4.0-qp20"
$env:electron_use_remote_checksums = "1"
npm.cmd install --save-dev electron@38.4.0
```

Add the dependency to `package.json` so future installs stay pinned:

```jsonc
{
  "devDependencies": {
    "electron": "38.4.0"
  }
}
```

> **Nightly consumers:** The previous `electron-nightly@40.0.0-nightly.20251020`
> artefacts remain published under `v40.0.0-qp20`. Point
> `ELECTRON_NIGHTLY_MIRROR` (and friends) at that tag if you still need that
> nightly build; otherwise prefer the stable artefact above.

If the installer continues to report checksum mismatches, clear the cached
downloads and retry:

```bash
rm -rf ~/.cache/electron
```

On Windows, remove `%LOCALAPPDATA%\electron\Cache` before re-running `npm.cmd install`.

### Rebasing onto new upstream releases

1. `gclient sync` to fetch the new Electron/Chromium sources.
2. Re-apply the two patches (`git apply` as above).
3. Re-run `./script/build_custom_electron.sh`.
4. Upload a new release asset (increment the tag/version).
5. Update documentation or consumers to point at the new release.

If the patches fail to apply because upstream changed the surrounding code,
inspect the rejected hunks, adjust the patches, and commit the updated patch
files back into the Electron repo.

### Validate NVENC availability

After rebuilding, confirm that FFmpeg exports the NVENC entry points so the
encoder can initialize at runtime.

- **Linux**
  ```bash
  nm -g out/Release/libffmpeg.so | grep nvEncEncodePicture
  ```

- **Windows**
  ```powershell
  dumpbin /exports out\Release-win\ffmpeg.dll | findstr nvEnc
  ```

At runtime you can also open `chrome://webrtc-internals` inside your Electron
app and inspect encoder stats — NVENC sessions show `ImplementationName` values
that include `NVENC`, and QP ceilings around 20 indicate the quantizer clamp is
in effect.
