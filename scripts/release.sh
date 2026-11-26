#!/bin/zsh
# Builds a Release version signed with Developer ID, optionally notarizes it,
# and produces dist/MacMetrix.zip ready to copy to the Mac minis.
#
#   ./scripts/release.sh                       # build + sign
#   NOTARY_PROFILE=synot ./scripts/release.sh  # build + sign + notarize + staple
#
# Create the notary profile once with:
#   xcrun notarytool store-credentials synot --apple-id <id> --team-id 3ZN9TSG9S7
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null && xcodegen generate --quiet

rm -rf build/release dist
xcodebuild -project MacMetrix.xcodeproj -scheme MacMetrix -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath build/release \
  OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build | grep -E "error|BUILD" || true

APP="build/release/Build/Products/Release/MacMetrix.app"
[[ -d "$APP" ]] || { echo "Build failed"; exit 1; }
codesign --verify --deep --strict "$APP"

mkdir -p dist
ditto -c -k --keepParent "$APP" dist/MacMetrix.zip

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit dist/MacMetrix.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm dist/MacMetrix.zip
  ditto -c -k --keepParent "$APP" dist/MacMetrix.zip
fi

cp scripts/install.sh dist/
# Odregistruj sestavenou kopii, aby ji macOS nespouštěl místo aplikace ve složce Aplikace.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$APP" 2>/dev/null || true
echo "Hotovo: dist/MacMetrix.zip (+ dist/install.sh)"
