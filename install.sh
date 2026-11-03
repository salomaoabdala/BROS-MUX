#!/bin/zsh
# BROS-MUX installer (Abdala Brothers)
#
# Installs everything the app needs on a Mac with Apple Silicon (the app has no Intel build) and the app itself:
#   1. Homebrew, if it is not there yet
#   2. the engines: gpac (MP4Box), ffmpeg (+ ffprobe), media-info, dovi_tool, hdr10plus_tool
#   3. the app: the prebuilt BROS-MUX-v*.zip next to this script (or in dist/), the GitHub release,
#      or a build from source when the Command Line Tools are installed
#   4. copies it to /Applications, clears the download quarantine and opens it
#
# Usage:  ./install.sh            (from the folder of the repository)
#         ./install.sh --build    (always build from source, ignore the zip)
set -e
setopt null_glob            # a glob with no match expands to nothing instead of aborting the command
cd "$(dirname "$0")"

say() { print -P "%F{blue}==>%f $*" }
ok()  { print -P "%F{green}✔%f $*" }
warn(){ print -P "%F{yellow}!%f $*" }

if [ "$(uname)" != "Darwin" ]; then echo "BROS-MUX runs on macOS only."; exit 1; fi
if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 14 ]; then echo "macOS 14 (Sonoma) or newer is required."; exit 1; fi
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" != "1" ]; then echo "BROS-MUX is built for Apple Silicon only (M1 or newer); this Mac is Intel."; exit 1; fi

# 1. Homebrew --------------------------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then eval "$(/usr/local/bin/brew shellenv)"
  else
    say "Installing Homebrew (it will ask for your password)"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; else eval "$(/usr/local/bin/brew shellenv)"; fi
  fi
fi
ok "Homebrew: $(brew --prefix)"

# 2. The engines -----------------------------------------------------------------------------
say "Installing the engines (gpac, ffmpeg, media-info, dovi_tool, hdr10plus_tool)"
brew install gpac ffmpeg media-info dovi_tool hdr10plus_tool
for t in MP4Box ffmpeg ffprobe mediainfo dovi_tool hdr10plus_tool; do
  if command -v $t >/dev/null 2>&1; then ok "$t → $(command -v $t)"; else warn "$t not found in PATH after the install"; fi
done

# 3. The app ---------------------------------------------------------------------------------
APP=/Applications/BROS-MUX.app
STAGE=$(mktemp -d)
zips=(BROS-MUX-v*.zip dist/BROS-MUX-v*.zip); ZIP=${zips[1]}
if [ "$1" != "--build" ] && [ -z "$ZIP" ]; then
  say "Downloading the latest release from GitHub"
  mkdir -p dist
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh release download --pattern 'BROS-MUX-v*.zip' --dir dist --clobber 2>/dev/null || true
  else
    # the repository is public: the release asset can be fetched without any login
    URL=$(curl -fsSL https://api.github.com/repos/salomaoabdala/BROS-MUX/releases/latest | grep -o '"browser_download_url": *"[^"]*BROS-MUX-v[^"]*\.zip"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')
    [ -n "$URL" ] && curl -fL --progress-bar -o "dist/$(basename "$URL")" "$URL" || warn "could not download the release; will build from source if possible"
  fi
  zips=(dist/BROS-MUX-v*.zip); ZIP=${zips[1]}
fi

if [ "$1" != "--build" ] && [ -n "$ZIP" ]; then
  say "Installing the prebuilt app from $ZIP"
  ditto -x -k "$ZIP" "$STAGE"
  SRC=$(find "$STAGE" -maxdepth 2 -name 'BROS-MUX.app' | head -1)
elif [ "$1" != "--build" ] && [ -d build/BROS-MUX.app ]; then
  say "Installing the app already built in build/"
  SRC=build/BROS-MUX.app
else
  if ! xcode-select -p >/dev/null 2>&1 || ! command -v swiftc >/dev/null 2>&1; then
    warn "Building from source needs the Xcode Command Line Tools. Starting their install now;"
    warn "when it finishes, run ./install.sh again."
    xcode-select --install || true
    exit 1
  fi
  say "Building the app from source (two or three minutes)"
  ./build.sh
  SRC=build/BROS-MUX.app
fi

[ -d "$SRC" ] || { echo "No BROS-MUX.app to install."; exit 1; }
say "Installing to $APP"
rm -rf "$APP"
ditto "$SRC" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true   # the app is ad-hoc signed; without this Gatekeeper refuses a downloaded copy
rm -rf "$STAGE"
ok "Installed $(defaults read "$APP/Contents/Info.plist" CFBundleName) $(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
open "$APP"
