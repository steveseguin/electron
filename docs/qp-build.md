# Custom Electron v36.9.5 Build (QP clamp + NVENC)

This guide documents the exact steps used to regenerate the **v36.9.5-qp20** release artefacts with the lossless QP and FFmpeg NVENC patches.

---

## 1. Prerequisites

- **Depot tools** installed and on `PATH` (both WSL and Windows).
- **VS 2022** + Windows SDK **10.0.26100.0** on the Windows host.
- Two checkouts rooted at the same tag:
  - WSL: `~/electron-work-v36/src`
  - Windows: `C:\electron-work-v36\src`

Bootstrap example (WSL):

```bash
mkdir -p ~/electron-work-v36
cd ~/electron-work-v36
gclient config --name "src/electron" --unmanaged https://github.com/electron/electron
gclient sync --with_branch_heads --with_tags --revision src/electron@v36.9.5
```

Repeat from PowerShell for the Windows tree if you want a native checkout.

---

## 2. Apply patches

With depot_tools on `PATH`:

```bash
cd ~/electron-work-v36/src
python3 electron/script/apply_all_patches.py electron/patches/config.json
```

Run the same command on Windows if the patches haven’t been applied yet:

```powershell
cd C:\electron-work-v36\src
py electron\script\apply_all_patches.py electron\patches\config.json
```

The helper script is idempotent—it skips patches already present.

---

## 3. Build (WSL)

```bash
cd ~/electron-work-v36/src
export PATH="$HOME/depot_tools:$PWD/buildtools/linux64:$PATH"

gn gen out/Testing --args='is_component_build=true is_debug=true target_cpu="x64"'
gn gen out/Release --args='is_official_build=true symbol_level=1 enable_nacl=false proprietary_codecs=true ffmpeg_branding="Chrome" target_cpu="x64"'

ninja -C out/Testing electron
ninja -C out/Release electron electron:electron_dist_zip
```

---

## 4. Build (Windows)

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

> **Tip:** If `gn.py` cannot find `gn.exe`, double-check that both environment variables above are set *before* running `vcvars64.bat`.

Copy `%WINDIR%\System32\nvEncodeAPI64.dll` into `out\Release-win` and rerun:

```powershell
ninja -C out\Release-win electron:electron_dist_zip
```

so the DLL is packaged inside `dist.zip`.

---

## 5. Package & checksums

From WSL:

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
```

The `awk` invocation strips directory prefixes so the manifest entries look like the upstream Electron ones.

---

## 6. Upload release assets

```bash
cd ~/electron-work-v36/src/electron
gh release upload v36.9.5-qp20 \
  ../out/Release/electron-v36.9.5-qp20-linux-x64.zip \
  ../out/Release/electron-v36.9.5-linux-x64.zip \
  ../out/Release-win/electron-v36.9.5-qp20-win32-x64.zip \
  ../out/Release-win/electron-v36.9.5-win32-x64.zip \
  ../out/Release/SHASUMS256.txt \
  --clobber
```

Run `gh release view v36.9.5-qp20` afterwards to confirm the files are attached.

---

## 7. Smoke tests

### Linux (WSL)

```bash
mkdir -p ~/tmp/electron-smoke-v36-linux
cd ~/tmp/electron-smoke-v36-linux
printf '{ "name": "electron-smoke-v36-linux", "version": "1.0.0", "private": true, "devDependencies": { "electron": "36.9.5" } }\n' > package.json

ELECTRON_MIRROR='https://github.com/steveseguin/electron/releases/download/' \
ELECTRON_CUSTOM_DIR='v36.9.5-qp20' \
electron_use_remote_checksums=1 \
  npm install

npx electron --version
```

### Windows

```powershell
New-Item -ItemType Directory -Force -Path 'C:\Users\Steve\Code\tmp\electron-smoke-v36-win' | Out-Null
Set-Location 'C:\Users\Steve\Code\tmp\electron-smoke-v36-win'
@'
{
  "name": "electron-smoke-v36-win",
  "version": "1.0.0",
  "private": true,
  "devDependencies": {
    "electron": "36.9.5"
  }
}
'@ | Set-Content -NoNewline package.json

$env:ELECTRON_MIRROR = 'https://github.com/steveseguin/electron/releases/download/'
$env:ELECTRON_CUSTOM_DIR = 'v36.9.5-qp20'
$env:electron_use_remote_checksums = '1'
npm.cmd install

npx.cmd electron --version
```

Use the **lowercase** `electron_use_remote_checksums` environment variable; the installer only checks that spelling.

---

## 8. Troubleshooting

| Symptom | Fix |
| --- | --- |
| `gn.py: Could not find gn executable` | Export `CHROMIUM_BUILDTOOLS_PATH` (WSL) or set it before `vcvars64.bat` (Windows). |
| Sumchecker says “No checksum found” | Rebuild `SHASUMS256.txt` and clear caches (`python -c "import shutil,os; shutil.rmtree(os.path.expanduser('~/.cache/electron'), ignore_errors=True)"` and remove `%LOCALAPPDATA%\electron\Cache`). |
| Sumchecker reports checksum mismatch | You uploaded new zips without regenerating `SHASUMS256.txt` or the cache still holds old artefacts. Re-run the commands above and use `--clobber` when uploading. |
| Windows build fails in `generate_config_gypi.py` | Set both `DEPOT_TOOLS_WIN_TOOLCHAIN=0` and `CHROMIUM_BUILDTOOLS_PATH` in the same `cmd` invocation that runs `ninja`. |
| Linker errors for `sqlite3_win32_*` | Ensure the SQLite rename patch is applied in both trees; remove `out/*/obj/third_party/sqlite` to force a rebuild after copying the patched headers. |
| `node install.js` fails with microtask errors | Do **not** revert the `isolate->SetMicrotasksPolicy` edits in `shell/common/node_bindings.cc`, `shell/renderer/electron_renderer_client.cc`, and `shell/renderer/web_worker_observer.cc`. They are required for the older V8 in v36. |

---

## 9. Release checklist

- [x] Patches apply cleanly on v36.9.5 (Chromium/WebRTC/FFmpeg).
- [x] Linux artefact rebuilt and renamed (`electron-v36.9.5-qp20-linux-x64.zip` + default).
- [x] Windows artefact rebuilt, `nvEncodeAPI64.dll` bundled, renamed (`electron-v36.9.5-qp20-win32-x64.zip` + default).
- [x] `SHASUMS256.txt` regenerated with bare filenames and uploaded.
- [x] `npm install electron@36.9.5` succeeds on both Linux + Windows with:
  ```
  ELECTRON_MIRROR=https://github.com/steveseguin/electron/releases/download/
  ELECTRON_CUSTOM_DIR=v36.9.5-qp20
  electron_use_remote_checksums=1
  ```
- [x] `AGENTS.md` updated to match the workflow.

Document any deviations in the release notes on the GitHub tag.
