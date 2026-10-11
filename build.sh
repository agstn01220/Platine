#!/bin/sh
# Construit l'app. Prérequis : Xcode Command Line Tools.
#   ./build.sh            construit Platine.app dans un dossier temporaire (chemin affiché à la fin)
#   ./build.sh install    construit, puis installe dans /Applications et lance
#   ./build.sh dmg        construit, puis crée Platine.dmg (pour une release GitHub)
set -e
cd "$(dirname "$0")"
NAME=Platine
ID=io.github.agstn01220.platine
VERSION=1.1
V=vendor/mediaremote-adapter
# Hors du dépôt : sur un Bureau synchronisé iCloud, le système ajoute des attributs que codesign refuse.
B=${TMPDIR:-/tmp}/platine-build
C=$B/$NAME.app/Contents
F=$C/Resources/MediaRemoteAdapter.framework
rm -rf $B/$NAME.app && mkdir -p $C/MacOS $F

clang -dynamiclib -fobjc-arc -fvisibility=default -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 \
  -I$V/include -I$V/src $V/src/adapter/*.m $V/src/private/*.m $V/src/utility/*.m \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers -o $F/MediaRemoteAdapter
cp $V/bin/mediaremote-adapter.pl $C/Resources/
cp $V/LICENSE $C/Resources/mediaremote-adapter-LICENSE
cp AppIcon.icns $C/Resources/

swiftc -O main.swift selftest.swift -o $C/MacOS/$NAME
cat > $C/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$ID</string>
<key>CFBundleName</key><string>$NAME</string>
<key>CFBundleExecutable</key><string>$NAME</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign -f --deep -s - $B/$NAME.app
echo "OK : $B/$NAME.app"

if [ "$1" = install ]; then
  pkill -x $NAME || true
  rm -rf /Applications/$NAME.app && cp -R $B/$NAME.app /Applications/
  open /Applications/$NAME.app
  echo "Installé : /Applications/$NAME.app"
fi

if [ "$1" = dmg ]; then
  rm -rf $B/dmg && mkdir $B/dmg && cp -R $B/$NAME.app $B/dmg/ && ln -s /Applications $B/dmg/Applications
  hdiutil create -quiet -volname $NAME -srcfolder $B/dmg -ov -format UDZO $B/$NAME.dmg
  echo "OK : $B/$NAME.dmg"
fi
