#!/bin/sh
# Compiles the watcher, with bridge.js embedded, into one executable that
# needs no bun or node.
# Also wraps it in the menu-bar app (app/), which needs swiftc (Xcode or its
# Command Line Tools).
#   ./build.sh            dist/qobuz-now-playing for this Mac, version "dev"
#   ./build.sh app        also dist/Qobuz Now Playing.app for this Mac
#   ./build.sh 1.2.0      for a GitHub release: dist/qobuz-now-playing-1.2.0-macos-{arm64,x64}.tar.gz
#                         and Qobuz-Now-Playing-1.2.0-macos-{arm64,x64}.zip, and
#                         prints the tarballs' SHA-256
# Everything is per architecture: a universal binary would be twice the size.
set -eu

VERSION="${1:-}"
cd "$(dirname "$0")"

command -v bun >/dev/null || { echo "error: building needs bun (https://bun.sh)" >&2; exit 1; }
APP_NAME="Qobuz Now Playing"

# compile <arch> <outfile> <version>
compile() {
  bun build src/watcher.mjs --compile --minify \
    --target="bun-darwin-$1" \
    --define "process.env.QOBUZ_NOW_PLAYING_VERSION=\"$3\"" \
    --outfile "$2" >/dev/null
  # bun's signature doesn't cover the embedded code; Apple silicon needs a valid one.
  codesign --force --sign - "$2" 2>/dev/null
}

# app <arch> <watcher> <version> <out.app>
# Unsigned apps don't run on Apple silicon, so this signs it ad hoc. Without a
# Developer ID and notarization, Gatekeeper still blocks a downloaded copy
# until it's allowed in System Settings (see the README).
app() {
  case "$1" in arm64) TRIPLE=arm64 ;; *) TRIPLE=x86_64 ;; esac
  mkdir -p "$4/Contents/MacOS"
  swiftc -O -target "$TRIPLE-apple-macos13" app/main.swift -o "$4/Contents/MacOS/$APP_NAME"
  cp "$2" "$4/Contents/MacOS/qobuz-now-playing"
  sed "s/VERSION/$3/" app/Info.plist > "$4/Contents/Info.plist"
  codesign --force --sign - "$4" 2>/dev/null
}

rm -rf dist
mkdir -p dist

if [ -z "$VERSION" ] || [ "$VERSION" = app ]; then
  case "$(uname -m)" in arm64) ARCH=arm64 ;; *) ARCH=x64 ;; esac
  compile "$ARCH" dist/qobuz-now-playing dev
  echo "Built dist/qobuz-now-playing"
  if [ "$VERSION" = app ]; then
    app "$ARCH" dist/qobuz-now-playing dev "dist/$APP_NAME.app"
    echo "Built dist/$APP_NAME.app"
  fi
  exit 0
fi

for ARCH in arm64 x64; do
  PKG="qobuz-now-playing-$VERSION"
  mkdir -p "dist/$PKG"
  compile "$ARCH" "dist/$PKG/qobuz-now-playing" "$VERSION"
  cp install.sh uninstall.sh README.md LICENSE "dist/$PKG/"
  tar -C dist -czf "dist/$PKG-macos-$ARCH.tar.gz" "$PKG"
  app "$ARCH" "dist/$PKG/qobuz-now-playing" "$VERSION" "dist/$APP_NAME.app"
  # ditto keeps the signature intact, which zip doesn't guarantee.
  ditto -c -k --keepParent "dist/$APP_NAME.app" "dist/Qobuz-Now-Playing-$VERSION-macos-$ARCH.zip"
  rm -rf "dist/$PKG" "dist/$APP_NAME.app"
done
(cd dist && shasum -a 256 ./*.tar.gz)
