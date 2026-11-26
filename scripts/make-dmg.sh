#!/bin/zsh
# Sestaví instalační DMG pro distribuci: dist/MacMetrix-<verze>.dmg
#
# - univerzální Release build (Apple Silicon + Intel), podpis Developer ID s hardened runtime
# - DMG se zástupcem složky Aplikace a ikonou svazku
# - s NOTARY_PROFILE i notarizace a připojení lístku (stapler), takže stažená
#   aplikace jde otevřít bez varování Gatekeeperu
#
# Použití:
#   ./scripts/make-dmg.sh
#   NOTARY_PROFILE=dockpeek ./scripts/make-dmg.sh     # s notarizací
#
# Profil pro notarizaci se jednou uloží do Klíčenky:
#   xcrun notarytool store-credentials <profil> --apple-id <apple-id> --team-id 3ZN9TSG9S7
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null && xcodegen generate --quiet

echo "==> Sestavuji Release (arm64 + x86_64)"
rm -rf build/release
xcodebuild -project MacMetrix.xcodeproj -scheme MacMetrix -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath build/release \
  ONLY_ACTIVE_ARCH=NO OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build | grep -E "error:|BUILD" || true

APP="build/release/Build/Products/Release/MacMetrix.app"
[[ -d "$APP" ]] || { echo "Build selhal"; exit 1; }
codesign --verify --deep --strict --verbose=1 "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
CERT_NAME=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application.*\)/\1/p' | head -1)
[[ -n "$CERT_NAME" ]] || { echo "Aplikace není podepsaná Developer ID"; exit 1; }
# DMG podepiš stejným certifikátem jako aplikaci – podle SHA-1 jejího listového certifikátu,
# jméno by po obnově certifikátu (starý i nový v Klíčence) bylo nejednoznačné.
CERTS=$(mktemp -d)
(cd "$CERTS" && codesign -d --extract-certificates "$OLDPWD/$APP" 2>/dev/null)
IDENTITY=$(openssl x509 -inform DER -in "$CERTS/codesign0" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')
rm -rf "$CERTS"
[[ -n "$IDENTITY" ]] || { echo "Nepodařilo se zjistit certifikát aplikace"; exit 1; }
lipo -archs "$APP/Contents/MacOS/MacMetrix"

echo "==> Vytvářím DMG"
STAGE="build/dmg"
DMG="dist/MacMetrix-$VERSION.dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE" dist
ditto "$APP" "$STAGE/MacMetrix.app"
ln -s /Applications "$STAGE/Aplikace"
# Ikona svazku
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
SetFile -a C "$STAGE" 2>/dev/null || true

rm -f "$DMG"
hdiutil create -quiet -volname "MacMetrix $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

# Pomocné kopie aplikace odregistruj a smaž – jinak si je macOS může vybrat
# při spuštění po přihlášení místo aplikace ve složce Aplikace.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$PWD/$STAGE/MacMetrix.app" 2>/dev/null || true
"$LSREGISTER" -u "$PWD/$APP" 2>/dev/null || true
rm -rf "$STAGE"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> Notarizace (profil $NOTARY_PROFILE) – může trvat pár minut"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
  echo "Hotovo: $DMG (podepsáno Developer ID, notarizováno)"
else
  echo "Hotovo: $DMG (Developer ID, BEZ notarizace – nastavte NOTARY_PROFILE)"
fi
