## Custom QP-Capped Electron Build

This guide documents how to reproduce the high-quality Electron build that
ships with a tighter maximum quantizer ceiling (QP ≤ 20) for VPx, AV1, and
H26x encoders. The flow keeps Chromium pristine by applying small patches on
top of upstream sources before invoking the standard Electron build.

### Prerequisites

- Ubuntu 22.04+ (WSL2 or native) with at least 16 GiB RAM and 200 GiB disk
- Depot tools already bootstrapped (`~/tools/depot_tools` on `PATH`)
- Node.js ≥ 18 for Electron tooling (nvm recommended)
- An Electron checkout created with `gclient` at `~/electron-work`

### Update sources

```bash
cd ~/electron-work
gclient sync --with_branch_heads --with_tags
```

### Apply the quantizer patches

1. Chromium patches (from the ELECTRON repo):

   ```bash
   cd ~/electron-work/src
   git apply ../electron/patches/qp-cap/chromium-max-qp.patch
   ```

2. WebRTC patch (apply inside the submodule):

   ```bash
   cd ~/electron-work/src/third_party/webrtc
   git apply ../../../electron/patches/qp-cap/webrtc-max-qp.patch
   ```

> **Tip:** To discard the patches later, run `git reset --hard` in the
> respective repositories (Chromium root and `third_party/webrtc`).

### Build debug and release artifacts

Use the helper script that lives in the Electron repo:

```bash
cd ~/electron-work/src/electron
./script/build_custom_electron.sh
```

The script generates:

- Debug binary: `~/electron-work/src/out/Testing/electron`
- Release bundle: `~/electron-work/src/out/Release/dist.zip`

To publish a Windows-friendly archive name, copy the zip:

```bash
cd ~/electron-work/src
cp out/Release/dist.zip out/Release/electron-v40.0.0-qp16-linux-x64.zip
```

(Adjust the filename to match the current Electron version/target platform.)

### Create or update a GitHub release

```bash
cd ~/electron-work/src/electron
gh release create v40.0.0-qp16 \
  ../out/Release/electron-v40.0.0-qp16-linux-x64.zip \
  --title "Electron v40.0.0-qp16 (QP-capped build)" \
  --notes "Custom build with encoder max QP forced to 20."
```

Subsequent rebuilds can re-use `gh release upload` to replace the asset.

### Wiring the build into npm

Consumers can point `electron` downloads at the GitHub release by exporting
the following variables before `npm install`:

```bash
export ELECTRON_MIRROR="https://github.com/steveseguin/electron/releases/download/"
export ELECTRON_CUSTOM_DIR="v40.0.0-qp16"
export ELECTRON_CUSTOM_FILENAME="electron-v40.0.0-qp16-linux-x64.zip"
npm install
```

You can also reference the build directly in `package.json`:

```jsonc
{
  "devDependencies": {
    "electron": "https://github.com/steveseguin/electron/releases/download/v40.0.0-qp16/electron-v40.0.0-qp16-linux-x64.zip"
  }
}
```

### Rebasing onto new upstream releases

1. `gclient sync` to fetch the new Electron/Chromium sources.
2. Re-apply the two patches (`git apply` as above).
3. Re-run `./script/build_custom_electron.sh`.
4. Upload a new release asset (increment the tag/version).
5. Update documentation or consumers to point at the new release.

If the patches fail to apply because upstream changed the surrounding code,
inspect the rejected hunks, adjust the patches, and commit the updated patch
files back into the Electron repo.
