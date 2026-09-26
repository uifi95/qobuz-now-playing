#!/bin/sh
# Installs the Qobuz Now Playing bridge as a per-user LaunchAgent.
# Run it from an unpacked release (uses the bundled qobuz-now-playing) or from
# a checkout (builds it first, which needs bun). Re-run to update. The Homebrew
# cask runs it too.
set -eu

LABEL="com.user.qobuz-nowplaying"
INSTALL_DIR="$HOME/.qobuz-nowplaying"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ ! -d /Applications/Qobuz.app ]; then
  echo "warning: /Applications/Qobuz.app not found; installing anyway" >&2
fi

if [ -f "$HERE/qobuz-now-playing" ]; then
  BIN="$HERE/qobuz-now-playing"
else
  "$HERE/build.sh"
  BIN="$HERE/dist/qobuz-now-playing"
fi

mkdir -p "$INSTALL_DIR" "$HOME/Library/LaunchAgents"
# Files from versions that ran the watcher script with bun or node.
rm -f "$INSTALL_DIR/watcher.mjs" "$INSTALL_DIR/bridge.js"
cp "$BIN" "$INSTALL_DIR/qobuz-now-playing"
# A release downloaded with a browser is quarantined, and Gatekeeper would stop
# launchd from running the unnotarized binary.
xattr -d com.apple.quarantine "$INSTALL_DIR/qobuz-now-playing" 2>/dev/null || true

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$INSTALL_DIR/qobuz-now-playing</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>$INSTALL_DIR/watcher.log</string>
  <key>StandardErrorPath</key>
  <string>$INSTALL_DIR/watcher.err.log</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST" >/dev/null

# bootout returns before the service is gone, and bootstrapping it again too
# early fails with "Bootstrap failed: 5: Input/output error".
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break
  sleep 0.5
done
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Installed qobuz-now-playing $("$INSTALL_DIR/qobuz-now-playing" --version). It starts at every login."
echo "If Qobuz is open, the bridge is injected within a few seconds; no restart needed."
echo
echo "One more step, so the keyboard's media keys control whatever is playing instead of"
echo "always Qobuz: remove Qobuz's Accessibility access, then quit and reopen Qobuz:"
echo "  tccutil reset Accessibility com.qobuz.desktop"
echo "  osascript -e 'quit app \"Qobuz\"'; sleep 3; open -a Qobuz"
echo "When Qobuz asks for Accessibility access again, tick the option to not ask again and decline."
echo
echo "To check it works, open Qobuz. A log line like \"bridge: installed\" means it's connected:"
echo "  tail $INSTALL_DIR/watcher.log"
