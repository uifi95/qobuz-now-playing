// Keeps the Qobuz -> macOS Now Playing bridge alive.
// - If Qobuz was just launched normally (no debug port), relaunch it with a
//   localhost-only debug port. Only done in the first START_WINDOW_S seconds
//   after launch so an in-progress listening session is never interrupted.
// - Whenever the Qobuz page lacks the bridge (first load, reload), inject it.
// Runs on bun or node >= 22 (needs global fetch and WebSocket).
import { execFile } from 'node:child_process';
import { readFileSync, appendFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const run = promisify(execFile);
const DIR = dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.QOBUZ_NP_PORT) || 9333;
const POLL_MS = 3000;
const START_WINDOW_S = 30;

const log = (msg) => {
  try {
    appendFileSync(join(DIR, 'watcher.log'), `${new Date().toISOString()} ${msg}\n`);
  } catch {}
};

const qobuzUptime = async () => {
  try {
    const { stdout } = await run('/bin/ps', ['-axo', 'pid=,etime=,comm=']);
    const line = stdout
      .split('\n')
      .find((l) => l.trim().endsWith('/Qobuz.app/Contents/MacOS/Qobuz'));
    if (!line) return null;
    // etime: [[dd-]hh:]mm:ss
    const etime = line.trim().split(/\s+/)[1];
    const [days, rest] = etime.includes('-') ? etime.split('-') : ['0', etime];
    const parts = rest.split(':').map(Number);
    while (parts.length < 3) parts.unshift(0);
    return Number(days) * 86400 + parts[0] * 3600 + parts[1] * 60 + parts[2];
  } catch {
    return null;
  }
};

const pageTarget = async () => {
  try {
    const res = await fetch(`http://127.0.0.1:${PORT}/json/list`, { signal: AbortSignal.timeout(1000) });
    const list = await res.json();
    return list.find((t) => t.type === 'page' && t.url.endsWith('/app.html')) || null;
  } catch {
    return null;
  }
};

const evaluate = (wsUrl, expression) =>
  new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    const timer = setTimeout(() => {
      ws.close();
      reject(new Error('timeout'));
    }, 5000);
    ws.onopen = () =>
      ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression, returnByValue: true } }));
    ws.onmessage = (e) => {
      const msg = JSON.parse(e.data);
      if (msg.id !== 1) return;
      clearTimeout(timer);
      ws.close();
      resolve(msg.result && msg.result.result ? msg.result.result.value : undefined);
    };
    ws.onerror = () => {
      clearTimeout(timer);
      reject(new Error('ws error'));
    };
  });

const relaunch = async () => {
  log('relaunching Qobuz with debug port');
  await run('/usr/bin/osascript', ['-e', 'quit app "Qobuz"']).catch(() => {});
  for (let i = 0; i < 40 && (await qobuzUptime()) !== null; i++) await new Promise((r) => setTimeout(r, 250));
  await run('/usr/bin/open', ['-a', 'Qobuz', '--args', `--remote-debugging-port=${PORT}`, '--remote-debugging-address=127.0.0.1']);
};

let relaunchedAt = 0;

const tick = async () => {
  const uptime = await qobuzUptime();
  if (uptime === null) return;

  const target = await pageTarget();
  if (!target) {
    // Qobuz runs without the port. Relaunch only right after startup, and not in a loop.
    if (uptime <= START_WINDOW_S && Date.now() - relaunchedAt > 60000) {
      relaunchedAt = Date.now();
      await relaunch();
    }
    return;
  }

  try {
    const installed = await evaluate(target.webSocketDebuggerUrl, '!!window.__qobuzNowPlaying');
    if (installed) return;
    const result = await evaluate(target.webSocketDebuggerUrl, readFileSync(join(DIR, 'bridge.js'), 'utf8'));
    if (result !== 'store not ready') log(`bridge: ${result}`);
  } catch (err) {
    log(`inject error: ${err.message}`);
  }
};

log('watcher started');
const loop = async () => {
  await tick().catch((err) => log(`tick error: ${err.message}`));
  setTimeout(loop, POLL_MS);
};
loop();
