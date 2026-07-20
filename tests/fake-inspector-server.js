import fs from 'node:fs';
import http from 'node:http';

const readyFile = process.argv[2];
if (!readyFile) throw new Error('Percorso ready-file mancante.');

const server = http.createServer((request, response) => {
  if (request.url === '/json/list') {
    response.writeHead(404).end('Not found');
    return;
  }
  if (request.url === '/json') {
    response.writeHead(200, {'content-type': 'application/json'});
    response.end(JSON.stringify([{
      id: 'fallback-json',
      title: 'Target /json',
      url: 'https://example.test/app',
      webSocketDebuggerUrl: 'ws://0.0.0.0/devtools/page/fallback-json',
    }]));
    return;
  }
  response.writeHead(404).end('Not found');
});

server.listen(0, '127.0.0.1', () => {
  fs.writeFileSync(readyFile, String(server.address().port), 'utf8');
});

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
