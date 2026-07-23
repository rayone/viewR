#!/usr/bin/env bash
# Build viewR.app from SPM sources.
# Usage: ./build.sh [debug|release]  (default: debug)
set -euo pipefail

VERSION="1"
echo "==> viewR v${VERSION}"

CONFIG="${1:-debug}"
if [[ "$CONFIG" == "release" ]]; then
    BUILD_FLAGS="--configuration release"
    BUILD_DIR=".build/arm64-apple-macosx/release"
else
    BUILD_FLAGS="--configuration debug"
    BUILD_DIR=".build/debug"
fi

echo "==> Building viewR ($CONFIG)..."
swift build $BUILD_FLAGS

echo "==> Assembling viewR.app bundle..."
APP="viewR.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

# Copy executable
cp "$BUILD_DIR/viewR" "$MACOS/viewR"

# Copy Info.plist
cp "bundle/Info.plist" "$CONTENTS/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$CONTENTS/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$CONTENTS/Info.plist"
plutil -replace CFBundleName -string "viewR" "$CONTENTS/Info.plist"
plutil -replace CFBundleDisplayName -string "viewR" "$CONTENTS/Info.plist"

# Build icon from source PNGs
ICON_LIGHT="icon light.png"
ICON_DARK="icon dark.png"

if [[ -f "$ICON_DARK" ]]; then
    echo "==> Building icon..."
    ICONSET="$RESOURCES/viewR.iconset"
    mkdir -p "$ICONSET"

    declare -a ICON_SIZES=(
        "icon_16x16.png:16"
        "icon_16x16@2x.png:32"
        "icon_32x32.png:32"
        "icon_32x32@2x.png:64"
        "icon_128x128.png:128"
        "icon_128x128@2x.png:256"
        "icon_256x256.png:256"
        "icon_256x256@2x.png:512"
        "icon_512x512.png:512"
        "icon_512x512@2x.png:1024"
    )

    for entry in "${ICON_SIZES[@]}"; do
        name="${entry%%:*}"
        size="${entry##*:}"
        sips -z "$size" "$size" "$ICON_DARK" --out "$ICONSET/$name" >/dev/null 2>&1
    done

    iconutil --convert icns "$ICONSET" --output "$RESOURCES/AppIcon.icns"
    rm -rf "$ICONSET"
fi

# Copy appearance-variant icons for runtime dock icon switching
if [[ -f "$ICON_LIGHT" ]]; then
    sips -z 512 512 "$ICON_LIGHT" --out "$RESOURCES/icon light.png" >/dev/null 2>&1
fi
if [[ -f "$ICON_DARK" ]]; then
    sips -z 512 512 "$ICON_DARK" --out "$RESOURCES/icon dark.png" >/dev/null 2>&1
fi

# Copy localization resources
if [[ -d "bundle/Resources" ]]; then
    cp -R bundle/Resources/* "$RESOURCES/"
fi

# Strip debug symbols in release mode
if [[ "$CONFIG" == "release" ]]; then
    echo "==> Stripping debug symbols..."
    strip -x "$MACOS/viewR"
fi

echo "==> Clearing extended attributes..."
xattr -cr "$APP"

echo "==> Signing viewR.app..."
codesign --force --deep --sign - "$APP"

echo "==> Done: $APP (v${VERSION})"
echo "    Run with: open $APP"
echo "    Or: open -a \$PWD/$APP path/to/image.jpg"
