#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Relay"
BINARY_NAME="RelayApp"
BUNDLE_ID="com.gokul.relay"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"
# Non-destructive verify: SKIP_INSTALL=1 ./build.sh  (assembles Relay.app in-repo only)
INSTALL_DIR="${RELAY_INSTALL_DIR:-/Applications}"
SKIP_INSTALL="${SKIP_INSTALL:-0}"
SIGN_IDENTITY="RelayLocalSign"

echo "==> Building release binary"
swift build -c release

echo "==> Assembling app bundle"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${BINARY_NAME}" "${APP_BUNDLE}/Contents/MacOS/${BINARY_NAME}"
cp "Support/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
if [ -f "Support/AppIcon.icns" ]; then
    cp "Support/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi

if security find-certificate -c "${SIGN_IDENTITY}" >/dev/null 2>&1; then
    echo "==> Code signing (${SIGN_IDENTITY})"
    codesign --force --deep --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"
else
    echo "==> Code signing (ad-hoc — ${SIGN_IDENTITY} not found in keychain)"
    echo "    Tip: run ./setup-signing.sh once so macOS doesn't reset your"
    echo "    grants on every rebuild."
    codesign --force --deep --sign - "${APP_BUNDLE}"
fi

if [ "${SKIP_INSTALL}" = "1" ]; then
    echo "==> Skipping install (SKIP_INSTALL=1). Bundle at: $(pwd)/${APP_BUNDLE}"
    echo "    Launch with: open \"$(pwd)/${APP_BUNDLE}\""
    exit 0
fi

echo "==> Installing to ${INSTALL_DIR}"
if [ -d "${INSTALL_DIR}/${APP_BUNDLE}" ]; then
    osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
    sleep 1
    rm -rf "${INSTALL_DIR}/${APP_BUNDLE}"
fi
cp -R "${APP_BUNDLE}" "${INSTALL_DIR}/"

echo "==> Launching"
open "${INSTALL_DIR}/${APP_BUNDLE}"

echo "Done. Look for the Relay icon in the menu bar."
