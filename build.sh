#!/bin/sh
# Compiles the watcher, with bridge.js embedded, into one executable that
# needs no bun or node.
#   ./build.sh            dist/qobuz-now-playing for this Mac, version "dev"
#   ./build.sh 1.2.0      also dist/qobuz-now-playing-1.2.0-macos-{arm64,x64}.tar.gz
#                         for a GitHub release, and prints their SHA-256
# The tarballs are per architecture: a universal binary would be twice the size.
set -eu

VERSION="${1:-}"
cd "$(dirname "$0")"

command -v bun >/dev/null || { echo "error: building needs bun (https://bun.sh)" >&2; exit 1; }

# compile <arch> <outfile> <version>
compile() {
  bun build src/watcher.mjs --compile --minify \
    --target="bun-darwin-$1" \
    --define "process.env.QOBUZ_NOW_PLAYING_VERSION=\"$3\"" \
    --outfile "$2" >/dev/null
  # bun's signature doesn't cover the embedded code; Apple silicon needs a valid one.
  codesign --force --sign - "$2" 2>/dev/null
}

rm -rf dist
mkdir -p dist

if [ -z "$VERSION" ]; then
  case "$(uname -m)" in arm64) ARCH=arm64 ;; *) ARCH=x64 ;; esac
  compile "$ARCH" dist/qobuz-now-playing dev
  echo "Built dist/qobuz-now-playing"
  exit 0
fi

for ARCH in arm64 x64; do
  PKG="qobuz-now-playing-$VERSION"
  mkdir -p "dist/$PKG"
  compile "$ARCH" "dist/$PKG/qobuz-now-playing" "$VERSION"
  cp install.sh uninstall.sh README.md LICENSE "dist/$PKG/"
  tar -C dist -czf "dist/$PKG-macos-$ARCH.tar.gz" "$PKG"
  rm -rf "dist/$PKG"
done
(cd dist && shasum -a 256 ./*.tar.gz)
