#!/bin/zsh
# ==============================================================================
# OpenMacDictate — Uninstaller Script
# ==============================================================================

echo "🛑 Stopping and removing OpenMacDictate..."

PLIST="$HOME/Library/LaunchAgents/co.domotex.openmacdictate.plist"
if [ -f "$PLIST" ]; then
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
fi

pkill -x OpenMacDictate 2>/dev/null || true
rm -rf "$HOME/Applications/OpenMacDictate.app"

echo "✅ OpenMacDictate has been completely uninstalled."
