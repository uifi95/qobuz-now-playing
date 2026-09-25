// Evaluates a JavaScript expression in the running Qobuz page and prints the result.
// Requires Qobuz to be running with the debug port (the watcher does this).
// Usage: bun tools/cdp.mjs '<expression>'
const port = process.env.QOBUZ_NP_PORT || 9333;
const expr = process.argv[2];
if (!expr) {
  console.error("usage: bun tools/cdp.mjs '<expression>'");
  process.exit(1);
}
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const page = list.find((t) => t.type === 'page');
const ws = new WebSocket(page.webSocketDebuggerUrl);
ws.onopen = () =>
  ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression: expr, awaitPromise: true, returnByValue: true } }));
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.id !== 1) return;
  console.log(JSON.stringify(m.result.result?.value ?? m.result, null, 1));
  ws.close();
};
