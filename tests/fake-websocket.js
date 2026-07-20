class FakeWebSocket {
  static OPEN = 1;

  constructor() {
    this.readyState = FakeWebSocket.OPEN;
    this.listeners = new Map();
    setTimeout(() => this.emit('open', {}), 5);
  }

  addEventListener(name, callback) {
    if (!this.listeners.has(name)) this.listeners.set(name, []);
    this.listeners.get(name).push(callback);
  }

  emit(name, event) {
    for (const callback of this.listeners.get(name) || []) callback(event);
  }

  message(payload) {
    this.emit('message', {data: JSON.stringify(payload)});
  }

  send(raw) {
    const command = JSON.parse(raw);
    setTimeout(() => {
      const injectedSource = command.params && (command.params.expression || command.params.source || command.params.scriptSource);
      if (process.env.FAKE_CDP_REQUIRE_ES5 === '1' && injectedSource && /(=>|\bconst\b|\blet\b|catch\s*\{)/.test(injectedSource)) {
        this.message({id: command.id, error: {message: 'Injected source is not ES5 compatible'}});
        return;
      }
      if (command.method === 'Log.enable' && process.env.FAKE_CDP_IGNORE_LOG === '1') return;
      if (command.method === 'Network.enable' && process.env.FAKE_CDP_DISABLE_NETWORK === '1') {
        this.message({id: command.id, error: {message: 'Network domain unavailable'}});
        return;
      }
      this.message({id: command.id, result: {}});
      if (command.method === 'Runtime.evaluate' && process.env.FAKE_CDP_EMIT_HOOK === '1'
          && injectedSource && injectedSource.includes('__DEVICE_LOG_CAPTURE_NETWORK_V1__')) {
        const now = Date.now();
        this.message({method: 'Runtime.consoleAPICalled', params: {
          timestamp: now / 1000,
          type: 'log',
          args: [{value: `__DEVICE_LOG_CAPTURE_NETWORK_V1__${JSON.stringify({
            kind: 'fetch', method: 'POST', url: 'https://example.test/hook', status: 204,
            statusText: 'No Content', startedAt: now - 25, endedAt: now,
          })}`}],
        }});
      }
      if (command.method === 'Console.enable') {
        const timestamp = Date.now() / 1000;
        this.message({method: 'Console.messageAdded', params: {message: {
          timestamp, level: 'log', source: 'console-api',
          text: 'XHR Req: https://example.test/native?id=1',
        }}});
        this.message({method: 'Console.messageAdded', params: {message: {
          timestamp: timestamp + 0.001, level: 'log', source: 'console-api',
          text: 'XHR Req: https://example.test/fallback?id=2',
        }}});
        this.message({method: 'Console.messageAdded', params: {message: {
          timestamp: timestamp + 0.002, level: 'error', source: 'network',
          text: 'Failed to load resource: the server responded with a status of 404 (Not Found)',
          url: 'https://example.test/missing',
        }}});
      }
      if (command.method === 'Network.enable') {
        setTimeout(() => {
          const timestamp = Date.now() / 1000;
          const url = 'https://example.test/native?id=1';
          this.message({method: 'Network.requestWillBeSent', params: {
            requestId: 'native-1', timestamp, wallTime: timestamp,
            type: 'XHR', request: {method: 'GET', url, headers: {}},
          }});
          this.message({method: 'Network.responseReceived', params: {
            requestId: 'native-1', timestamp: timestamp + 0.01, type: 'XHR',
            response: {status: 200, statusText: 'OK', mimeType: 'application/json', headers: {}},
          }});
          this.message({method: 'Network.loadingFinished', params: {
            requestId: 'native-1', timestamp: timestamp + 0.02, encodedDataLength: 12,
          }});
        }, 80);
      }
    }, 2);
  }

  close() {
    this.readyState = 3;
  }
}

globalThis.WebSocket = FakeWebSocket;
