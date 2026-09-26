#!/bin/sh
# Prints the Homebrew cask for a release, for the uifi95/homebrew-tap repo
# (Casks/qobuz-now-playing.rb). Run after ./build.sh <version>.
# Usage: packaging/cask.sh <version> [url-base]
#   url-base defaults to the GitHub release download URL for v<version>.
# A cask rather than a formula: formulae without bottles need up-to-date
# Command Line Tools to install, even when there's nothing to compile.
set -eu

VERSION="$1"
cd "$(dirname "$0")/.."
BASE="${2:-https://github.com/uifi95/qobuz-now-playing/releases/download/v$VERSION}"
sha() { shasum -a 256 "dist/qobuz-now-playing-$VERSION-macos-$1.tar.gz" | cut -d' ' -f1; }

cat <<RUBY
cask "qobuz-now-playing" do
  arch arm: "arm64", intel: "x64"

  version "$VERSION"
  sha256 arm:   "$(sha arm64)",
         intel: "$(sha x64)"

  url "$BASE/qobuz-now-playing-#{version}-macos-#{arch}.tar.gz"
  name "Qobuz Now Playing"
  desc "Shows the Qobuz desktop app in macOS Now Playing"
  homepage "https://github.com/uifi95/qobuz-now-playing"

  depends_on macos: :ventura

  # install.sh copies the watcher to ~/.qobuz-nowplaying and starts it as a
  # LaunchAgent; uninstall.sh stops it and removes both.
  installer script: {
    executable: "qobuz-now-playing-#{version}/install.sh",
  }

  uninstall script: {
    executable: "qobuz-now-playing-#{version}/uninstall.sh",
  }

  caveats <<~EOS
    So the keyboard's media keys control whatever is playing, not always
    Qobuz, remove Qobuz's Accessibility access, then quit and reopen Qobuz:
      tccutil reset Accessibility com.qobuz.desktop
  EOS
end
RUBY
