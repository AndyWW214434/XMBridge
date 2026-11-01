#!/usr/bin/env bash
# Builds XMBridge.app into ./build. Needs only the Xcode Command Line Tools.
#   scripts/build-app.sh                 release build for this Mac
#   CONFIG=debug scripts/build-app.sh    debug build (logs every protocol frame)
#   UNIVERSAL=1 scripts/build-app.sh     Apple Silicon + Intel, plus build/XMBridge.zip for a release
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
APP="build/XMBridge.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    binaries=()
    for triple in arm64-apple-macosx13.0 x86_64-apple-macosx13.0; do
        swift build -c "$CONFIG" --triple "$triple"
        binaries+=("$(swift build -c "$CONFIG" --triple "$triple" --show-bin-path)/XMBridge")
    done
    lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/XMBridge"
else
    swift build -c "$CONFIG"
    cp "$(swift build -c "$CONFIG" --show-bin-path)/XMBridge" "$APP/Contents/MacOS/XMBridge"
fi

cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature: enough to run locally and for macOS to remember the Bluetooth permission.
codesign --force --sign - "$APP"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    rm -f build/XMBridge.zip
    ditto -c -k --norsrc --noextattr --keepParent "$APP" build/XMBridge.zip
    echo "Built $APP and build/XMBridge.zip ($(lipo -archs "$APP/Contents/MacOS/XMBridge"))"
else
    echo "Built $APP"
fi
