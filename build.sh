#!/bin/zsh
# Compila o BROS-MUX.app (Abdala Brothers) e instala em /Applications
set -e
cd "$(dirname "$0")"
VERSION=1.2                      # keep in step with AppInfo.version in Design.swift
NAME="BROS-MUX (v.$VERSION)"
APP=build/BROS-MUX.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary (Apple Silicon + Intel) so the same app runs on every Mac; FAST=1 builds only this machine's slice.
if [ -n "$FAST" ]; then ARCHS=($(uname -m)); else ARCHS=(arm64 x86_64); fi
SLICES=()
for arch in $ARCHS; do
  echo "compiling $arch…"
  if swiftc -O -parse-as-library -swift-version 5 -target $arch-apple-macos14.0 *.swift -o "build/BROS-MUX-$arch"; then
    SLICES+=("build/BROS-MUX-$arch")
  else
    echo "WARNING: the $arch slice did not compile; the app will not run on $arch Macs"
  fi
done
[ ${#SLICES[@]} -gt 0 ] || { echo "no slice compiled"; exit 1; }
lipo -create $SLICES -output "$APP/Contents/MacOS/BROS-MUX"
rm -f $SLICES

[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>com.abdalabrothers.brosmux</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>BROS-MUX</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHumanReadableCopyright</key><string>Abdala Brothers</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>public.movie</string><string>public.audio</string><string>public.text</string><string>public.data</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP"
echo "OK: $APP"
