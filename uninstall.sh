#!/bin/sh
# Removes the Qobuz Now Playing bridge. Restart Qobuz afterwards to drop the debug port.
set -eu

LABEL="com.user.qobuz-nowplaying"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/.qobuz-nowplaying"

echo "Uninstalled. Quit and reopen Qobuz to run it without the debug port."
