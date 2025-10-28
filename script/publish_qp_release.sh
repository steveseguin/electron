#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKSPACE_DIR="$(cd "${SRC_DIR}/.." && pwd)"
PATCH_DIR="${SRC_DIR}/electron/patches/qp-cap"
FFMPEG_PATCH="${SRC_DIR}/electron/patches/ffmpeg/enable-nvenc.patch"

DEFAULT_WINDOWS_SRC="/mnt/c/electron-work-win2/electron-work/src"

TITLE_TEMPLATE='Electron %s (Lossless-cap build)'
NOTES_DEFAULT='Custom build with encoder window clamped to 0-20 QP.'

usage() {
  cat <<'EOF'
Usage: publish_qp_release.sh <tag> [options]

Builds the QP-capped Electron binaries (Linux + optional Windows) and uploads
the resulting artefacts to the specified GitHub release.

Options:
  --notes TEXT           Custom release notes text.
  --title TEXT           Custom release title (defaults to "Electron <tag> ...").
  --windows-src PATH     Windows workspace root (default: /mnt/c/electron-work-win2/electron-work/src).
  --skip-linux           Skip the Linux build (reuse existing artefact).
  --skip-windows         Skip the Windows build (or when no Windows workspace is available).

The script expects:
  - depot_tools checked out under ${WORKSPACE_DIR}/tools/depot_tools (Linux)
  - patches/qp-cap/* present in the Electron repo
  - GitHub CLI (gh) authenticated for publishing releases
  - For Windows builds: Visual Studio 2022 toolchain and depot_tools on the host.
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

TAG=""
NOTES="${NOTES_DEFAULT}"
TITLE=""
WINDOWS_SRC="${DEFAULT_WINDOWS_SRC}"
SKIP_LINUX=0
SKIP_WINDOWS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes)
      shift
      [[ $# -gt 0 ]] || { echo "Error: --notes requires a value" >&2; exit 1; }
      NOTES="$1"
      ;;
    --title)
      shift
      [[ $# -gt 0 ]] || { echo "Error: --title requires a value" >&2; exit 1; }
      TITLE="$1"
      ;;
    --windows-src)
      shift
      [[ $# -gt 0 ]] || { echo "Error: --windows-src requires a value" >&2; exit 1; }
      WINDOWS_SRC="$1"
      ;;
    --skip-linux)
      SKIP_LINUX=1
      ;;
    --skip-windows)
      SKIP_WINDOWS=1
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -z "${TAG}" ]]; then
        TAG="$1"
      else
        echo "Unexpected argument: $1" >&2
        usage
        exit 1
      fi
      ;;
  esac
  shift
done

if [[ -z "${TAG}" ]]; then
  echo "Error: release tag is required." >&2
  usage
  exit 1
fi

if [[ -z "${TITLE}" ]]; then
  printf -v TITLE "${TITLE_TEMPLATE}" "${TAG}"
fi

export PATH="${WORKSPACE_DIR}/tools/depot_tools:${SRC_DIR}/buildtools/linux64:${PATH}"

apply_patch_if_needed() {
  local repo_path="$1"
  local patch_path="$2"
  local patch_name
  patch_name="$(basename "${patch_path}")"

  if git -C "${repo_path}" apply --reverse --check "${patch_path}" >/dev/null 2>&1; then
    echo "    Patch already applied: ${patch_name}"
    return 0
  fi

  echo "    Applying patch: ${patch_name}"
  git -C "${repo_path}" apply --check "${patch_path}"
  git -C "${repo_path}" apply "${patch_path}"
}

maybe_wslpath() {
  local path="$1"
  if command -v wslpath >/dev/null 2>&1; then
    wslpath "${path}"
  else
    echo "${path}"
  fi
}

WINDOWS_RELEASE_ZIP=""

if [[ "${SKIP_LINUX}" -eq 0 ]]; then
  echo "[linux] Syncing Chromium/Electron sources"
  (cd "${WORKSPACE_DIR}" && gclient sync --with_branch_heads --with_tags)

  echo "[linux] Applying quantizer patches"
  apply_patch_if_needed "${SRC_DIR}" "${PATCH_DIR}/chromium-max-qp.patch"
  apply_patch_if_needed "${SRC_DIR}/third_party/webrtc" "${PATCH_DIR}/webrtc-max-qp.patch"
  echo "[linux] Applying FFmpeg NVENC patch"
  apply_patch_if_needed "${SRC_DIR}/third_party/ffmpeg" "${FFMPEG_PATCH}"

  echo "[linux] Generating debug build files"
  "${SRC_DIR}/buildtools/linux64/gn" gen "${SRC_DIR}/out/Testing" \
    --args='import("//electron/build/args/testing.gn") is_debug=true enterprise_content_analysis=false enterprise_cloud_content_analysis=false enterprise_local_content_analysis=false'

  echo "[linux] Building debug Electron"
  (cd "${SRC_DIR}" && ninja -C out/Testing electron)

  echo "[linux] Generating release build files"
  "${SRC_DIR}/buildtools/linux64/gn" gen "${SRC_DIR}/out/Release" \
    --args='import("//electron/build/args/release.gn") symbol_level=1 proprietary_codecs=true ffmpeg_branding="Chrome" target_cpu="x64"'

  echo "[linux] Building release Electron + dist zip"
  (cd "${SRC_DIR}" && ninja -C out/Release electron electron:electron_dist_zip)

  LINUX_RELEASE_ZIP="${SRC_DIR}/out/Release/electron-${TAG}-linux-x64.zip"
  cp "${SRC_DIR}/out/Release/dist.zip" "${LINUX_RELEASE_ZIP}"
  echo "[linux] Release artefact ready: ${LINUX_RELEASE_ZIP}"
else
  echo "[linux] Skipping Linux build as requested"
  LINUX_RELEASE_ZIP="${SRC_DIR}/out/Release/electron-${TAG}-linux-x64.zip"
  if [[ ! -f "${LINUX_RELEASE_ZIP}" ]]; then
    echo "Warning: Linux artefact ${LINUX_RELEASE_ZIP} not found. Release upload may fail." >&2
  fi
fi

if [[ "${SKIP_WINDOWS}" -eq 0 ]]; then
  if [[ -d "${WINDOWS_SRC}" ]]; then
    WINDOWS_POWERSHELL=""
    if command -v pwsh.exe >/dev/null 2>&1; then
      WINDOWS_POWERSHELL="pwsh.exe"
    elif command -v powershell.exe >/dev/null 2>&1; then
      WINDOWS_POWERSHELL="powershell.exe"
    fi

    if [[ -z "${WINDOWS_POWERSHELL}" ]]; then
      echo "[windows] PowerShell executable not found; skipping Windows build." >&2
    else
      WINDOWS_SRC_WIN="$(wslpath -w "${WINDOWS_SRC}")"
      SCRIPT_DIR_WIN="$(wslpath -w "${SCRIPT_DIR}")"
      echo "[windows] Invoking Windows build helper via ${WINDOWS_POWERSHELL}"
      mapfile -t ps_output < <("${WINDOWS_POWERSHELL}" -NoProfile -ExecutionPolicy Bypass -File "${SCRIPT_DIR_WIN}\\build_win_qp_release.ps1" -WorkspaceRoot "${WINDOWS_SRC_WIN}" -Tag "${TAG}")
      for line in "${ps_output[@]}"; do
        line="${line%$'\r'}"
        echo "[windows] ${line}"
        if [[ "${line}" == WINDOWS_RELEASE_ZIP=* ]]; then
          WINDOWS_RELEASE_ZIP_WIN="${line#WINDOWS_RELEASE_ZIP=}"
          if [[ -n "${WINDOWS_RELEASE_ZIP_WIN}" ]]; then
            WINDOWS_RELEASE_ZIP="$(maybe_wslpath "${WINDOWS_RELEASE_ZIP_WIN}")"
          fi
        fi
      done
      if [[ -z "${WINDOWS_RELEASE_ZIP}" ]]; then
        echo "[windows] Windows artefact path not returned; check PowerShell output above." >&2
      else
        echo "[windows] Release artefact ready: ${WINDOWS_RELEASE_ZIP}"
      fi
    fi
  else
    echo "[windows] Workspace ${WINDOWS_SRC} not found; skipping Windows build."
  fi
else
  echo "[windows] Skipping Windows build as requested"
fi

ASSETS=()
if [[ -n "${LINUX_RELEASE_ZIP:-}" && -f "${LINUX_RELEASE_ZIP}" ]]; then
  ASSETS+=("${LINUX_RELEASE_ZIP}")
fi
if [[ -n "${WINDOWS_RELEASE_ZIP:-}" && -f "${WINDOWS_RELEASE_ZIP}" ]]; then
  ASSETS+=("${WINDOWS_RELEASE_ZIP}")
fi

if [[ "${#ASSETS[@]}" -eq 0 ]]; then
  echo "Error: no release artefacts found; aborting." >&2
  exit 1
fi

if gh release view "${TAG}" >/dev/null 2>&1; then
  echo "[release] Updating existing release ${TAG}"
  gh release upload "${TAG}" "${ASSETS[@]}" --clobber
else
  echo "[release] Creating release ${TAG}"
  gh release create "${TAG}" "${ASSETS[@]}" --title "${TITLE}" --notes "${NOTES}"
fi

echo "Release publishing complete."
