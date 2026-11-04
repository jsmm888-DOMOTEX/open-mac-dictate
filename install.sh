#!/bin/zsh
# ==============================================================================
# OpenMacDictate (Dictado Domotex) — Installer Script
# Fast, infinite, on-device native voice dictation for macOS (Apple Silicon & Intel)
# ==============================================================================

set -e

echo "🚀 Building OpenMacDictate..."

APP_DIR="$HOME/Applications/OpenMacDictate.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"

mkdir -p "$BIN_DIR" "$RES_DIR"

cat > "$APP_DIR/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>co.domotex.openmacdictate</string>
    <key>CFBundleName</key>
    <string>OpenMacDictate</string>
    <key>CFBundleExecutable</key>
    <string>OpenMacDictate</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>4.1</string>
    <key>CFBundleVersion</key>
    <string>4.1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Microphone access is required for local speech-to-text dictation.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Apple Speech framework is used on-device to transcribe your voice locally.</string>
</dict>
</plist>
EOF

# Compile Swift binary with optimizations
swiftc -O -swift-version 5 main.swift \
    -o "$BIN_DIR/OpenMacDictate" \
    -framework Cocoa \
    -framework Speech \
    -framework AVFoundation \
    -framework Carbon

# Code sign with a stable designated requirement
codesign --force --deep -s - "$APP_DIR"

# Set up launch-on-login agent
PLIST="$HOME/Library/LaunchAgents/co.domotex.openmacdictate.plist"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>co.domotex.openmacdictate</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-a</string>
        <string>$APP_DIR</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST" 2>/dev/null || true

# Restart running instance
pkill -x OpenMacDictate 2>/dev/null || true
sleep 0.5
open "$APP_DIR"

echo "✅ OpenMacDictate installed and running successfully!"
echo "🎙 Shortcut: Press [Control + Option + Space] or click the menu bar mic icon."
