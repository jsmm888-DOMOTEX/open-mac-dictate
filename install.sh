#!/bin/zsh
# Compila e instala Dictado Domotex v5.0 en ~/Applications y lo deja arrancando con el Mac.
set -e
cd "$(dirname "$0")"

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
  <key>CFBundleShortVersionString</key><string>5.0</string>
  <key>CFBundleVersion</key><string>5</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Para escuchar tu voz y escribir lo que dictas en cualquier ventana con Whisper MLX.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Para convertir tu voz en texto continuo en tiempo real.</string>
</dict></plist>
EOF

# Copiar el daemon de Whisper a Resources
cp whisper_daemon.py "$APP/Contents/Resources/whisper_daemon.py"
chmod +x "$APP/Contents/Resources/whisper_daemon.py"

pkill -x DictadoDomotex 2>/dev/null || true
sleep 0.5

echo "Compilando Dictado Domotex v5.0 (Swift 5 + Carbon + AVFoundation + Speech)..."
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/DictadoDomotex" \
  -framework Cocoa -framework Speech -framework AVFoundation -framework Carbon

# Firma con requerimiento designado estable para que TCC preserve permisos de Accesibilidad
codesign --force --deep -s - -r='designated => identifier "co.domotex.dictado"' "$APP"

# Arranque automático al iniciar sesión de usuario
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

sleep 0.5
open "$APP"
echo "OK: Dictado Domotex v5.0 (Titanio) instalado y en ejecución"
