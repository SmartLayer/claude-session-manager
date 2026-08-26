#!/usr/bin/env bash
#
# Wrap the self-contained macOS image in the two things a Mac user expects: a
# double-clickable questlog.app, and a .dmg to drag it from.
#
# The image built by build-selfcontained.sh is a bare Mach-O. Handed to a Mac
# user it has no icon, no Finder launch, no name in the menu bar, and it runs
# only from a terminal. The bundle changes none of the program: the same single
# file becomes Contents/MacOS/questlog, and Info.plist plus an .icns is all that
# sits beside it.
#
# The bundle ships whatever signature the executable already has, and adds
# none. codesign will not sign a zipfs image: mkimg appends its archive past
# the end of the Mach-O's __LINKEDIT, and codesign rejects that shape as "main
# executable failed strict validation". What the executable carries is the
# ad-hoc signature the linker gave the wish it was stubbed onto.
#
# Signing is attempted anyway, and a refusal is reported and passed over
# rather than failing the build: whether the bundle can be signed is a
# property of the image shape, while whether it runs is what the build then
# goes on to test.
#
# Gatekeeper is a separate matter and no build step reaches it. A download
# that no Developer ID signed and Apple did not notarize is quarantined, and
# the user clears that per install (Control-click -> Open, or `xattr -dr
# com.apple.quarantine`). docs/installation.md carries the instruction.
#
# Usage:
#   zipfs/macos-bundle.sh <image> <version> <arch>
#
# Produces, beside the image:
#   dist/questlog.app
#   dist/questlog-<version>-macos-<arch>.dmg

set -euo pipefail

IMAGE="${1:?usage: macos-bundle.sh <image> <version> <arch>}"
VERSION="${2:?}"
ARCH="${3:?}"

BUNDLE_ID="io.github.overseers-desk.questlog"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$(cd "$(dirname "$IMAGE")" && pwd)"
APP="$DIST/questlog.app"
DMG="$DIST/questlog-$VERSION-macos-$ARCH.dmg"

rm -rf "$APP" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "== icon =="
# .icns wants the ladder of sizes; sips resamples them from the 512 master and
# iconutil seals the set. A missing icon would leave the generic-app tile, so
# the absence of either tool is a build failure rather than something to skip.
ICONSET="$(mktemp -d)/questlog.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$REPO_ROOT/assets/questlog-512.png" \
        --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$REPO_ROOT/assets/questlog-512.png" \
        --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/questlog.icns"

echo "== bundle =="
cp "$IMAGE" "$APP/Contents/MacOS/questlog"
chmod 0755 "$APP/Contents/MacOS/questlog"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# LSMinimumSystemVersion 11.0: the floor where Apple Silicon starts, and above
# Tk 9's own 10.15 floor, so one number covers both slices this ships for.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>questlog</string>
    <key>CFBundleDisplayName</key>       <string>questlog</string>
    <key>CFBundleExecutable</key>        <string>questlog</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>          <string>questlog.icns</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleSignature</key>         <string>????</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key>    <string>11.0</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

echo "== signature =="
if codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP" 2>&1; then
    codesign --verify --verbose "$APP"
else
    echo "bundle ships with the executable's own signature; see the header"
fi

echo "== dmg =="
# The window a user opens: the app on one side, a link to /Applications on the
# other, so the install is the drag between them.
STAGE="$(mktemp -d)/questlog"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/questlog.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "questlog $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO -quiet "$DMG"

echo "built $APP"
echo "built $DMG"
