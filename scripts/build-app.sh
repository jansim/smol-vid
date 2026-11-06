#!/bin/sh
# Builds build/smol-vid.app (and the smolvid command-line tool) in release mode.
# ARCHS="arm64 x86_64" builds universal binaries (default: this Mac's architecture only),
# VERSION=1.2.3 sets the app's version.
# ffmpeg is not bundled: the app and the tool use the one installed with `brew install ffmpeg`.
set -euo pipefail
cd "$(dirname "$0")/.."

# One release build per architecture, merged with lipo; stripped of debug and local symbols
# (which voids their ad-hoc signature, so they are signed again).
ARCHS="${ARCHS:-$(uname -m)}"
OUT=build/bin
rm -rf "$OUT"
mkdir -p "$OUT"
for product in SmolVidApp smolvid; do
    slices=""
    for arch in $ARCHS; do
        swift build -c release --arch "$arch" --product "$product"
        slices="$slices $(swift build -c release --arch "$arch" --show-bin-path)/$product"
    done
    lipo -create $slices -output "$OUT/$product"
    strip -S -x "$OUT/$product"
    codesign --force --sign - "$OUT/$product"
done

APP=build/smol-vid.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/SmolVidApp" "$APP/Contents/MacOS/"
cp "$OUT/smolvid" "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/"
if [ -n "${VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/SmolVidApp"))"
