#!/bin/bash
# build-app.sh [TARGET_APP]
#
# Builds a standalone, double-clickable "SD Photo Downloader.app" Automator
# Application from the existing import script. Stream Deck can launch it with
# a plain "Open" button (no third-party plugins needed).
#
# The app runs the workflow, so the script must be installed first:
#   ./install.sh
#
# If macOS questions the app, right-click it in Finder -> Open once.

set -euo pipefail

SRC_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
APP="${1:-$SRC_DIR/SD Photo Downloader.app}"

STUB="/System/Library/CoreServices/Automator Application Stub.app/Contents/MacOS/Automator Application Stub"
[ -x "$STUB" ] || { echo "error: Automator Application Stub not found" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp "$STUB" "$APP/Contents/MacOS/Automator Application Stub"

cat > "$APP/Contents/PkgInfo" <<EOF
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
	<string>Automator Application Stub</string>
	<key>CFBundleIdentifier</key>
	<string>com.github.mac-photo-downloader.app</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>SD Photo Downloader</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleSignature</key>
	<string>zwrd</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
</dict>
</plist>
EOF

cat > "$APP/Contents/document.wflow" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AMApplicationBuild</key>
	<string>474</string>
	<key>AMApplicationVersion</key>
	<string>2.10</string>
	<key>AMDocumentVersion</key>
	<string>2</string>
	<key>actions</key>
	<array>
		<dict>
			<key>actionBundleIdentifier</key>
			<string>com.apple.RunShellScript</string>
			<key>actionName</key>
			<string>Run Shell Script</string>
			<key>arguments</key>
			<dict>
				<key>COMMAND_STRING</key>
				<string>exec "$HOME/.sd-photo-downloader/sd-photo-download.sh" "$@"</string>
				<key>inputMethod</key>
				<dict>
					<key>inputMode</key>
					<integer>2</integer>
					<key>inputType</key>
					<integer>0</integer>
				</dict>
				<key>SHELL</key>
				<string>/bin/bash</string>
				<key>shellInputType</key>
				<integer>1</integer>
				<key>source</key>
				<string></string>
				<key>timeout</key>
				<integer>3600</integer>
			</dict>
			<key>isViewExpanded</key>
			<true/>
			<key>isViewVisible</key>
			<true/>
			<key>location</key>
			<string>1. 0. 0.</string>
			<key>name</key>
			<string>Run Shell Script</string>
			<key>parameters</key>
			<dict>
				<key>COMMAND_STRING</key>
				<string>exec "$HOME/.sd-photo-downloader/sd-photo-download.sh" "$@"</string>
				<key>inputMethod</key>
				<dict>
					<key>inputMode</key>
					<integer>2</integer>
					<key>inputType</key>
					<integer>0</integer>
				</dict>
				<key>SHELL</key>
				<string>/bin/bash</string>
				<key>shellInputType</key>
				<integer>1</integer>
				<key>source</key>
				<string></string>
				<key>timeout</key>
				<integer>3600</integer>
			</dict>
			<key>requiredResources</key>
			<array/>
			<key>uuid</key>
			<string>6c3f0f2d-1f9a-4d7b-9c8e-4b2a6d2f3a1e</string>
			<key>version</key>
			<integer>2</integer>
		</dict>
	</array>
	<key>algorithms</key>
	<array/>
	<key>connectors</key>
	<dict/>
	<key>workflowMetaData</key>
	<dict>
		<key>workflowTypeIdentifier</key>
		<string>com.apple.Automator.application</string>
	</dict>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP" >/dev/null 2>&1

echo "Built $APP"
echo "In Stream Deck: add an 'Open' action and choose this .app,"
echo "or copy it into ~/Applications first."