# Agent Handbook: Lossless-QP + NVENC Electron v36.9.5

This branch packages a customized Electron **36.9.5** with:

- **Encoder window clamp** – Chromium & WebRTC patches drop min QP to 0 and clamp the max QP at 20 so VPx/AV1/H26x encoders stay effectively lossless.
- **FFmpeg NVENC** – FFmpeg configs enable NVIDIA NVENC/CUDA support; Windows artefacts include the redistributable DLL.

Release artefacts live on tag **`v36.9.5-qp20`** (custom `*-qp20-*` plus default-named zips so npm installs work without extra flags).

---

## Workspaces

| Platform | Path | Notes |
| --- | --- | --- |
| Linux (WSL2) | `~/electron-work-v36/src` | Primary Chromium/Electron checkout; all GN/Ninja invocations run here. |
| Windows | `C:\electron-work-v36\src` | VS 2022 + Windows SDK toolchain; builds land in `out\Testing-win` / `out\Release-win`. |

Always `gclient sync` from WSL before a fresh build; copy cache-friendly tarballs to Windows if you prefer but keep the repos aligned on tag **v36.9.5**.

---

## Patch Inventory

| Patch | Location | Purpose | Touchpoints |
| --- | --- | --- | --- |
| Lossless QP (Chromium) | `patches/qp-cap/chromium-max-qp.patch` | Boosts quality defaults across Blink/MediaRecorder/WebCodecs and libvpx setup. | `third_party/blink`, `media/video/*_video_encoder.cc` |
| Lossless QP (WebRTC) | `patches/qp-cap/webrtc-max-qp.patch` | Aligns WebRTC sender QP ranges for VP8/VP9/AV1/H264. | `media/base/media_constants.cc`, `modules/video_coding/...` |
| FFmpeg NVENC | `patches/ffmpeg/enable-nvenc.patch` | Enables CUDA/NVENC in FFmpeg configs, vendors headers, tightens color metadata casts. | `third_party/ffmpeg/**`, `libavcodec/nvenc.c`, `libavutil/hwcontext_cuda.h` |
| Portal shim | `patches/chromium/fix-win-portal-build.patch` | Keeps Electron’s Linux portal dialog GN wiring intact for v36. | `ui/shell_dialogs/BUILD.gn`, `shell/browser/ui/file_dialog_linux_portal.cc` |

Each patch directory has a `.patches` manifest – update them if you rename files or Husky will flag the build.

---

## Build Loop (Quick Reference)

1. **Sync & apply patches (WSL)**
   ```bash
   cd ~/electron-work-v36/src
   gclient sync --with_branch_heads --with_tags --revision src/electron@v36.9.5
   python3 electron/script/apply_all_patches.py electron/patches/config.json
   ```
   Windows: run the same script from PowerShell if you cloned afresh, e.g.
   ```powershell
   cd C:\electron-work-v36\src
   py electron\script\apply_all_patches.py electron\patches\config.json
   ```
   (The script skips already-applied patches.)

2. **GN/Ninja (Linux)**
   ```bash
   export PATH="$HOME/depot_tools:$PWD/buildtools/linux64:$PATH"
   gn gen out/Testing --args='is_component_build=true is_debug=true target_cpu="x64"'
   gn gen out/Release --args='is_official_build=true symbol_level=1 enable_nacl=false proprietary_codecs=true ffmpeg_branding="Chrome" target_cpu="x64"'
   ninja -C out/Testing electron
   ninja -C out/Release electron electron:electron_dist_zip
   ```

3. **GN/Ninja (Windows)**
   ```powershell
   cd C:\electron-work-v36\src
   $env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
   $env:CHROMIUM_BUILDTOOLS_PATH = 'C:\electron-work-v36\src\buildtools'
   & "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
   buildtools\win\gn.exe gen out\Testing-win
   buildtools\win\gn.exe gen out\Release-win
   ninja -C out\Testing-win electron
   ninja -C out\Release-win electron electron:electron_dist_zip
   ```
   (If `ninja` can’t find `gn`, ensure both `DEPOT_TOOLS_WIN_TOOLCHAIN` and `CHROMIUM_BUILDTOOLS_PATH` are set before running `vcvars64`.)

4. **NVENC runtime**
   - Copy `%WINDIR%\System32\nvEncodeAPI64.dll` into `out\Release-win` before zipping; re-run `ninja -C out\Release-win electron:electron_dist_zip` afterwards.
   - Linux depends on system `libnvidia-encode.so.1`; no packaging needed.

5. **Package & upload (WSL)**
   ```bash
   cd ~/electron-work-v36/src
   cp out/Release/dist.zip out/Release/electron-v36.9.5-qp20-linux-x64.zip
   cp out/Release/dist.zip out/Release/electron-v36.9.5-linux-x64.zip

   mkdir -p out/Release-win
   cp /mnt/c/electron-work-v36/src/out/Release-win/dist.zip out/Release-win/electron-v36.9.5-qp20-win32-x64.zip
   cp /mnt/c/electron-work-v36/src/out/Release-win/dist.zip out/Release-win/electron-v36.9.5-win32-x64.zip

   sha256sum --binary \
     out/Release/electron-v36.9.5-qp20-linux-x64.zip \
     out/Release/electron-v36.9.5-linux-x64.zip \
     out/Release-win/electron-v36.9.5-qp20-win32-x64.zip \
     out/Release-win/electron-v36.9.5-win32-x64.zip \
     | awk '{f=$2; gsub(/\\\\/,"/"); sub(/^.*\//,"",f); print $1 " *" f}' \
     > out/Release/SHASUMS256.txt

   cd electron
   gh release upload v36.9.5-qp20 \
     ../out/Release/electron-v36.9.5-qp20-linux-x64.zip \
     ../out/Release/electron-v36.9.5-linux-x64.zip \
     ../out/Release-win/electron-v36.9.5-qp20-win32-x64.zip \
     ../out/Release-win/electron-v36.9.5-win32-x64.zip \
     ../out/Release/SHASUMS256.txt \
     --clobber
   ```

6. **Smoke tests**
   - **Linux (WSL)**
     ```bash
     ELECTRON_MIRROR='https://github.com/steveseguin/electron/releases/download/' \
     ELECTRON_CUSTOM_DIR='v36.9.5-qp20' \
     electron_use_remote_checksums=1 \
       npm install --save-dev electron@36.9.5

     npx electron --version
     ```
   - **Windows (PowerShell)**
     ```powershell
     cd C:\Users\Steve\Code\tmp\electron-smoke-v36-win
     $env:ELECTRON_MIRROR = 'https://github.com/steveseguin/electron/releases/download/'
     $env:ELECTRON_CUSTOM_DIR = 'v36.9.5-qp20'
     $env:electron_use_remote_checksums = '1'
     npm.cmd install --save-dev electron@36.9.5
     npx.cmd electron --version
     ```

---

## Troubleshooting

- **Checksum errors** – Regenerate `SHASUMS256.txt` after any artefact change. If npm still fails, clear caches (`rm -rf ~/.cache/electron` via Python or `shutil.rmtree`, and delete `%LOCALAPPDATA%\electron\Cache`) then retry.
- **`gn` missing** – Ensure `CHROMIUM_BUILDTOOLS_PATH` is exported on both platforms before running `ninja`. Windows needs the variable set *before* invoking `vcvars64.bat`.
- **`node install` complaining about microtasks** – The v36 Node headers lack `MicrotaskQueue::set_microtasks_policy`; our branch already swaps to `isolate->SetMicrotasksPolicy`. Don’t revert those edits.
- **Patch failures** – Rebase patches against Chromium/WEbRTC/FFmpeg at `v36.9.5`, update the `.patches` manifests, and rerun `apply_all_patches.py`.
- **NVENC runtime** – Forgetting `nvEncodeAPI64.dll` leads to runtime load errors. Bundle it or document the dependency.

---

## Committing & Branching

- Default branch for this work: `feature/qp-cap-v36`.
- Husky hooks still run (`lint:docs`, `lint.js --patches`). Use `HUSKY=0 git commit …` sparingly when iterating.
- Push to `steveseguin/electron`; upload release artefacts manually with `gh`.

---

## Follow-ups

- No automated checks confirm the QP window or NVENC path. After major reworks, run a manual `chrome://webrtc-internals` capture and inspect encoder stats.
- If upstream Electron recuts v36 (unlikely) or you retarget another baseline, regenerate all patches (Chromium/WebRTC/FFmpeg) and update this handbook.

For deeper context and scripted automation, see `docs/qp-build.md`.
