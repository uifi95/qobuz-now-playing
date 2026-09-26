# Troubleshooting

```sh
# Background service running?
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
| `bridge: waiting for the Qobuz page` | Qobuz hadn't finished loading. The hook keeps trying inside Qobuz; check the page with `tools/cdp.mjs`. |
| `inject error`, or `bridge: installed` never appears | A Qobuz update probably changed its internals. See [After a Qobuz update](development.md#after-a-qobuz-update). |
| Buttons work but the progress bar can't seek | Qobuz's media-key shortcuts weren't released. Quit and reopen Qobuz, and check that `bridge: installed` appears in the log. |
| Track shows but the buttons do nothing | The player button class names changed. Update the `.player__action-*` selectors in `src/bridge.js`. |
| The keyboard's media keys control Qobuz while another app plays | Qobuz has Accessibility access (the log says so on the `bridge:` line). Remove it in the Mac app's setup window, or with [step 1 of the service install](../README.md#background-service). [Why](how-it-works.md#media-keys-and-accessibility-access). |
| Play/pause opens Apple Music | No app is in Now Playing. Play a track in Qobuz once so macOS registers it. If that doesn't help, check that the bridge is in. |
| Another app appears while Qobuz is paused | Normal. macOS shows the app that played most recently. |
| A local (non-streaming) track lacks artwork or metadata | Known limitation: it depends on what Qobuz stores for the track. |
