# Development

## Building from source

Needs [bun](https://bun.sh) (`brew install bun`).

```sh
git clone https://github.com/uifi95/qobuz-now-playing.git
cd qobuz-now-playing
./install.sh
```

`install.sh` runs `build.sh`, which compiles `src/watcher.mjs`, with `src/bridge.js` embedded, into `dist/qobuz-now-playing`. It then copies the program to `~/.qobuz-nowplaying/` and registers `~/Library/LaunchAgents/com.user.qobuz-nowplaying.plist`. The Homebrew cask runs the same script. Re-run `./install.sh` after changing either source file.

To build the Mac app instead, run `./build.sh app`. It also needs Xcode or its Command Line Tools (`xcode-select --install`), and writes `dist/Qobuz Now Playing.app`. A local build isn't quarantined, so macOS doesn't block it.

## After a Qobuz update

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

Push a tag such as `v1.2.0`. The `release` workflow runs `./build.sh <version>` to build `qobuz-now-playing-<version>-macos-{arm64,x64}.tar.gz` and the Mac app's `Qobuz-Now-Playing-<version>-macos-{arm64,x64}.zip`, publishes them as a GitHub release, and updates `Casks/qobuz-now-playing.rb` in [uifi95/homebrew-tap](https://github.com/uifi95/homebrew-tap) (see the workflow for the token it needs). `packaging/cask.sh` generates the cask.
