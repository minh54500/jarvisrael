#!/bin/zsh
# Construit Encoche.app et l'installe dans ~/Applications.
set -euo pipefail
cd "${0:A:h}"

VERSION=$(<VERSION)
APP=build/Encoche.app
RES=$APP/Contents/Resources

rm -rf build && mkdir -p $APP/Contents/MacOS $RES
swiftc -O -parse-as-library -swift-version 5 -target $(uname -m)-apple-macos14 \
  app/*.swift -o $APP/Contents/MacOS/Encoche 2>&1 | grep -E "error" || true
[[ -x $APP/Contents/MacOS/Encoche ]] || { echo "✗ La compilation a échoué"; exit 1; }

# Icône : le Mochi lui-même, dessiné par le code de l'app
swiftc -O -parse-as-library -swift-version 5 app/Util.swift app/Skins.swift app/Mochi.swift tools/icon.swift -o build/icon 2>&1 | grep -E "error" || true
build/icon build/Encoche.iconset
iconutil -c icns build/Encoche.iconset -o $RES/Encoche.icns

cp hook/hook.py $RES/

cat > $APP/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Encoche</string>
  <key>CFBundleIdentifier</key><string>io.github.minh54500.encoche</string>
  <key>CFBundleExecutable</key><string>Encoche</string>
  <key>CFBundleIconFile</key><string>Encoche</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Encoche t'écoute quand tu dictes un message à Claude.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Encoche transforme ta voix en texte pour écrire à Claude.</string>
  <key>NSAppleEventsUsageDescription</key><string>Encoche pilote Spotify depuis l'encoche : lecture, pause, morceau suivant.</string>
</dict></plist>
EOF
# Signature : le certificat local « Encoche Dev » (tools/cert.sh, à lancer une fois) garde la même
# identité d'un build à l'autre, donc macOS garde les autorisations (Accessibilité, Spotify).
# Sans lui, signature ad hoc : nouvelle identité à chaque build, autorisations à redonner.
if security find-certificate -c "Encoche Dev" >/dev/null 2>&1; then SIGN="Encoche Dev"; else SIGN=-; fi
codesign --force --deep -s "$SIGN" $APP 2>/dev/null || { SIGN=-; codesign --force --deep -s - $APP 2>/dev/null || true; }

osascript -e 'quit app "Encoche"' 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/Encoche.app
cp -R $APP ~/Applications/
if [[ $SIGN == - ]]; then
  # Ad hoc : l'ancienne autorisation ne vaut plus. On l'efface pour que macOS la redemande proprement.
  tccutil reset Accessibility io.github.minh54500.encoche >/dev/null 2>&1 || true
  tccutil reset AppleEvents io.github.minh54500.encoche >/dev/null 2>&1 || true
  echo "ℹ︎ Lance tools/cert.sh une fois : tu n'auras plus à réautoriser Encoche après chaque build."
fi
echo "✓ Installé : ~/Applications/Encoche.app (v$VERSION)"
