#!/usr/bin/env bash
# Build Readpaw.app — wraps the SwiftPM executable in a proper macOS bundle.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP_NAME="Readpaw"
BUNDLE_DIR="build/${APP_NAME}.app"
EXE_NAME="Readpaw"
INFO_PLIST="Resources/Info.plist"

echo "Building (${CONFIG})…"
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)"
EXE_PATH="${BIN_PATH}/${EXE_NAME}"

if [[ ! -f "${EXE_PATH}" ]]; then
  echo "Built executable not found at ${EXE_PATH}" >&2
  exit 1
fi

echo "Assembling ${BUNDLE_DIR}…"
rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

cp "${EXE_PATH}" "${BUNDLE_DIR}/Contents/MacOS/${EXE_NAME}"
chmod +x "${BUNDLE_DIR}/Contents/MacOS/${EXE_NAME}"
cp "${INFO_PLIST}" "${BUNDLE_DIR}/Contents/Info.plist"

# App icon. CFBundleIconFile in Info.plist references "AppIcon", which the
# macOS Dock / Finder look up as AppIcon.icns in the bundle's Resources.
if [[ -f "Resources/AppIcon.icns" ]]; then
  cp "Resources/AppIcon.icns" "${BUNDLE_DIR}/Contents/Resources/AppIcon.icns"
fi

# Copy SwiftPM-generated resource bundle if present.
RES_BUNDLE="${BIN_PATH}/Readpaw_Readpaw.bundle"
if [[ -d "${RES_BUNDLE}" ]]; then
  cp -R "${RES_BUNDLE}" "${BUNDLE_DIR}/Contents/Resources/"
fi

# Ad-hoc codesign so Gatekeeper lets it run locally.
codesign --force --deep --sign - "${BUNDLE_DIR}" 2>/dev/null || true

echo "Done: ${BUNDLE_DIR}"
echo "Run with: open ${BUNDLE_DIR}"
