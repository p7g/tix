#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP="$PWD/dist/Tix.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
chmod -R u+w "$APP"
cp "$BIN/Tix" "$APP/Contents/MacOS/Tix"
cp "$BIN/tix-mcp" "$APP/Contents/MacOS/tix-mcp"
# SwiftPM resource bundles (including dependency privacy manifests).
for bundle in "$BIN"/*.bundle; do
    [ ! -d "$bundle" ] || cp -R "$bundle" "$APP/Contents/Resources/"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Tix</string>
<key>CFBundleIdentifier</key><string>local.tix.app</string>
<key>CFBundleName</key><string>Tix</string>
<key>CFBundleDisplayName</key><string>Tix</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP/Contents/MacOS/tix-mcp"
codesign --force --sign - "$APP"
printf 'Built %s\nMCP: %s/Contents/MacOS/tix-mcp\n' "$APP" "$APP"
