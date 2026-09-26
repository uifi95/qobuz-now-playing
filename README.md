# qobuz-now-playing

Makes the Qobuz desktop app for macOS show up in **Now Playing**: Control Center, the lock screen and the menu bar get the current track, artist, album, artwork and progress, and their play/pause/next/previous buttons and progress bar control Qobuz.

It doesn't modify the Qobuz app bundle. It keeps working across Qobuz updates as long as the app's internals don't change much.

> Unofficial. Not affiliated with or endorsed by Qobuz.

## Why this is needed

The Qobuz Mac app is built on Electron, but it plays audio through its own native engine (JUCE) rather than through Chromium. macOS learns what's playing from Chromium's media session, and that session only exists when a page plays an `<audio>`/`<video>` element. Qobuz never plays one, so macOS never hears about the track. The app registers the media keys as global shortcuts and does nothing else. On macOS, Electron implements those shortcuts through the same remote command center Now Playing uses, and turns off Chromium's own handling while they are registered, so a page's media session never receives remote commands such as seeking. If Qobuz also has Accessibility access, which it asks for on launch, Chromium grabs the keyboard's media keys before macOS can send them to the app that's playing, so they always control Qobuz. See [Media keys and Accessibility access](#media-keys-and-accessibility-access).

## How it works

1. **`watcher.mjs`** runs in the background, either as a per-user LaunchAgent or inside the Mac app (`app/main.swift`), which starts it and shows its status. It's compiled with `bridge.js` into a single `qobuz-now-playing` program, so it needs no bun or Node.js to run.
   - It never restarts Qobuz. When Qobuz is running, the watcher sends its main process `SIGUSR1`, which makes Node open its inspector on `127.0.0.1` (port 9229 by default). It does this once per Qobuz launch, and again each time the watcher starts, so an update replaces the running bridge.
   - Through the inspector, it installs a small hook in the main process. The hook injects the bridge into the Qobuz window, and injects it again after every reload.
   - Once the bridge is in, the hook unregisters Qobuz's media-key shortcuts. Now Playing commands then reach the bridge instead.
   - The watcher then closes the inspector, so no debug port stays open.
   - It logs a warning if Qobuz still has Accessibility access. See [Media keys and Accessibility access](#media-keys-and-accessibility-access).
2. **`bridge.js`** runs inside the Qobuz page.
   - It reads the player state from the app's Redux store: current track, play state, position, and track/album metadata.
   - It copies that state into `navigator.mediaSession`.
   - While Qobuz plays, it loops a silent 10-second clip so Chromium publishes the session to macOS.
   - Play, pause, next and previous click Qobuz's own player buttons. Seeking calls the same action as Qobuz's progress bar.

## Requirements

- macOS 13 (Ventura) or newer, with the Qobuz desktop app in `/Applications`

Tested with Qobuz 8.2.0 (Electron 32) on macOS 27.

## Install

There are two ways to run it. Use one, not both:

- **The Mac app**: a menu-bar app that runs the bridge while it's open. No Terminal needed.
- **The background service**, installed with Homebrew or a script. It has no icon and starts at login.

### Mac app

1. Download `Qobuz-Now-Playing-<version>-macos-arm64.zip` from the [latest release](https://github.com/uifi95/qobuz-now-playing/releases/latest), or `-x64.zip` for an Intel Mac. Not sure which? Apple menu → **About This Mac**: "Apple M…" means arm64, "Intel" means x64.
2. Open the zip and drag **Qobuz Now Playing** into your **Applications** folder.
3. Open it. The app isn't notarized by Apple (that needs a paid developer account), so macOS refuses the first time with "Apple could not verify…". Click **Done**, then open **System Settings → Privacy & Security**, scroll to "Qobuz Now Playing was blocked…" and click **Open Anyway**, then confirm. You only do this once.
4. The setup window opens. If it says **Turn off Qobuz in Accessibility**, click **Open Accessibility Settings**, switch off Qobuz in the list, then click **Reopen Qobuz**. When Qobuz asks for the access again, tick the option to not ask again and decline. The window turns green once Qobuz no longer has the access ([why this matters](#media-keys-and-accessibility-access)). Qobuz Now Playing itself doesn't need Accessibility access.
5. A ♪ icon appears in the menu bar. Its menu says **Working: Qobuz shows in Now Playing** while Qobuz is open. It becomes ⚠ if something needs attention.

The app turns on **Open at login** the first time it runs, so it starts with your Mac. The setup window also has **Show icon in the menu bar**. Untick it and the app keeps running without an icon. To get the window back, open Qobuz Now Playing again from Applications or Spotlight; with the icon showing, use its **Settings…** item. **Show Log** opens `~/Library/Logs/Qobuz Now Playing.log`. To update, quit the app and replace it with a newer one. To uninstall, quit it and move it to the Trash.

If you had the background service installed (Homebrew or `install.sh`), the app offers to remove it the first time it opens, so only one copy runs. After a Homebrew install, also run `brew uninstall --cask qobuz-now-playing` so Homebrew stops tracking it.

If you'd rather use Terminal for step 3: `xattr -dr com.apple.quarantine "/Applications/Qobuz Now Playing.app"`.

### Homebrew

With [Homebrew](https://brew.sh), open Terminal and run:

```sh
brew install --cask uifi95/tap/qobuz-now-playing
```

It starts right away and at every login. Then finish with [After installing the background service](#after-installing-the-background-service). Homebrew prints the same steps. Update it with `brew upgrade --cask qobuz-now-playing`.

### Without Homebrew

Download the `.tar.gz` for your Mac from the [latest release](https://github.com/uifi95/qobuz-now-playing/releases/latest): `arm64` for Apple silicon (M1 and later), `x64` for Intel. Open it, then drag the `install.sh` file from the folder it creates into a Terminal window and press Return. Run a newer release's `install.sh` the same way to update.

### From source

```sh
git clone https://github.com/uifi95/qobuz-now-playing.git
cd qobuz-now-playing
./install.sh
```

This needs [bun](https://bun.sh) (`brew install bun`): `install.sh` runs `build.sh`, which compiles `src/watcher.mjs`, with `src/bridge.js` embedded, into `dist/qobuz-now-playing`. Re-run `./install.sh` after changing either file.

To build the Mac app instead, run `./build.sh app`. It also needs Xcode or its Command Line Tools (`xcode-select --install`), and writes `dist/Qobuz Now Playing.app`. Move it to Applications and open it; a local build isn't quarantined, so macOS doesn't block it.

`install.sh` copies the `qobuz-now-playing` program to `~/.qobuz-nowplaying/` and registers `~/Library/LaunchAgents/com.user.qobuz-nowplaying.plist`. The Homebrew cask runs the same script.

### After installing the background service

1. Remove Qobuz's Accessibility access, so the keyboard's media keys control whatever is playing instead of always Qobuz, then quit and reopen Qobuz:

   ```sh
   tccutil reset Accessibility com.qobuz.desktop
   osascript -e 'quit app "Qobuz"'; sleep 3; open -a Qobuz
   ```

   Or do it by hand: open **System Settings → Privacy & Security → Accessibility**, select **Qobuz**, click **−**, then quit and reopen Qobuz.

   When Qobuz asks for the access again on launch, tick the option to not ask again and decline.
2. Check it works. With Qobuz open, a log line like `bridge: installed` means it's connected:

   ```sh
   tail ~/.qobuz-nowplaying/watcher.log
   ```

   From then on the current track shows in Now Playing, and the media keys control Qobuz whenever it's the app that played last. There's nothing else to restart: the service picks up Qobuz within a few seconds of it opening.

## Media keys and Accessibility access

Qobuz asks for Accessibility access so its media-key shortcuts work. This tool doesn't need it, and leaving it on breaks the media keys for every other app.

Electron (Chromium) watches the keyboard's play/pause, next and previous keys with an event tap. macOS lets that tap intercept keys only when the app has Accessibility access. With access, the keys reach Qobuz before macOS can send them to the Now Playing app, so they control Qobuz even while a browser or another player is playing. Unregistering Qobuz's shortcuts doesn't remove the tap, and nothing outside Qobuz can remove it while the access is granted.

Without Accessibility access there's no tap, and the keys behave as they do for other apps: macOS sends them to the Now Playing app, and Qobuz receives them through its media session when it's that app. Control Center and the lock screen always go through Now Playing, so they work either way.

When Qobuz is the app that played last, the keys control it. If nothing has played since you logged in, macOS opens Apple Music when you press play/pause. That's also standard macOS behavior.

## Uninstall

The Mac app: quit it from its menu and move it to the Trash.

If you installed with Homebrew:

```sh
brew uninstall --cask qobuz-now-playing
```

Otherwise run `uninstall.sh` from the release folder or checkout, the same way as `install.sh`.

Then quit and reopen Qobuz to remove the bridge from the running app. Qobuz's own media-key shortcuts need Accessibility access, so grant it again if you want them back.

## Troubleshooting

```sh
# Watcher running?
launchctl print gui/$(id -u)/com.user.qobuz-nowplaying | grep -E 'state|pid'

# What has it done? A healthy run logs: watcher started / bridge: installed
tail -20 ~/.qobuz-nowplaying/watcher.log ~/.qobuz-nowplaying/watcher.err.log
# The Mac app's log (also its Show Log menu item)
tail -20 ~/Library/Logs/"Qobuz Now Playing.log"

# What does macOS report as Now Playing?
osascript -l JavaScript tools/now-playing.js

# Inspect the live Qobuz page
bun tools/cdp.mjs 'JSON.stringify({bridge: !!window.__qobuzNowPlaying, state: navigator.mediaSession.playbackState, title: navigator.mediaSession.metadata?.title})'
```

| Symptom | Fix |
|---|---|
| No `bridge:` line in the log | `launchctl kickstart -k gui/$(id -u)/com.user.qobuz-nowplaying` |
| `inject error: Qobuz did not open its inspector` | Another process may be using port 9229. Check with `lsof -nP -iTCP:9229`, stop it, then quit and reopen Qobuz. |
| `bridge: waiting for the Qobuz page` | Qobuz hadn't finished loading. The hook keeps trying inside Qobuz; check the page with `tools/cdp.mjs` (below). |
| `inject error`, or `bridge: installed` never appears | A Qobuz update probably changed its internals. See below. |
| Buttons work but the progress bar can't seek | Qobuz's media-key shortcuts weren't released. Quit and reopen Qobuz, and check that `bridge: installed` appears in the log. |
| Track shows but the buttons do nothing | The player button class names changed. Update the `.player__action-*` selectors in `src/bridge.js`. |
| The keyboard's media keys control Qobuz while another app plays | Qobuz has Accessibility access; the log says so on the `bridge:` line. Remove it (the Mac app's setup window, or [step 1 here](#after-installing-the-background-service)). |
| Play/pause opens Apple Music | No app is in Now Playing. Play a track in Qobuz once so macOS registers it. If that doesn't help, check that the bridge is in (below). |
| Another app appears while Qobuz is paused | Normal. macOS shows the app that played most recently. |

### After a Qobuz update

The bridge depends on these parts of Qobuz's internals:

| Where | What |
|---|---|
| `player.currentTrack.id`, `.duration` (ms) | Current track |
| `player.playingState` (`"play"` when playing) | Play state |
| `player.position` `{value (ms), timestamp}` | Elapsed time |
| `dictionnary.tracks.data[id]` | Title, version, interpreters, `releaseId` |
| `dictionnary.releases.data[releaseId]` | Album title, artists, `image.small` / `image.large` |
| `.player__action-play`, `-pause`, `-next`, `-previous` | Buttons clicked for remote commands |
| A component prop `seek({position})` (ms) | Progress bar's seek action, called for `seekto` |
| `globalShortcut` `MediaPlayPause`, `MediaNextTrack`, `MediaPreviousTrack` (main process) | Shortcuts released so Chromium routes commands to the page |

Use `tools/cdp.mjs` to explore the live page, fix `src/bridge.js`, bump its `VERSION`, then re-run `./install.sh`. The restarted watcher replaces the running bridge with the new version. Pull requests are welcome.

## Releasing

Push a tag such as `v1.2.0`. The `release` workflow builds `qobuz-now-playing-<version>-macos-{arm64,x64}.tar.gz` and the Mac app's `Qobuz-Now-Playing-<version>-macos-{arm64,x64}.zip` with `./build.sh <version>`, publishes them as a GitHub release, and updates `Casks/qobuz-now-playing.rb` in [uifi95/homebrew-tap](https://github.com/uifi95/homebrew-tap) (see the workflow for the token it needs). `packaging/cask.sh` generates the cask.

## Security

Qobuz keeps no debug port open. Each time the watcher installs or updates the bridge, Qobuz's main process listens on a Node inspector port on `127.0.0.1` (9229 by default) for a few seconds, at most about 20 s while the page loads, and the watcher then closes it. The Node inspector rejects requests whose `Host` header isn't an IP address or `localhost`, so a website can't reach it. A local process running as your user could run code in Qobuz while the port is open. It could already do that by sending Qobuz `SIGUSR1` itself, and it can read Qobuz's data in `~/Library/Application Support/Qobuz`.

## Approaches that don't work

- **Restarting Qobuz with `--remote-debugging-port` and `--inspect`:** this is what earlier versions did. The window visibly closes and reopens, and a Qobuz that was already running (for example, opened at login) was left without the bridge.
- **`NODE_OPTIONS=--require …`** (hooking the main process with no debug port): Electron refuses it on macOS with `Node.js environment variables are disabled because this process is invoked by other apps.`
- **Patching `main-darwin.js` inside the bundle:** this breaks the code signature, and the updater overwrites it anyway.
- **Calling the app's IPC from the page:** the page has no `require` or `ipcRenderer` access.

## Known limitations

- Local (non-streaming) tracks may lack artwork or metadata, depending on what Qobuz stores for them.

## License

[MIT](LICENSE)
