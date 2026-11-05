#!/bin/zsh
# Compila o BROS-MUX.app (Abdala Brothers) — só para Apple Silicon.
#
# The app is built for arm64 and nothing else. There is no Intel (x86_64) slice on purpose: every Mac at Abdala
# Brothers is Apple Silicon, and an app with no Intel code can never be run through Rosetta — which is what made
# macOS 26 show "Support Ending for Intel-based Apps" for the old universal build. Info.plist also declares
# LSRequiresNativeExecution, so Launch Services refuses to translate the app even if "Open using Rosetta" is ticked.
set -e
cd "$(dirname "$0")"
VERSION=2.0.1                    # keep in step with AppInfo.version in Design.swift
LABEL="Beta 2.0.1"               # the working version's name (AppInfo.label); a beta installs beside the stable app
NAME="BROS-MUX $LABEL"
APP=build.noindex/BROS-MUX.app   # .noindex: Spotlight skips it, so only /Applications shows up in search
ARCH=arm64
MACOS_MIN=14.0
rm -rf build build.noindex
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Whole-module optimization is what Xcode uses for Release builds: the app is compiled as one unit, so generics and
# small functions are specialised and inlined across files; -num-threads keeps the code generation parallel.
echo "compiling for $ARCH (Apple Silicon), optimized, whole module…"
swiftc -O -wmo -num-threads "$(sysctl -n hw.ncpu)" -parse-as-library -swift-version 5 \
  -target "$ARCH-apple-macos$MACOS_MIN" *.swift -o "$APP/Contents/MacOS/BROS-MUX"
# set -e: a compile error stops the build right here — nothing else is ever shipped in place of the arm64 binary.

[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/"
# official Dolby Vision / HDR10+ logo art, when someone drops it in Logos/ (the app draws its own vector badges otherwise)
if [ -d Logos ]; then mkdir -p "$APP/Contents/Resources/Logos"; cp Logos/*.pdf "$APP/Contents/Resources/Logos/" 2>/dev/null || true; fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>com.abdalabrothers.brosmux.beta</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>BROS-MUX</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>$MACOS_MIN</string>
  <key>LSArchitecturePriority</key>
  <array><string>$ARCH</string></array>
  <key>LSRequiresNativeExecution</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHumanReadableCopyright</key><string>Abdala Brothers</string>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.abdalabrothers.brosmux.job</string>
      <key>UTTypeDescription</key><string>BROS-MUX delivery job</string>
      <key>UTTypeConformsTo</key><array><string>public.json</string></array>
      <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>bmjob</string></array></dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>BROS-MUX delivery job</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>com.abdalabrothers.brosmux.job</string></array>
    </dict>
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
echo "OK: $APP — $(lipo -archs "$APP/Contents/MacOS/BROS-MUX") only, $(du -h "$APP/Contents/MacOS/BROS-MUX" | cut -f1)"
