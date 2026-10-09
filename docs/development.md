# Development

## Building from source

Needs [bun](https://bun.sh) (`brew install bun`) and Xcode or its Command Line Tools (`xcode-select --install`) for the native addon.

```sh
git clone https://github.com/uifi95/qobuz-now-playing.git
cd qobuz-now-playing
./install.sh
```

`install.sh` runs `build.sh`, which compiles `src/native/nowplaying.m` into `dist/nowplaying.node` (one file for both architectures, since it has to match Qobuz), then `src/watcher.mjs`, with `src/bridge.js` and the addon embedded, into `dist/qobuz-now-playing`. Running `bun src/watcher.mjs` directly needs `dist/nowplaying.node`, so run `./build.sh` first. It then copies the program to `~/.qobuz-nowplaying/` and registers `~/Library/LaunchAgents/com.user.qobuz-nowplaying.plist`. The Homebrew cask runs the same script. Re-run `./install.sh` after changing either source file.

To build the Mac app instead, run `./build.sh app`. It writes `dist/Qobuz Now Playing.app`. A local build isn't quarantined, so macOS doesn't block it.

## After a Qobuz update

The bridge depends on these parts of Qobuz's internals:

| Where | What |
|---|---|
| `player.currentTrack.id`, `.duration` (ms) | Current track |
| `player.playingState` (`"play"` when playing) | Play state |
| `player.position` `{value (ms), timestamp}` | Elapsed time |
| `player.quality` `{formatId, samplingRate (kHz), bitDepth}` | Stream format (format 5 is MP3, the others FLAC) |
| `dictionnary.tracks.data[id]` | Title, version, interpreters, composer, ISRC, `mediaSupport`, `releaseId` |
| `dictionnary.releases.data[releaseId]` | Album title, artists, genre, track and disc counts, `image.small` / `image.large` |
| `playqueue` `items` / `shuffledItems`, `currentIndex`, `shuffled`, `repeatMode`, `autoplay.{mode,items}` | Up Next, shuffle, repeat |
| `userLibrary.chunks.favoriteTracks.mapById` | Favorite |
| `audioOutputs.current`, `.availables.direct`, `.dictionnary[uid]` (`displayName`, `driverType`, `controllerType` `"JUCE"` for local devices) | Audio output, and the devices Qobuz can follow the Mac's output to |
| A dispatched `{type: 'LOAD_TRACKS_EPIC', ids}` | Loads queued tracks Qobuz hasn't fetched |
| A dispatched `{type: 'playqueue/jumpTo', payload: {index}}`, then `media-controls` `next` | Plays a queued track when no `moveInQueue` is on screen |
| Component props `seek({position})` (ms) and `moveInQueue({index})` | Progress bar's seek action; playing a queued track |
| Renderer IPC `media-controls` (`togglePlayPause`, `next`, `previous`), `shufflePlayqueue`, `changeLoopMode` (0 off, 1 all, 2 one), `toggleFavorite` (bool), `changeDevice` (`{name: uid, type: driverType}`) | Sent by the host for remote commands and output changes, as Qobuz's Controls and Devices menus do |
| `globalShortcut` `MediaPlayPause`, `MediaNextTrack`, `MediaPreviousTrack` (main process) | Shortcuts released so Electron doesn't take Now Playing commands |

Use `tools/cdp.mjs` to explore the live page, fix `src/bridge.js`, bump its `VERSION`, then re-run `./install.sh`. `/Applications/Qobuz.app/Contents/Resources/app/node_modules/@qobuz/qobuz-dwp-ui/dist/bundle.js` is the page's code and `main-darwin.js` the main process's, if you need to look up an action or IPC message. The restarted watcher replaces the running bridge with the new version. Pull requests are welcome.

## Changing the native addon

A copy loaded into Qobuz stays there until Qobuz quits, and a mistake in it takes Qobuz down. Two rules keep it safe:

- Everything in a queue item's info dictionary is archived by MediaRemote with secure coding. Only strings, numbers, data and dates may go in; anything else (an `MPMediaItemArtwork`, say) makes the archiver throw on a background thread, which terminates Qobuz.
- `invalidatePlaybackQueue` calls the data source synchronously and throws if there's no current item, so the addon detaches the data source when there's nothing to show.

Test changes outside Qobuz first: build `src/native/nowplaying.m` with `-DQNP_NO_NAPI` into a small program that calls `qnpStart`, `qnpUpdate` and `qnpSetQueue` and runs the main run loop, then check what macOS reports with `tools/now-playing.js`.

## Releasing

Push a tag such as `v1.2.0`. The `release` workflow runs `./build.sh <version>` to build `qobuz-now-playing-<version>-macos-{arm64,x64}.tar.gz` and the Mac app's `Qobuz-Now-Playing-<version>-macos-{arm64,x64}.zip`, publishes them as a GitHub release, and updates `Casks/qobuz-now-playing.rb` in [uifi95/homebrew-tap](https://github.com/uifi95/homebrew-tap) (see the workflow for the token it needs). `packaging/cask.sh` generates the cask.
