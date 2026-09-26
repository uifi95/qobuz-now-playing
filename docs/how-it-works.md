# How it works

## Why this is needed

The Qobuz Mac app is built on Electron, but plays audio through its own native engine (JUCE) rather than through Chromium. macOS learns what's playing from Chromium's media session, which only exists when a page plays an `<audio>`/`<video>` element. Qobuz never plays one, so macOS never hears about the track.

Qobuz registers the media keys as global shortcuts and does nothing else. On macOS, Electron implements those shortcuts through the same remote command center Now Playing uses, and turns off Chromium's own handling while they're registered, so a page's media session never receives remote commands such as seeking.

## The pieces

1. **`src/watcher.mjs`** runs in the background, either as a per-user LaunchAgent or inside the Mac app (`app/main.swift`), which starts it and shows its status. It's compiled with `bridge.js` into a single `qobuz-now-playing` program, so it needs no bun or Node.js to run.
   - It never restarts Qobuz. When Qobuz is running, it sends the main process `SIGUSR1`, which makes Node open its inspector on `127.0.0.1` (port 9229 by default). It does this once per Qobuz launch, and again each time the watcher starts, so an update replaces the running bridge.
   - Through the inspector it installs a small hook in the main process, which injects the bridge into the Qobuz window, and again after every reload.
   - Once the bridge is in, the hook unregisters Qobuz's media-key shortcuts, so Now Playing commands reach the bridge instead.
   - The watcher then closes the inspector, and logs a warning if Qobuz still has Accessibility access.
2. **`src/bridge.js`** runs inside the Qobuz page.
   - It reads the player state (current track, play state, position, track and album metadata) from the app's Redux store and copies it into `navigator.mediaSession`.
   - While Qobuz plays, it loops a silent 10-second clip so Chromium publishes the session to macOS.
   - Play, pause, next and previous click Qobuz's own player buttons. Seeking calls the same action as Qobuz's progress bar.

## Media keys and Accessibility access

Qobuz asks for Accessibility access so its media-key shortcuts work. This tool doesn't need it, and leaving it on breaks the media keys for every other app.

Electron (Chromium) watches the keyboard's play/pause, next and previous keys with an event tap, which macOS lets intercept keys only when the app has Accessibility access. With access, the keys reach Qobuz before macOS can send them to the Now Playing app, so they control Qobuz even while another player is playing. Unregistering Qobuz's shortcuts doesn't remove the tap, and nothing outside Qobuz can while the access is granted.

Without the access there's no tap: macOS sends the keys to the Now Playing app, and Qobuz receives them through its media session when it's that app. Control Center and the lock screen always go through Now Playing, so they work either way. If nothing has played since you logged in, play/pause opens Apple Music; that's standard macOS behavior.

## Security

Qobuz keeps no debug port open. Each time the watcher installs or updates the bridge, Qobuz's main process listens on a Node inspector port on `127.0.0.1` for a few seconds (at most about 20 s while the page loads), then the watcher closes it. The inspector rejects requests whose `Host` header isn't an IP address or `localhost`, so a website can't reach it. A local process running as your user could run code in Qobuz while the port is open, but it could already do that by sending Qobuz `SIGUSR1` itself, and can read Qobuz's data in `~/Library/Application Support/Qobuz`.

## Approaches that don't work

- **Restarting Qobuz with `--remote-debugging-port` and `--inspect`** (what earlier versions did): the window visibly closes and reopens, and a Qobuz already running (for example, opened at login) was left without the bridge.
- **`NODE_OPTIONS=--require …`**: Electron refuses it on macOS with `Node.js environment variables are disabled because this process is invoked by other apps.`
- **Patching `main-darwin.js` inside the bundle:** breaks the code signature, and the updater overwrites it anyway.
- **Calling the app's IPC from the page:** the page has no `require` or `ipcRenderer` access.
