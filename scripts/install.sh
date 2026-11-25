#!/bin/zsh
# Run on a Mac mini (as the user that is logged in over VNC):
#   ./install.sh MacMetrix.zip
set -euo pipefail
ZIP="${1:-MacMetrix.zip}"
TMP=$(mktemp -d)
ditto -x -k "$ZIP" "$TMP"

pkill -x "MacMetrix" 2>/dev/null || true
rm -rf "/Applications/MacMetrix.app"
ditto "$TMP/MacMetrix.app" "/Applications/MacMetrix.app"
xattr -dr com.apple.quarantine "/Applications/MacMetrix.app" 2>/dev/null || true
rm -rf "$TMP"

# First launch registers the app as a login item (SMAppService).
open "/Applications/MacMetrix.app"
echo "MacMetrix nainstalován a spuštěn."
