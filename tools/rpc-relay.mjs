// Tiny local JSON-RPC relay for Aevum testnet.
// Foundry's Rust TLS stack (rustls) aborts on this RPC because the server
// closes TLS connections without a close_notify. Node/OpenSSL tolerates it,
// so this proxy forwards requests over Node https and serves plain HTTP
// locally. Testnet only, localhost only, no keys involved.
import http from 'node:http';
import https from 'node:https';

const TARGET = 'https://rpc-test.qday.info';
const PORT = 8545;

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const data = Buffer.concat(chunks);
    let attempt = 0;
    const tryOnce = () => {
      attempt += 1;
      const treq = https.request(
        TARGET,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'Content-Length': data.length },
        },
        (tres) => {
          res.writeHead(tres.statusCode || 200, { 'Content-Type': 'application/json' });
          tres.pipe(res);
        },
      );
      treq.on('error', (e) => {
        if (attempt < 4) {
          setTimeout(tryOnce, 500 * attempt);
        } else {
          res.writeHead(502, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: String(e && e.message ? e.message : e) }));
        }
      });
      treq.end(data);
    };
    tryOnce();
  });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`aevum rpc relay listening on http://127.0.0.1:${PORT} -> ${TARGET}`);
});
