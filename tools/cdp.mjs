// Evaluates a JavaScript expression in the running Qobuz page and prints the result.
// Opens the main process's Node inspector with SIGUSR1, runs the expression in
// the page through webContents.executeJavaScript, then closes the inspector.
// Usage: bun tools/cdp.mjs '<expression>'
import { execFileSync } from 'node:child_process';

const expr = process.argv[2];
if (!expr) {
  console.error("usage: bun tools/cdp.mjs '<expression>'");
  process.exit(1);
}
const pid = Number(execFileSync('/usr/bin/pgrep', ['-x', 'Qobuz'], { encoding: 'utf8' }).split('\n')[0]);
process.kill(pid, 'SIGUSR1');

let node;
for (let i = 0; i < 12 && !node; i++) {
  await new Promise((r) => setTimeout(r, 250));
  let lsof = '';
  try {
    lsof = execFileSync('/usr/sbin/lsof', ['-nP', '-a', '-p', String(pid), '-iTCP', '-sTCP:LISTEN', '-Fn'], { encoding: 'utf8' });
  } catch {}
  for (const [, port] of lsof.matchAll(/^n127\.0\.0\.1:(\d+)$/gm)) {
    const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json().catch(() => []);
    node = node || list.find((t) => t.type === 'node');
  }
}
if (!node) {
  console.error('Qobuz did not open its inspector');
  process.exit(1);
}

const expression = `(async () => {
  const wc = process.mainModule.require('electron').webContents.getAllWebContents()
    .find((w) => w.getURL().endsWith('/app.html'));
  try {
    return await wc.executeJavaScript(${JSON.stringify(expr)});
  } finally {
    setTimeout(() => process.mainModule.require('inspector').close(), 500);
  }
})()`;
const ws = new WebSocket(node.webSocketDebuggerUrl);
ws.onopen = () =>
  ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression, awaitPromise: true, returnByValue: true } }));
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.id !== 1) return;
  console.log(JSON.stringify(m.result.result?.value ?? m.result, null, 1));
  ws.close();
};
