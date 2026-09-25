# qobuz-now-playing

Makes the Qobuz desktop app for macOS show up in **Now Playing**: Control Center, the lock screen and the menu bar get the current track, artist, album, artwork and progress, and their play/pause/next/previous buttons and progress bar control Qobuz.

It doesn't modify the Qobuz app bundle. It keeps working across Qobuz updates as long as the app's internals don't change much.

> Unofficial. Not affiliated with or endorsed by Qobuz.

## Why this is needed

The Qobuz Mac app is built on Electron, but it plays audio through its own native engine (JUCE) rather than through Chromium. macOS learns what's playing from Chromium's media session, and that session only exists when a page plays an `<audio>`/`<video>` element. Qobuz never plays one, so macOS never hears about the track. The app registers the media keys as global shortcuts and does nothing else. On macOS, Electron implements those shortcuts through the same remote command center Now Playing uses, and turns off Chromium's own handling while they are registered, so a page's media session never receives remote commands such as seeking. If Qobuz also has Accessibility access, which it asks for on launch, Chromium grabs the keyboard's media keys before macOS can send them to the app that's playing, so they always control Qobuz. See [Media keys and Accessibility access](#media-keys-and-accessibility-access).

## How it works

1. **`watcher.mjs`** runs in the background as a per-user LaunchAgent.
   - When you open Qobuz normally, the watcher restarts it once with `--remote-debugging-port=9333 --remote-debugging-address=127.0.0.1 --inspect=127.0.0.1:9334`.
   - It only does this within the first 30 seconds after launch, so it never interrupts music that's already playing.
   - It then injects the bridge into the Qobuz window, and injects it again after reloads and updates.
   - Once the bridge is in, it uses the Node inspector on port 9334 to unregister Qobuz's media-key shortcuts in the main process, then closes that port. Now Playing commands then reach the bridge instead.
   - It logs a warning if Qobuz still has Accessibility access. See [Media keys and Accessibility access](#media-keys-and-accessibility-access).
2. **`bridge.js`** runs inside the Qobuz page.
   - It reads the player state from the app's Redux store: current track, play state, position, and track/album metadata.
   - It copies that state into `navigator.mediaSession`.
   - While Qobuz plays, it loops a silent 10-second clip so Chromium publishes the session to macOS.
   - Play, pause, next and previous click Qobuz's own player buttons. Seeking calls the same action as Qobuz's progress bar.

## Requirements

- macOS with the Qobuz desktop app in `/Applications`
- [bun](https://bun.sh) (`brew install bun`) or Node.js 22 or newer

Tested with Qobuz 8.2.0 (Electron 32) on macOS 27.

## Install

```sh
git clone https://github.com/uifi95/qobuz-now-playing.git
cd qobuz-now-playing
./install.sh
```

1. Remove Qobuz's Accessibility access, so the keyboard's media keys control whatever is playing instead of always Qobuz. Open **System Settings → Privacy & Security → Accessibility**, select **Qobuz** and click **−**. This opens that list directly:

   ```sh
   open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
   ```

   Or remove the entry from a terminal:

   ```sh
   tccutil reset Accessibility com.qobuz.desktop
   ```

   When Qobuz asks for the access again on launch, tick the option to not ask again and decline.
2. Quit Qobuz and open it again. It closes and reopens by itself once. Let it do that; if you reopen it yourself in between, it starts without the bridge. From then on the current track shows in Now Playing, and the media keys control Qobuz whenever it's the app that played last.

`install.sh` copies `src/` to `~/.qobuz-nowplaying/` and registers `~/Library/LaunchAgents/com.user.qobuz-nowplaying.plist`. Re-run it to update. If your node comes from a version manager (nvm, fnm, volta), re-run it whenever that path changes, or install bun.

## Media keys and Accessibility access

Qobuz asks for Accessibility access so its media-key shortcuts work. This tool doesn't need it, and leaving it on breaks the media keys for every other app.

Electron (Chromium) watches the keyboard's play/pause, next and previous keys with an event tap. macOS lets that tap intercept keys only when the app has Accessibility access. With access, the keys reach Qobuz before macOS can send them to the Now Playing app, so they control Qobuz even while a browser or another player is playing. Unregistering Qobuz's shortcuts doesn't remove the tap, and nothing outside Qobuz can remove it while the access is granted.

Without Accessibility access there's no tap, and the keys behave as they do for other apps: macOS sends them to the Now Playing app, and Qobuz receives them through its media session when it's that app. Control Center and the lock screen always go through Now Playing, so they work either way.

When Qobuz is the app that played last, the keys control it. If nothing has played since you logged in, macOS opens Apple Music when you press play/pause. That's also standard macOS behavior.

## Uninstall

```sh
./uninstall.sh
```

Then quit and reopen Qobuz so it runs without the debug port. Qobuz's own media-key shortcuts need Accessibility access, so grant it again if you want them back.

## Troubleshooting

```sh
# Watcher running?
launchctl print gui/$(id -u)/com.user.qobuz-nowplaying | grep -E 'state|pid'

# What has it done? A healthy run logs: watcher started / relaunching Qobuz with debug port / bridge: installed / media keys: released
tail -20 ~/.qobuz-nowplaying/watcher.log ~/.qobuz-nowplaying/watcher.err.log

# What does macOS report as Now Playing?
osascript -l JavaScript tools/now-playing.js

# Inspect the live Qobuz page
bun tools/cdp.mjs 'JSON.stringify({bridge: !!window.__qobuzNowPlaying, state: navigator.mediaSession.playbackState, title: navigator.mediaSession.metadata?.title})'
```

| Symptom | Fix |
|---|---|
| Qobuz was already open when you installed | Quit Qobuz and open it again. The watcher only restarts it right after launch. |
| No `relaunching` line in the log | `launchctl kickstart -k gui/$(id -u)/com.user.qobuz-nowplaying` |
| `inject error`, or `bridge: installed` never appears | A Qobuz update probably changed its internals. See below. |
| Buttons work but the progress bar can't seek | Qobuz was started without `--inspect` (for example, before this version was installed), so `media keys: released` is missing from the log. Quit and reopen Qobuz. |
| Track shows but the buttons do nothing | The player button class names changed. Update the `.player__action-*` selectors in `src/bridge.js`. |
| The keyboard's media keys control Qobuz while another app plays | Qobuz has Accessibility access; the log says so after `media keys: released`. Remove it (see [Install](#install), step 1) and restart Qobuz. |
| Play/pause opens Apple Music | No app is in Now Playing. Play a track in Qobuz once so macOS registers it. If that doesn't help, check that the bridge is in (below). |
| `relaunching` in the log, but no `bridge: installed` after it | Qobuz was reopened before the watcher's own relaunch, so it runs without the debug port. Quit Qobuz, open it again, and let it close and reopen by itself. |
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

Use `tools/cdp.mjs` to explore the live page, fix `src/bridge.js`, bump its `VERSION`, then re-run `./install.sh`. The watcher replaces the running bridge with the new version. Pull requests are welcome.

## Security

While Qobuz runs through this tool, it listens on a Chrome DevTools port bound to `127.0.0.1`. Chromium rejects WebSocket connections that come from websites, so a webpage can't reach it. Any local process running as your user can, and it could control the Qobuz page. Such a process can already read Qobuz's data in `~/Library/Application Support/Qobuz`, so the extra risk is small, but it isn't zero. Uninstall and restart Qobuz to close the port.

After launch, Qobuz's main process also listens on a Node inspector port bound to `127.0.0.1:9334`. The watcher closes it once the bridge is installed and the media keys are released, normally within seconds. If the bridge never installs, the port stays open until Qobuz quits. The Node inspector rejects requests whose `Host` header isn't an IP address or `localhost`, so a website can't reach it. A local process running as your user could run code in Qobuz while the port is open, which it could already do as that user.

## Approaches that don't work

- **`NODE_OPTIONS=--require …`** (hooking the main process with no debug port): Electron refuses it on macOS with `Node.js environment variables are disabled because this process is invoked by other apps.`
- **Patching `main-darwin.js` inside the bundle:** this breaks the code signature, and the updater overwrites it anyway.
- **Calling the app's IPC from the page:** the page has no `require` or `ipcRenderer` access.

## Known limitations

- Local (non-streaming) tracks may lack artwork or metadata, depending on what Qobuz stores for them.

## License

[MIT](LICENSE)
