#!/bin/zsh
# ==============================================================================
# OpenMacDictate / Dictado Domotex — Uninstaller Script
# ==============================================================================

echo "🛑 Stopping and removing OpenMacDictate / Dictado Domotex..."

for LABEL in co.domotex.dictado co.domotex.openmacdictate; do
    PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
    if [ -f "$PLIST" ]; then
        launchctl unload "$PLIST" 2>/dev/null || true
        rm -f "$PLIST"
    fi
done

pkill -x DictadoDomotex 2>/dev/null || true
pkill -x OpenMacDictate 2>/dev/null || true
pkill -f "whisper_daemon.py" 2>/dev/null || true

rm -rf "$HOME/Applications/Dictado Domotex.app"
rm -rf "$HOME/Applications/OpenMacDictate.app"
rm -f "$HOME/Library/Application Support/OpenMacDictate/dictado_whisper.sock" /tmp/dictado_whisper.sock

echo "✅ OpenMacDictate / Dictado Domotex has been completely uninstalled."
