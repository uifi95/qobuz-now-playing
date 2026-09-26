# qobuz-now-playing

Makes the Qobuz desktop app for macOS show up in **Now Playing**: Control Center, the lock screen and the menu bar get the current track, artist, album, artwork and progress, and their play/pause/next/previous buttons and progress bar control Qobuz.

It doesn't modify the Qobuz app bundle. It keeps working across Qobuz updates as long as the app's internals don't change much.

> Unofficial. Not affiliated with or endorsed by Qobuz.

## Why this is needed

The Qobuz Mac app is built on Electron, but it plays audio through its own native engine (JUCE) rather than through Chromium. macOS learns what's playing from Chromium's media session, and that session only exists when a page plays an `<audio>`/`<video>` element. Qobuz never plays one, so macOS never hears about the track. The app registers the media keys as global shortcuts and does nothing else. On macOS, Electron implements those shortcuts through the same remote command center Now Playing uses, and turns off Chromium's own handling while they are registered, so a page's media session never receives remote commands such as seeking. If Qobuz also has Accessibility access, which it asks for on launch, Chromium grabs the keyboard's media keys before macOS can send them to the app that's playing, so they always control Qobuz. See [Media keys and Accessibility access](#media-keys-and-accessibility-access).

## How it works

1. **`watcher.mjs`** runs in the background as a per-user LaunchAgent. It's compiled with `bridge.js` into a single `qobuz-now-playing` program, so it needs no bun or Node.js to run.
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

With [Homebrew](https://brew.sh), open Terminal and run:

```sh
brew install --cask uifi95/tap/qobuz-now-playing
```

That's all it needs: it starts right away and at every login. Update it with `brew upgrade --cask qobuz-now-playing`.

Without Homebrew, download the `.tar.gz` for your Mac from the [latest release](https://github.com/uifi95/qobuz-now-playing/releases/latest): `arm64` for Apple silicon (M1 and later), `x64` for Intel. Open it, then drag the `install.sh` file from the folder it creates into a Terminal window and press Return. Run a newer release's `install.sh` the same way to update.

Then:

1. Remove Qobuz's Accessibility access, so the keyboard's media keys control whatever is playing instead of always Qobuz. Open **System Settings → Privacy & Security → Accessibility**, select **Qobuz** and click **−**. This opens that list directly:

   ```sh
   open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
   ```

   Or remove the entry from a terminal:

   ```sh
   tccutil reset Accessibility com.qobuz.desktop
   ```

   When Qobuz asks for the access again on launch, tick the option to not ask again and decline.
2. If you removed the access while Qobuz was open, quit Qobuz and open it again. Otherwise there's nothing to restart: the watcher picks up a running Qobuz within a few seconds. From then on the current track shows in Now Playing, and the media keys control Qobuz whenever it's the app that played last.

`install.sh` copies the `qobuz-now-playing` program to `~/.qobuz-nowplaying/` and registers `~/Library/LaunchAgents/com.user.qobuz-nowplaying.plist`. The Homebrew cask runs the same script.

### From source

```sh
git clone https://github.com/uifi95/qobuz-now-playing.git
cd qobuz-now-playing
./install.sh
```

This needs [bun](https://bun.sh) (`brew install bun`): `install.sh` runs `build.sh`, which compiles `src/watcher.mjs`, with `src/bridge.js` embedded, into `dist/qobuz-now-playing`. Re-run `./install.sh` after changing either file.

## Media keys and Accessibility access

Qobuz asks for Accessibility access so its media-key shortcuts work. This tool doesn't need it, and leaving it on breaks the media keys for every other app.

Electron (Chromium) watches the keyboard's play/pause, next and previous keys with an event tap. macOS lets that tap intercept keys only when the app has Accessibility access. With access, the keys reach Qobuz before macOS can send them to the Now Playing app, so they control Qobuz even while a browser or another player is playing. Unregistering Qobuz's shortcuts doesn't remove the tap, and nothing outside Qobuz can remove it while the access is granted.

Without Accessibility access there's no tap, and the keys behave as they do for other apps: macOS sends them to the Now Playing app, and Qobuz receives them through its media session when it's that app. Control Center and the lock screen always go through Now Playing, so they work either way.

When Qobuz is the app that played last, the keys control it. If nothing has played since you logged in, macOS opens Apple Music when you press play/pause. That's also standard macOS behavior.

## Uninstall

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
| The keyboard's media keys control Qobuz while another app plays | Qobuz has Accessibility access; the log says so on the `bridge:` line. Remove it (see [Install](#install), step 1) and restart Qobuz. |
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

Push a tag such as `v1.2.0`. The `release` workflow builds `qobuz-now-playing-<version>-macos-{arm64,x64}.tar.gz` with `./build.sh <version>`, publishes them as a GitHub release, and updates `Casks/qobuz-now-playing.rb` in [uifi95/homebrew-tap](https://github.com/uifi95/homebrew-tap) (see the workflow for the token it needs). `packaging/cask.sh` generates the cask.

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
