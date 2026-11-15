// A tiny dev server for the PortBar demo. Usage: node server.js <port> <title> [--stubborn]
//
// With --stubborn it ignores SIGTERM/SIGINT/SIGHUP, like a hung dev server, so the only way
// to stop it is Force Quit (SIGKILL).
const http = require("node:http");

const port = Number(process.argv[2]);
const title = process.argv[3] || "demo";
const stubborn = process.argv.includes("--stubborn");

if (stubborn) {
  for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) {
    process.on(signal, () => console.log(`${title}: ignoring ${signal}`));
  }
}

const page = `<!doctype html><meta charset="utf-8"><title>${title}</title>
<style>
  body { font: 16px -apple-system, system-ui, sans-serif; display: grid; place-items: center;
         height: 100vh; margin: 0; background: #0f172a; color: #e2e8f0; }
  main { text-align: center; }
  h1 { margin: 0 0 .25em; font-size: 2.2rem; }
  p { margin: 0; color: #94a3b8; }
  code { color: #7dd3fc; }
</style>
<main><h1>${title}</h1><p>Running on <code>localhost:${port}</code></p></main>`;

http
  .createServer((_, res) => {
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    res.end(page);
  })
  .listen(port, "127.0.0.1", () => console.log(`${title} listening on ${port}`));
