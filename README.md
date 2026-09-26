# qobuz-now-playing

Makes the Qobuz desktop app for macOS show up in **Now Playing**: Control Center, the lock screen and the menu bar get the current track, artist, album, artwork and progress, and their play/pause/next/previous buttons and progress bar control Qobuz.

It doesn't modify the Qobuz app bundle, so it keeps working across Qobuz updates as long as the app's internals don't change much. Qobuz plays audio through its own engine instead of Chromium, so macOS never learns what's playing; this tool fills that in. See [How it works](docs/how-it-works.md).

> Unofficial. Not affiliated with or endorsed by Qobuz.

Requires macOS 13 (Ventura) or newer, with Qobuz in `/Applications`. Tested with Qobuz 8.2.0 (Electron 32) on macOS 27.

## Install

Pick one, not both:

- **The Mac app**: a menu-bar app that runs the bridge while it's open. No Terminal needed.
- **The background service**, installed with Homebrew or a script. It has no icon and starts at login.

### Mac app

1. Download `Qobuz-Now-Playing-<version>-macos-arm64.zip` from the [latest release](https://github.com/uifi95/qobuz-now-playing/releases/latest), or `-x64.zip` for an Intel Mac (Apple menu → **About This Mac**: "Apple M…" means arm64).
2. Unzip it and drag **Qobuz Now Playing** into **Applications**.
3. Open it. The app isn't notarized, so macOS refuses the first time with "Apple could not verify…". Click **Done**, then in **System Settings → Privacy & Security** click **Open Anyway** next to "Qobuz Now Playing was blocked…". (Or run `xattr -dr com.apple.quarantine "/Applications/Qobuz Now Playing.app"`.)
4. The setup window opens. If it says **Turn off Qobuz in Accessibility**, click **Open Accessibility Settings**, switch Qobuz off, then click **Reopen Qobuz**. When Qobuz asks for the access again, tick the option to not ask again and decline. ([Why](docs/how-it-works.md#media-keys-and-accessibility-access).)
5. A ♪ icon appears in the menu bar, saying **Working: Qobuz shows in Now Playing** while Qobuz is open. It becomes ⚠ if something needs attention.

The app turns on **Open at login** the first time it runs. The setup window can also hide the menu-bar icon; open the app again from Applications or Spotlight to get the window back. To update, quit it and replace it with a newer one.

If the background service is already installed, the app offers to remove it so only one copy runs. After a Homebrew install, also run `brew uninstall --cask qobuz-now-playing`.

### Background service

With [Homebrew](https://brew.sh):

```sh
brew install --cask uifi95/tap/qobuz-now-playing
```

Update with `brew upgrade --cask qobuz-now-playing`.

Without Homebrew, download the `.tar.gz` for your Mac (`arm64` or `x64`) from the [latest release](https://github.com/uifi95/qobuz-now-playing/releases/latest), open it, drag `install.sh` from the extracted folder into Terminal and press Return. Run a newer release's `install.sh` to update. To build from source, see [Development](docs/development.md).

The service starts right away and at every login. Then:

1. Remove Qobuz's Accessibility access, so the keyboard's media keys control whatever is playing instead of always Qobuz, and restart Qobuz:

   ```sh
   tccutil reset Accessibility com.qobuz.desktop
   osascript -e 'quit app "Qobuz"'; sleep 3; open -a Qobuz
   ```

   When Qobuz asks for the access again, tick the option to not ask again and decline.
2. With Qobuz open, check the log for `bridge: installed`:

   ```sh
   tail ~/.qobuz-nowplaying/watcher.log
   ```

## Uninstall

- **Mac app:** quit it from its menu and move it to the Trash.
- **Homebrew:** `brew uninstall --cask qobuz-now-playing`
- **Script:** run `uninstall.sh` from the release folder or checkout, like `install.sh`.

Then quit and reopen Qobuz. Grant Qobuz Accessibility access again if you want its own media-key shortcuts back.

## More

- [How it works](docs/how-it-works.md): why Qobuz doesn't show up on its own, media keys, security
- [Troubleshooting](docs/troubleshooting.md)
- [Development](docs/development.md): building, fixing it after a Qobuz update, releasing

## License

[MIT](LICENSE)
