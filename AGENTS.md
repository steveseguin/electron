# Agent Handbook: Lossless-QP + NVENC Electron Build

This repo tracks a customized Electron 38.4.0 build with:

- **Encoder window clamp** – Chromium & WebRTC patches drive VPx/AV1/H26x max QP down to 20 and allow min QP 0 for near-lossless output.
- **FFmpeg NVENC** – FFmpeg configs are rebuilt with CUDA/NVENC enabled so Windows users can leverage NVIDIA hardware.

The published artefacts live on the GitHub release tag `v38.4.0-qp20` and ship both custom (`*-qp20-*.zip`) and default-named archives for drop-in npm installs.

---

## Workspaces

| Platform | Path | Notes |
| --- | --- | --- |
| Linux (WSL2) | `~/electron-work/src` | Primary Chromium/Electron checkout; all GN/Ninja commands run here. |
| Windows | `C:\electron-work-win2\electron-work\src` | VS2022+Windows SDK toolchain; reuses GN outputs `out\Testing-win`, `out\Release-win`. |

Keep both trees in sync by running `gclient sync` from WSL; Windows accesses the same git data via a tarball restore (see `docs/qp-build.md` for bootstrap).

---

## Patch Overview

| Patch | Location | Purpose | Touchpoints |
| --- | --- | --- | --- |
| Lossless QP (Chromium) | `patches/qp-cap/chromium-max-qp.patch` | Raises quality defaults across Blink/MediaRecorder/WebCodecs and libvpx encoder setup. | `third_party/blink`, `media/.../vpx_video_encoder.cc` |
| Lossless QP (WebRTC) | `patches/qp-cap/webrtc-max-qp.patch` | Aligns libwebrtc min/max QP for VP8/VP9/AV1/H26x senders. | `media/base/media_constants.cc`, `modules/video_coding/...` |
| FFmpeg NVENC | `patches/ffmpeg/enable-nvenc.patch` | Enables CUDA/NVENC across Chrome/Chromium configs, vendors NVIDIA headers, adjusts hwcontext. | `third_party/ffmpeg/chromium/...`, `libavutil/hwcontext_cuda.h` |

The patch manifests (`patches/ffmpeg/.patches`, `patches/qp-cap/.patches`) **must** list every file or the `lint.js --patches` precommit step will fail.

---

## Build Loop (Quick Reference)

1. **Sync & prep**
   ```bash
   cd ~/electron-work/src
   gclient sync --with_branch_heads --with_tags
   ./script/apply_all_patches.py
   ```
   Windows tree: run `git clean -fd` if necessary and reapply patches via `python ..\..\electron\script\apply_all_patches.py`.

2. **GN/Ninja**
   ```bash
   gn gen out/Testing --args='is_component_build=true is_debug=true target_cpu="x64"'
   gn gen out/Release --args='is_official_build=true symbol_level=1 enable_nacl=false proprietary_codecs=true ffmpeg_branding="Chrome" target_cpu="x64"'
   ninja -C out/Testing electron
   ninja -C out/Release electron electron:electron_dist_zip
   ```
   Windows equivalent (from PowerShell VS developer prompt):
   ```powershell
   cd C:\electron-work-win2\electron-work\src
   gn gen out\Testing-win --args="is_component_build=true is_debug=true target_cpu=\"x64\" target_os=\"win\""
   gn gen out\Release-win --args="is_official_build=true symbol_level=1 enable_nacl=false proprietary_codecs=true ffmpeg_branding=\"Chrome\" target_cpu=\"x64\" target_os=\"win\""
   ninja -C out\Testing-win electron
   ninja -C out\Release-win electron electron:electron_dist_zip
   ```

3. **NVENC runtime assets**
   - Copy `nvEncodeAPI64.dll` (from `%SystemRoot%\System32` or NVIDIA Video Codec SDK `Redistrib`) into `out\Release-win` before zipping.
   - Linux relies on `libnvidia-encode.so.1` supplied by system drivers; no bundling needed.

4. **Package & publish** (WSL)
   ```bash
   cd ~/electron-work/src
   cp out/Release/dist.zip out/Release/electron-v38.4.0-qp20-linux-x64.zip
   cp out/Release/dist.zip out/Release/electron-v38.4.0-linux-x64.zip

   cp /mnt/c/electron-work-win2/electron-work/src/out/Release-win/dist.zip \
      out/Release-win/electron-v38.4.0-qp20-win32-x64.zip
   cp /mnt/c/electron-work-win2/electron-work/src/out/Release-win/dist.zip \
      out/Release-win/electron-v38.4.0-win32-x64.zip

   sha256sum --binary \
     out/Release/electron-v38.4.0-qp20-linux-x64.zip \
     out/Release/electron-v38.4.0-linux-x64.zip \
     out/Release-win/electron-v38.4.0-qp20-win32-x64.zip \
     out/Release-win/electron-v38.4.0-win32-x64.zip \
     | awk '{print $1 " *" $2}' > out/Release/SHASUMS256.txt
   ```
   Upload artefacts:
   ```bash
   cd ~/electron-work/src/electron
   gh release upload v38.4.0-qp20 \
     ../out/Release/electron-v38.4.0-qp20-linux-x64.zip \
     ../out/Release/electron-v38.4.0-linux-x64.zip \
     ../out/Release-win/electron-v38.4.0-qp20-win32-x64.zip \
     ../out/Release-win/electron-v38.4.0-win32-x64.zip \
     ../out/Release/SHASUMS256.txt \
     --clobber
   ```

5. **Smoke tests**
   - **Linux (WSL)**
     ```bash
     ELECTRON_MIRROR='https://github.com/steveseguin/electron/releases/download/' \
     ELECTRON_CUSTOM_DIR='v38.4.0-qp20' \
     electron_use_remote_checksums=1 \
       npm install --save-dev electron@38.4.0

     npx electron --version
     ```
   - **Windows (PowerShell)**
     ```powershell
     cd C:\Users\steve\Code\tmp\electron-smoke-win
     $env:ELECTRON_MIRROR = "https://github.com/steveseguin/electron/releases/download/"
     $env:ELECTRON_CUSTOM_DIR = "v38.4.0-qp20"
     $env:electron_use_remote_checksums = "1"
     npm.cmd install --save-dev electron@38.4.0
     npx.cmd electron --version
     ```

---

## Troubleshooting Notes

- **Checksum mismatches** – The SHASUM lines must include `*` before filenames (binary mode). If npm still complains, clear caches: `rm -rf ~/.cache/electron` (WSL) and `%LOCALAPPDATA%\electron\Cache` (Windows).
- **Patch lints failing** – Update `.patches` manifests whenever you add/remove patch files. Use `HUSKY=0 git commit …` to skip Husky hooks if linting is noisy, but try to keep manifests accurate.
- **`extract-zip` flattening** – The upstream installer expects the zip root to contain `dist/*`. Keep our archives unmodified; do not pre-flatten them.
- **NVENC runtime** – Missing `nvEncodeAPI64.dll` leads to runtime load failures. Package it or document external dependency.
- **VS environment** – Use the “x64 Native Tools for VS 2022” prompt and ensure Windows SDK 10.0.26100.0 is installed. Set `DEPOT_TOOLS_WIN_TOOLCHAIN=0` if depot_tools tries to pull old toolchains.

---

## Committing & Branching

- Active branch: `feature/qp-cap-v38` tracking the customized patches.
- Run `HUSKY=0 git commit …` to bypass lint hooks if they choke on docs; otherwise expect `lint:docs` and `lint.js --patches` to run.
- Push to origin (`steveseguin/electron`); release assets are managed manually via `gh`.

---

## Open Follow-ups

- No automated validation exists for the lowered QP window or NVENC. Manual `chrome://webrtc-internals` captures are still recommended after significant changes.
- If upstream Electron revises FFmpeg configs or encoder defaults, expect the patches to need manual rebasing—regen diffs from the modified source tree and update the `.patches` manifests.

Refer to `docs/qp-build.md` for fully scripted bootstrap and rebuild instructions; this guide is intended as a high-level refresher for future agents. Good luck!
