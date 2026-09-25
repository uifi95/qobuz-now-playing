#!/bin/sh
# Installs the Qobuz Now Playing bridge as a per-user LaunchAgent.
# Re-run to update an existing install.
set -eu

LABEL="com.user.qobuz-nowplaying"
INSTALL_DIR="$HOME/.qobuz-nowplaying"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SRC_DIR="$(cd "$(dirname "$0")/src" && pwd)"

if [ ! -d /Applications/Qobuz.app ]; then
  echo "warning: /Applications/Qobuz.app not found; installing anyway" >&2
fi

# Prefer bun, fall back to node >= 22 (needs global WebSocket).
RUNTIME="$(command -v bun || true)"
if [ -z "$RUNTIME" ]; then
  NODE="$(command -v node || true)"
  if [ -n "$NODE" ] && [ "$("$NODE" -p 'process.versions.node.split(".")[0]')" -ge 22 ]; then
    RUNTIME="$NODE"
  else
    echo "error: need bun or node >= 22 on PATH (brew install bun)" >&2
    exit 1
  fi
fi
case "$RUNTIME" in
  */.nvm/*|*/.fnm/*|*/.volta/*)
    echo "note: using $RUNTIME from a version manager; re-run install.sh if that path changes" >&2 ;;
esac

mkdir -p "$INSTALL_DIR" "$HOME/Library/LaunchAgents"
cp "$SRC_DIR/bridge.js" "$SRC_DIR/watcher.mjs" "$INSTALL_DIR/"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$RUNTIME</string>
    <string>$INSTALL_DIR/watcher.mjs</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardErrorPath</key>
  <string>$INSTALL_DIR/watcher.err.log</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST" >/dev/null

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Installed. Runtime: $RUNTIME"
echo "Quit Qobuz and open it again; it will restart itself once."
echo "Log: $INSTALL_DIR/watcher.log"
