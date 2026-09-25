# qobuz-now-playing

Makes the Qobuz desktop app for macOS show up in **Now Playing**: Control Center, the lock screen and the menu bar get the current track, artist, album, artwork and progress, and their play/pause/next/previous buttons and progress bar control Qobuz.

It doesn't modify the Qobuz app bundle. It keeps working across Qobuz updates as long as the app's internals don't change much.

> Unofficial. Not affiliated with or endorsed by Qobuz.

## Why this is needed

The Qobuz Mac app is built on Electron, but it plays audio through its own native engine (JUCE) rather than through Chromium. macOS learns what's playing from Chromium's media session, and that session only exists when a page plays an `<audio>`/`<video>` element. Qobuz never plays one, so macOS never hears about the track. The app registers the media keys as global shortcuts and does nothing else. On macOS, Electron implements those shortcuts through the same remote command center Now Playing uses, and turns off Chromium's own handling while they are registered, so a page's media session never receives remote commands such as seeking.

## How it works

1. **`watcher.mjs`** runs in the background as a per-user LaunchAgent.
   - When you open Qobuz normally, the watcher restarts it once with `--remote-debugging-port=9333 --remote-debugging-address=127.0.0.1 --inspect=127.0.0.1:9334`.
   - It only does this within the first 30 seconds after launch, so it never interrupts music that's already playing.
   - It then injects the bridge into the Qobuz window, and injects it again after reloads and updates.
   - Once the bridge is in, it uses the Node inspector on port 9334 to unregister Qobuz's media-key shortcuts in the main process, then closes that port. Now Playing commands then reach the bridge instead.
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

Then quit Qobuz and open it again. It closes and reopens by itself once, and from then on the current track shows in Now Playing.

`install.sh` copies `src/` to `~/.qobuz-nowplaying/` and registers `~/Library/LaunchAgents/com.user.qobuz-nowplaying.plist`. Re-run it to update. If your node comes from a version manager (nvm, fnm, volta), re-run it whenever that path changes, or install bun.

## Uninstall

```sh
./uninstall.sh
```

Then quit and reopen Qobuz so it runs without the debug port.

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
