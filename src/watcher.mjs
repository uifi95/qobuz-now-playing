// Keeps the Qobuz -> macOS Now Playing bridge alive, without restarting Qobuz.
// - For each Qobuz launch, and once when the watcher starts (so an update
//   replaces the running bridge), send SIGUSR1 to the Qobuz main process.
//   Node opens its inspector on 127.0.0.1 in response.
// - Through the inspector, install a small host in the main process that
//   loads the native addon (src/native/nowplaying.m), which publishes Now
//   Playing for Qobuz, and injects the bridge into the Qobuz page, again after
//   every reload, which reports the player to it. Then it releases Qobuz's
//   media-key shortcuts: Electron's media-key globalShortcuts would take the
//   same macOS Now Playing commands.
// - Close the inspector again, so no debug port stays open.
// Warns if Qobuz has Accessibility access, which lets Chromium grab the
// keyboard media keys from whatever else is playing.
// Runs on bun; build.sh compiles it, with bridge.js and the addon embedded, into a single
// executable, which the LaunchAgent (install.sh) or the Mac app (app/) runs.
// Logs go to stdout; whoever runs it decides where they're written.
import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, readdirSync, renameSync, rmSync, existsSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import BRIDGE from './bridge.js' with { type: 'text' };
// build.sh compiles src/native/nowplaying.m to this file first.
import NATIVE from '../dist/nowplaying.node' with { type: 'file' };

// build.sh sets the release version; a plain `bun src/watcher.mjs` reports "dev".
const VERSION = process.env.QOBUZ_NOW_PLAYING_VERSION || 'dev';
if (process.argv.includes('--version')) {
  console.log(VERSION);
  process.exit(0);
}

const run = promisify(execFile);
const POLL_MS = 3000;
// Node installs its SIGUSR1 handler early in startup; before that the signal
// would terminate Qobuz, so leave a just-started process alone for a moment.
const MIN_UPTIME_S = 3;
const MAX_ATTEMPTS = 5;

const log = (msg) => console.log(`${new Date().toISOString()} ${msg}`);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// The Qobuz main process: pid and seconds since launch.
const qobuzProcess = async () => {
  try {
    const { stdout } = await run('/bin/ps', ['-axo', 'pid=,etime=,comm=']);
    const line = stdout
      .split('\n')
      .find((l) => l.trim().endsWith('/Qobuz.app/Contents/MacOS/Qobuz'));
    if (!line) return null;
    // etime: [[dd-]hh:]mm:ss
    const [pid, etime] = line.trim().split(/\s+/);
    const [days, rest] = etime.includes('-') ? etime.split('-') : ['0', etime];
    const parts = rest.split(':').map(Number);
    while (parts.length < 3) parts.unshift(0);
    return { pid: Number(pid), uptime: Number(days) * 86400 + parts[0] * 3600 + parts[1] * 60 + parts[2] };
  } catch {
    return null;
  }
};

// The main process's inspector target. It listens on process.debugPort
// (9229 unless Qobuz was started with --inspect), so look up the port by pid.
const inspectorTarget = async (pid) => {
  let ports = [];
  try {
    const { stdout } = await run('/usr/sbin/lsof', ['-nP', '-a', '-p', String(pid), '-iTCP', '-sTCP:LISTEN', '-Fn']);
    ports = [...stdout.matchAll(/^n127\.0\.0\.1:(\d+)$/gm)].map((m) => m[1]);
  } catch {}
  for (const port of ports) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/json/list`, { signal: AbortSignal.timeout(1000) });
      const node = (await res.json()).find((t) => t.type === 'node');
      if (node) return node;
    } catch {}
  }
  return null;
};

const evaluate = (wsUrl, expression, timeoutMs) =>
  new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    const timer = setTimeout(() => {
      ws.close();
      reject(new Error('timeout'));
    }, timeoutMs);
    ws.onopen = () =>
      ws.send(
        JSON.stringify({
          id: 1,
          method: 'Runtime.evaluate',
          params: { expression, awaitPromise: true, returnByValue: true },
        }),
      );
    ws.onmessage = (e) => {
      const msg = JSON.parse(e.data);
      if (msg.id !== 1) return;
      clearTimeout(timer);
      ws.close();
      const { result, exceptionDetails } = msg.result || {};
      if (exceptionDetails) reject(new Error(exceptionDetails.exception?.description || exceptionDetails.text));
      else resolve(result ? result.value : undefined);
    };
    ws.onerror = () => {
      clearTimeout(timer);
      reject(new Error('ws error'));
    };
  });

// Evaluated in Qobuz's main process. Replaces an older host, loads the native
// addon (once per build; a dylib can't be unloaded), then injects the bridge
// into the app page now and after every load, retrying until the page's store
// exists. The bridge reports the player through console messages, which the
// host forwards to the addon; the addon publishes them as Now Playing and
// sends remote commands back. Those go to the page through Qobuz's own menu
// IPC (the same messages its Controls menu sends) or, for seeking and the
// queue, to the bridge. Once the bridge runs, unregistering the media keys
// stops Electron from taking the same remote commands; a broken bridge leaves
// Qobuz's own media keys alone. Resolves with the first injection result, or
// after 20 s, then closes the inspector (close() waits for the watcher to
// disconnect).
// With Accessibility access, Chromium also keeps an event tap that grabs the
// hardware media keys before macOS routes them to the Now Playing app, so they
// always control Qobuz. Nothing here can remove that tap; the user has to take
// Qobuz out of the Accessibility list, so report it.
const hostScript = (bridge, nativePath) => `(async () => {
  const { app, webContents, globalShortcut, systemPreferences, net } = process.mainModule.require('electron');
  const BRIDGE = ${JSON.stringify(bridge)};
  const NATIVE = ${JSON.stringify(nativePath)};
  const MARKER = '\\u2063qobuz-now-playing:';

  let native = global.__qobuzNowPlayingNative;
  if (!native || native.path !== NATIVE) {
    const mod = { exports: {} };
    try {
      process.dlopen(mod, NATIVE);
    } catch (e) {
      // Leave Qobuz as it is; the old host, if any, keeps running.
      setTimeout(() => process.mainModule.require('inspector').close(), 1000);
      return 'error: native addon: ' + e.message;
    }
    native = global.__qobuzNowPlayingNative = { path: NATIVE, api: mod.exports };
  }
  const np = native.api;
  if (global.__qobuzNowPlayingHost) global.__qobuzNowPlayingHost.dispose();

  let disposed = false;
  let page = null;
  let state = null;
  let queue = null;

  // Artwork, fetched here because MediaPlayer wants the image itself.
  const art = new Map();
  const fetchArt = async (url) => {
    if (!url) return null;
    if (art.has(url)) return art.get(url);
    let data = null;
    try {
      const res = await net.fetch(url);
      if (res.ok) data = Buffer.from(await res.arrayBuffer());
    } catch (e) {}
    art.set(url, data);
    if (art.size > 100) art.delete(art.keys().next().value);
    return data;
  };

  const REPEAT = { noRepeat: 0, repeatOne: 1, repeatAll: 2 }; // MPRepeatType
  const CODEC = { flac: 0x666c6163, mp3: 0x2e6d7033 }; // Core Audio format IDs
  let artworkUrl;
  const publish = (withArtwork) => {
    if (!state || !state.track) return np.update(null);
    const { artworkUrl: url, id, codec, ...track } = state.track;
    const pos = state.position;
    let elapsed = pos ? pos.value : 0;
    if (pos && state.playing && pos.timestamp) elapsed += Date.now() - pos.timestamp;
    const info = {
      ...track,
      codec: CODEC[codec],
      elapsed: Math.min(Math.max(elapsed / 1000, 0), track.duration || Infinity),
      playing: state.playing,
      shuffle: state.shuffle,
      repeat: REPEAT[state.repeat] || 0,
      favorite: state.favorite,
      canNext: state.canNext,
      canPlayItems: !!(queue && queue.items.some((item) => item.playable)),
      queueIndex: state.queueIndex,
      queueCount: state.queueCount,
    };
    if (url !== artworkUrl) {
      artworkUrl = url;
      info.artwork = art.get(url) || null;
      if (!art.has(url)) fetchArt(url).then((data) => { if (data && !disposed && url === artworkUrl) publish(data); });
    } else if (withArtwork) info.artwork = withArtwork;
    if (info.artwork) info.artworkId = url;
    np.update(info);
  };

  // Up Next with small covers for the next few tracks; republished once
  // they've loaded.
  const publishQueue = () => {
    const items = queue.items.map(({ artworkUrl: url, ...item }) =>
      art.get(url) ? { ...item, artwork: art.get(url), artworkId: url } : item);
    np.setQueue(items, queue.current);
  };
  const loadQueueArt = (q) => {
    const urls = [...new Set(q.items.slice(Math.max(q.current, 0), q.current + 16).map((item) => item.artworkUrl))]
      .filter((url) => url && !art.has(url));
    if (urls.length) Promise.all(urls.map(fetchArt)).then(() => { if (!disposed && queue === q) publishQueue(); });
  };

  const fromPage = (event, level, message) => {
    const text = typeof message === 'string' ? message : event && event.message;
    if (disposed || typeof text !== 'string' || !text.startsWith(MARKER)) return;
    let msg;
    try { msg = JSON.parse(text.slice(MARKER.length)); } catch (e) { return; }
    page = event.sender || page;
    if (msg.type === 'state') {
      state = msg;
      publish();
    } else if (msg.type === 'queue') {
      queue = msg;
      publishQueue();
      loadQueueArt(msg);
      publish();
    }
  };

  const toPage = (name, value) => {
    if (!page || page.isDestroyed()) return;
    const playing = !!(state && state.playing);
    switch (name) {
      case 'play': if (!playing) page.send('media-controls', 'togglePlayPause'); return;
      case 'pause': if (playing) page.send('media-controls', 'togglePlayPause'); return;
      case 'togglePlayPause': return page.send('media-controls', 'togglePlayPause');
      case 'nextTrack': return page.send('media-controls', 'next');
      case 'previousTrack': return page.send('media-controls', 'previous');
      case 'shuffle': if (!!value !== !!(state && state.shuffle)) page.send('shufflePlayqueue'); return;
      case 'toggleShuffle': return page.send('shufflePlayqueue');
      // Qobuz's loop modes: 0 off, 1 all, 2 one.
      case 'repeat': return page.send('changeLoopMode', [0, 2, 1][value] || 0);
      case 'cycleRepeat': return page.send('changeLoopMode', { noRepeat: 1, repeatAll: 2 }[state && state.repeat] || 0);
      case 'favorite': return page.send('toggleFavorite', !!value);
      // The macOS default output changed: move Qobuz to the same device, as
      // its Devices menu would, unless it's casting or already there.
      case 'systemOutput': {
        const outputs = state && state.outputs;
        const device = outputs && outputs.local && outputs.direct.find((o) => o.name === value || o.uid === value);
        if (device && device.uid !== outputs.current) page.send('changeDevice', { name: device.uid, type: device.driverType });
        return;
      }
      default:
        page.executeJavaScript('window.__qobuzNowPlaying && window.__qobuzNowPlaying.command('
          + JSON.stringify(name) + ', ' + JSON.stringify(value) + ')')
          // The bridge asks for Next to finish playing a queued track.
          .then((result) => { if (result === 'next' && !page.isDestroyed()) page.send('media-controls', 'next'); })
          .catch(() => {});
    }
  };
  np.start(toPage);

  let report;
  const firstResult = new Promise((resolve) => (report = resolve));
  const loads = new WeakMap();
  const inject = async (wc) => {
    if (!wc.getURL().endsWith('/app.html')) return;
    const load = (loads.get(wc) || 0) + 1;
    loads.set(wc, load);
    while (!disposed && !wc.isDestroyed() && loads.get(wc) === load) {
      const result = await wc.executeJavaScript(BRIDGE).catch((e) => 'error: ' + e.message);
      if (result !== 'store not ready') {
        if (['installed', 'updated', 'already installed'].includes(result)) {
          page = wc;
          for (const key of ['MediaPlayPause', 'MediaNextTrack', 'MediaPreviousTrack']) globalShortcut.unregister(key);
        }
        report(result);
        return;
      }
      await new Promise((r) => setTimeout(r, 1000));
    }
  };

  const hooked = new Map();
  const hook = (wc) => {
    if (hooked.has(wc)) return;
    const onLoad = () => inject(wc);
    wc.on('did-finish-load', onLoad);
    wc.on('console-message', fromPage);
    hooked.set(wc, onLoad);
    if (!wc.isLoading()) inject(wc);
  };
  const onCreated = (_event, wc) => hook(wc);
  app.on('web-contents-created', onCreated);
  webContents.getAllWebContents().forEach(hook);
  global.__qobuzNowPlayingHost = {
    dispose() {
      disposed = true;
      np.stop();
      app.off('web-contents-created', onCreated);
      for (const [wc, onLoad] of hooked)
        if (!wc.isDestroyed()) {
          wc.off('did-finish-load', onLoad);
          wc.off('console-message', fromPage);
        }
    },
  };

  const result = await Promise.race([firstResult, new Promise((r) => setTimeout(() => r('waiting for the Qobuz page'), 20000))]);
  setTimeout(() => process.mainModule.require('inspector').close(), 1000);
  return systemPreferences.isTrustedAccessibilityClient(false)
    ? result + '. Qobuz has Accessibility access, so the keyboard media keys always control Qobuz. '
      + 'Remove Qobuz in System Settings > Privacy & Security > Accessibility, then restart Qobuz'
    : result;
})()`;

// Qobuz loads the addon from a real file, named by its content: a Qobuz that
// already loaded this build keeps using it, and a newer build gets a new name.
// Older copies are removed; one that's still loaded stays usable until Qobuz
// quits.
const NATIVE_DIR = join(homedir(), 'Library/Caches/qobuz-now-playing');
const nativeFile = () => {
  const data = readFileSync(NATIVE);
  const name = `nowplaying-${createHash('sha256').update(data).digest('hex').slice(0, 12)}.node`;
  const file = join(NATIVE_DIR, name);
  if (!existsSync(file)) {
    mkdirSync(NATIVE_DIR, { recursive: true });
    writeFileSync(`${file}.tmp`, data);
    renameSync(`${file}.tmp`, file);
  }
  for (const old of readdirSync(NATIVE_DIR)) if (old !== name) rmSync(join(NATIVE_DIR, old), { force: true });
  return file;
};

const BRIDGE_VERSION = Number((BRIDGE.match(/const VERSION = (\d+);/) || [])[1]);

// The Qobuz process the host was installed for, and the failed attempts for
// the current process.
let donePid = null;
let attempts = { pid: null, count: 0 };

const tick = async () => {
  const qobuz = await qobuzProcess();
  if (!qobuz || qobuz.uptime < MIN_UPTIME_S) return;

  if (donePid === qobuz.pid) return;

  if (attempts.pid !== qobuz.pid) attempts = { pid: qobuz.pid, count: 0 };
  if (attempts.count >= MAX_ATTEMPTS) return;
  attempts.count++;

  try {
    process.kill(qobuz.pid, 'SIGUSR1');
    let target = null;
    for (let i = 0; i < 12 && !target; i++) {
      await sleep(250);
      target = await inspectorTarget(qobuz.pid);
    }
    if (!target) throw new Error('Qobuz did not open its inspector');
    log(`bridge: ${await evaluate(target.webSocketDebuggerUrl, hostScript(BRIDGE, nativeFile()), 30000)}`);
    donePid = qobuz.pid;
  } catch (err) {
    log(`inject error: ${err.message}${attempts.count >= MAX_ATTEMPTS ? '; giving up until Qobuz restarts' : ''}`);
  }
};

// Started by the Mac app: exit if the app goes away without stopping us.
const PARENT = process.env.QOBUZ_NOW_PLAYING_APP ? process.ppid : null;

log(`watcher ${VERSION} started (bridge v${BRIDGE_VERSION})`);
const loop = async () => {
  if (PARENT && process.ppid !== PARENT) process.exit(0);
  await tick().catch((err) => log(`tick error: ${err.message}`));
  setTimeout(loop, POLL_MS);
};
loop();
