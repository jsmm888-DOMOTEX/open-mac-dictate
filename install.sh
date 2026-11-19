#!/bin/zsh
# Compila e instala OpenMacDictate / Dictado Domotex v5.6 en ~/Applications con entorno Python aislado.
set -e
cd "$(dirname "$0")"

APP_SUPPORT="$HOME/Library/Application Support/OpenMacDictate"
mkdir -p "$APP_SUPPORT"
chmod 700 "$APP_SUPPORT"

VENV_DIR="$APP_SUPPORT/.venv"
if [ ! -x "$VENV_DIR/bin/python3" ]; then
  echo "Creando entorno virtual Python en $VENV_DIR..."
  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --upgrade pip
  "$VENV_DIR/bin/pip" install -r requirements.txt
fi

if [ ! -f "$APP_SUPPORT/vocabulario_local.json" ] && [ -f "vocabulario_local.example.json" ]; then
  cp "vocabulario_local.example.json" "$APP_SUPPORT/vocabulario_local.json"
  chmod 600 "$APP_SUPPORT/vocabulario_local.json"
fi

APP="$HOME/Applications/Dictado Domotex.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>co.domotex.dictado</string>
  <key>CFBundleName</key><string>Dictado Domotex</string>
  <key>CFBundleExecutable</key><string>DictadoDomotex</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>5.6</string>
  <key>CFBundleVersion</key><string>8</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Para escuchar tu voz y escribir lo que dictas en cualquier ventana con Whisper MLX local.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Para convertir tu voz en texto continuo de forma local en el dispositivo.</string>
</dict></plist>
EOF

cp whisper_daemon.py "$APP/Contents/Resources/whisper_daemon.py"
chmod +x "$APP/Contents/Resources/whisper_daemon.py"

pkill -x DictadoDomotex 2>/dev/null || true
pkill -f "whisper_daemon.py" 2>/dev/null || true
rm -f "$APP_SUPPORT/dictado_whisper.sock" /tmp/dictado_whisper.sock
sleep 0.5

echo "Compilando Dictado Domotex v5.6 (Swift 5 + Carbon + AVFoundation + Speech)..."
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/DictadoDomotex" \
  -framework Cocoa -framework Speech -framework AVFoundation -framework Carbon

codesign --force --deep -s - -r='designated => identifier "co.domotex.dictado"' "$APP"

PL="$HOME/Library/LaunchAgents/co.domotex.dictado.plist"
cat > "$PL" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>co.domotex.dictado</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>$APP</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF

launchctl unload "$PL" 2>/dev/null || true
launchctl load "$PL"

sleep 1.0
if ! pgrep -x DictadoDomotex >/dev/null 2>&1; then
  open "$APP"
fi
echo "OK: Dictado Domotex v5.6 instalado y en ejecución."
