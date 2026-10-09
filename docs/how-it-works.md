# How it works

## Why this is needed

The Qobuz Mac app is built on Electron, but plays audio through its own native engine (JUCE) rather than through Chromium. macOS learns what's playing from Chromium's media session, which only exists when a page plays an `<audio>`/`<video>` element. Qobuz never plays one, so macOS never hears about the track.

Qobuz registers the media keys as global shortcuts and does nothing else. On macOS, Electron implements those shortcuts through the same remote command center Now Playing uses, and turns off Chromium's own handling while they're registered, so a page's media session never receives remote commands such as seeking.

## The pieces

1. **`src/watcher.mjs`** runs in the background, either as a per-user LaunchAgent or inside the Mac app (`app/main.swift`), which starts it and shows its status. It's compiled with `bridge.js` and the native addon into a single `qobuz-now-playing` program, so it needs no bun or Node.js to run.
   - It never restarts Qobuz. When Qobuz is running, it sends the main process `SIGUSR1`, which makes Node open its inspector on `127.0.0.1` (port 9229 by default). It does this once per Qobuz launch, and again each time the watcher starts, so an update replaces the running bridge.
   - Through the inspector it installs a small host in the main process. The host loads the native addon, injects the bridge into the Qobuz window (and again after every reload), and passes messages between the two.
   - Once the bridge is in, the host unregisters Qobuz's media-key shortcuts, so Electron doesn't take the Now Playing commands.
   - The watcher then closes the inspector, and logs a warning if Qobuz still has Accessibility access.
2. **`src/bridge.js`** runs inside the Qobuz page. It reads the player, the play queue (and the autoplay tracks after it), favorites, the audio output and the stream quality from the app's Redux store, and reports changes to the host. It asks Qobuz to load queued tracks it hasn't fetched yet, the way Qobuz's own queue panel does.
3. **`src/native/nowplaying.m`** is a Node-API addon loaded into the Qobuz main process. It publishes Now Playing for Qobuz through macOS's MediaPlayer framework and receives the remote commands:
   - Play, pause, next, previous, shuffle, repeat and favorite are sent to the page as the same messages Qobuz's own Controls menu sends.
   - Seeking, ±15 s skips and holding a media key move the position through the same action as Qobuz's progress bar. Playing a track from Up Next uses Qobuz's own "play this track in the queue" action; autoplay tracks are listed but can only be reached by playing on.
   - Qobuz plays to the device chosen in Qobuz and ignores the Mac's default output, so switching the sound output in the menu bar, System Settings or an app like Vorssaint wouldn't move it. The addon watches the default output, and when it changes, the host switches Qobuz to the device with the same name, as Qobuz's own Devices menu does. It leaves Qobuz alone while it plays to a Chromecast or Qobuz Connect device.

### What it publishes

| | |
|---|---|
| Track | Title (with version), artist, album, album artist, composer, genre, track and disc numbers, duration, explicit flag, ISRC, artwork |
| Playback | Position, playing or paused, shuffle, repeat, favorite |
| Up Next | Up to 10 tracks back and 50 ahead, then the autoplay tracks, with covers for the next few |
| Audio | The output Qobuz plays to ("Playing on …") and the stream's codec, sample rate and bit depth; Qobuz follows changes to the Mac's sound output |
| Commands | Play, pause, play/pause, stop, next, previous, seek, skip ±15 s, fast-forward and rewind, shuffle, repeat, favorite (also "add to library"), play an Up Next track |

### Why not Chromium's media session

Earlier versions published through the page's `navigator.mediaSession`, keeping a silent `<audio>` element playing so Chromium would pass it to macOS. Chromium only forwards title, artist, album, artwork, position and seven commands (play, pause, stop, play/pause, next, previous, seek), and drops everything else, so the native addon replaces it.

The queue uses a private part of MediaPlayer (a playback-queue data source), so it may need fixing after a macOS update. While one is set, macOS takes the current track from the queue too, so everything goes through it. The rest uses public MediaPlayer API.

## Media keys and Accessibility access

Qobuz asks for Accessibility access so its media-key shortcuts work. This tool doesn't need it, and leaving it on breaks the media keys for every other app.

Electron (Chromium) watches the keyboard's play/pause, next and previous keys with an event tap, which macOS lets intercept keys only when the app has Accessibility access. With access, the keys reach Qobuz before macOS can send them to the Now Playing app, so they control Qobuz even while another player is playing. Unregistering Qobuz's shortcuts doesn't remove the tap, and nothing outside Qobuz can while the access is granted.

Without the access there's no tap: macOS sends the keys to the Now Playing app, and Qobuz receives them through its media session when it's that app. Control Center and the lock screen always go through Now Playing, so they work either way. If nothing has played since you logged in, play/pause opens Apple Music; that's standard macOS behavior.

## Security

Qobuz keeps no debug port open. Each time the watcher installs or updates the bridge, Qobuz's main process listens on a Node inspector port on `127.0.0.1` for a few seconds (at most about 20 s while the page loads), then the watcher closes it. The inspector rejects requests whose `Host` header isn't an IP address or `localhost`, so a website can't reach it. A local process running as your user could run code in Qobuz while the port is open, but it could already do that by sending Qobuz `SIGUSR1` itself, and can read Qobuz's data in `~/Library/Application Support/Qobuz`.

The native addon is native code running inside Qobuz. The watcher writes it to `~/Library/Caches/qobuz-now-playing/`, named after its content, and Qobuz loads it from there (Qobuz allows loading libraries not signed by Qobuz, which is also how it loads its own audio engine). Anything that could replace that file could already run code in Qobuz the ways above. The addon only talks to MediaPlayer and the host; it makes no network requests (the host fetches artwork from Qobuz's image server).

## Approaches that don't work

- **Restarting Qobuz with `--remote-debugging-port` and `--inspect`** (what earlier versions did): the window visibly closes and reopens, and a Qobuz already running (for example, opened at login) was left without the bridge.
- **`NODE_OPTIONS=--require …`**: Electron refuses it on macOS with `Node.js environment variables are disabled because this process is invoked by other apps.`
- **Patching `main-darwin.js` inside the bundle:** breaks the code signature, and the updater overwrites it anyway.
- **Calling the app's IPC from the page:** the page has no `require` or `ipcRenderer` access. The host sends Qobuz's menu messages from the main process instead.
- **Publishing everything through Chromium's media session:** see [Why not Chromium's media session](#why-not-chromiums-media-session).
