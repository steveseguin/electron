#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKSPACE_DIR="$(cd "${SRC_DIR}/.." && pwd)"

export PATH="${WORKSPACE_DIR}/tools/depot_tools:${SRC_DIR}/buildtools/linux64:${PATH}"

echo "[1/5] Syncing Electron dependencies"
(cd "${WORKSPACE_DIR}" && gclient sync --with_branch_heads --with_tags)

echo "[2/5] Generating debug build files"
"${SRC_DIR}/buildtools/linux64/gn" gen "${SRC_DIR}/out/Testing" \
  --args='import("//electron/build/args/testing.gn") is_debug=true enterprise_content_analysis=false enterprise_cloud_content_analysis=false enterprise_local_content_analysis=false'

echo "[3/5] Building debug Electron"
(cd "${SRC_DIR}" && ninja -C out/Testing electron)

echo "[4/5] Generating release build files"
"${SRC_DIR}/buildtools/linux64/gn" gen "${SRC_DIR}/out/Release" \
  --args='import("//electron/build/args/release.gn") symbol_level=1 proprietary_codecs=true ffmpeg_branding="Chrome" target_cpu="x64"'

echo "[5/5] Building release Electron and distributable zip"
(cd "${SRC_DIR}" && ninja -C out/Release electron electron:electron_dist_zip)

echo "Build complete. Debug binary: ${SRC_DIR}/out/Testing/electron"
echo "Release bundle: ${SRC_DIR}/out/Release/dist.zip"
