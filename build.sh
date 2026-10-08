#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP=MiddleTap.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/MiddleTap"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>nl.david.MiddleTap</string>
<key>CFBundleName</key><string>MiddleTap</string>
<key>CFBundleExecutable</key><string>MiddleTap</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
# Stable certificate so Accessibility permissions survive a rebuild (ad-hoc = new
# cdhash per build = permission lost). Create via Certificate Assistant (Code Signing, self-signed).
IDENTITY="MiddleTap Dev"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "Note: certificate '$IDENTITY' not found, signed ad-hoc (Accessibility permission is lost on rebuild)"
    codesign --force --sign - "$APP"
fi
echo "Done: $PWD/$APP"
