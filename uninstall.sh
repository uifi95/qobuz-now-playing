#!/bin/sh
# Removes the Qobuz Now Playing bridge. Restart Qobuz afterwards to remove it from the running app.
set -eu

LABEL="com.user.qobuz-nowplaying"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/.qobuz-nowplaying"

echo "Uninstalled. Quit and reopen Qobuz to remove the bridge from the running app."
