// Keeps the Qobuz -> macOS Now Playing bridge alive, without restarting Qobuz.
// - For each Qobuz launch, and once when the watcher starts (so an update
//   replaces the running bridge), send SIGUSR1 to the Qobuz main process.
//   Node opens its inspector on 127.0.0.1 in response.
// - Through the inspector, install a small host in the main process that
//   injects the bridge into the Qobuz page, again after every reload, then
//   releases Qobuz's media-key shortcuts. Electron's media-key globalShortcuts
//   swallow every macOS Now Playing command, so without this Control Center
//   can't seek and the bridge's handlers never run.
// - Close the inspector again, so no debug port stays open.
// Warns if Qobuz has Accessibility access, which lets Chromium grab the
// keyboard media keys from whatever else is playing.
// Runs on bun; build.sh compiles it, with bridge.js embedded, into a single
// executable. Logs go to stdout; the LaunchAgent decides where they're written.
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import BRIDGE from './bridge.js' with { type: 'text' };

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

// Evaluated in Qobuz's main process. Replaces an older host, then injects the
// bridge into the app page now and after every load, retrying until the page's
// store exists. Once the bridge handles commands, unregistering the media keys
// hands Now Playing commands back to Chromium, which routes them to the bridge;
// a broken bridge leaves Qobuz's own media keys alone. Resolves with the first
// injection result, or after 20 s, then closes the inspector (close() waits
// for the watcher to disconnect).
// With Accessibility access, Chromium also keeps an event tap that grabs the
// hardware media keys before macOS routes them to the Now Playing app, so they
// always control Qobuz. Nothing here can remove that tap; the user has to take
// Qobuz out of the Accessibility list, so report it.
const hostScript = (bridge) => `(async () => {
  const { app, webContents, globalShortcut, systemPreferences } = process.mainModule.require('electron');
  const BRIDGE = ${JSON.stringify(bridge)};
  if (global.__qobuzNowPlayingHost) global.__qobuzNowPlayingHost.dispose();

  let disposed = false;
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
        if (['installed', 'updated', 'already installed'].includes(result))
          for (const key of ['MediaPlayPause', 'MediaNextTrack', 'MediaPreviousTrack']) globalShortcut.unregister(key);
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
    hooked.set(wc, onLoad);
    if (!wc.isLoading()) inject(wc);
  };
  const onCreated = (_event, wc) => hook(wc);
  app.on('web-contents-created', onCreated);
  webContents.getAllWebContents().forEach(hook);
  global.__qobuzNowPlayingHost = {
    dispose() {
      disposed = true;
      app.off('web-contents-created', onCreated);
      for (const [wc, onLoad] of hooked) if (!wc.isDestroyed()) wc.off('did-finish-load', onLoad);
    },
  };

  const result = await Promise.race([firstResult, new Promise((r) => setTimeout(() => r('waiting for the Qobuz page'), 20000))]);
  setTimeout(() => process.mainModule.require('inspector').close(), 1000);
  return systemPreferences.isTrustedAccessibilityClient(false)
    ? result + '. Qobuz has Accessibility access, so the keyboard media keys always control Qobuz. '
      + 'Remove Qobuz in System Settings > Privacy & Security > Accessibility, then restart Qobuz'
    : result;
})()`;

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
    log(`bridge: ${await evaluate(target.webSocketDebuggerUrl, hostScript(BRIDGE), 30000)}`);
    donePid = qobuz.pid;
  } catch (err) {
    log(`inject error: ${err.message}${attempts.count >= MAX_ATTEMPTS ? '; giving up until Qobuz restarts' : ''}`);
  }
};

log(`watcher ${VERSION} started (bridge v${BRIDGE_VERSION})`);
const loop = async () => {
  await tick().catch((err) => log(`tick error: ${err.message}`));
  setTimeout(loop, POLL_MS);
};
loop();
