#!/bin/bash
# build-app.sh [TARGET_APP]
#
# Builds a native "SD Photo Downloader.app" from sd-photo-download.swift.
# Launching it (Finder double-click, Stream Deck "Open" action, Shortcuts)
# imports from the auto-detected card and shows the progress window.
#
# Requirements: Xcode Command Line Tools (swiftc) and exiftool.
# The config is read at runtime from, in order:
#   1. $SD_CARD_DOWNLOADER_CONFIG
#   2. <this app>/Contents/MacOS/config        (for portable copies)
#   3. ~/.sd-photo-downloader/config           (what install.sh creates)
#   4. ~/Library/Application Support/SD Photo Downloader/config
#
# Extra arguments are passed through, e.g.
#   open -Wn "SD Photo Downloader.app" --args --card /Volumes/NO_NAME --dry-run

set -euo pipefail

SRC_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
APP="${1:-$SRC_DIR/SD Photo Downloader.app}"
BIN="sd-photo-download"

command -v swiftc >/dev/null 2>&1 || {
    echo "error: swiftc not found. Install the Xcode Command Line Tools:" >&2
    echo "       xcode-select --install" >&2
    exit 1
}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# App icon: a flat blue squircle with a white SD card glyph, from the Remix
# Icon "sd-card-fill" shape (https://remixicon.com, Apache License 2.0).
if [ -f "$SRC_DIR/resources/AppIcon.icns" ]; then
    cp -f "$SRC_DIR/resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "Compiling $BIN..."
swiftc -O -o "$APP/Contents/MacOS/$BIN" "$SRC_DIR/sd-photo-download.swift"

cat > "$APP/Contents/PkgInfo" <<'EOF'
APPL????
EOF

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>sd-photo-download</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.github.mac-photo-downloader.app</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>SD Photo Downloader</string>
	<key>CFBundleDisplayName</key>
	<string>SD Photo Downloader</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
EOF

# Ad-hoc signature: enough for local use on Apple silicon.
codesign --force --sign - "$APP" >/dev/null 2>&1 || \
    echo "warning: ad-hoc codesign failed; the app may still run locally" >&2

echo "Built $APP"
echo
echo "Test it without writing anything:"
echo "  open -Wn \"$APP\" --args --dry-run --no-eject"
echo
echo "In Stream Deck: add an 'Open' action and pick this .app,"
echo "or copy it into ~/Applications first."