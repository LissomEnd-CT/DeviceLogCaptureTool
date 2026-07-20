#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
let toolVersion = '0.0.0';
try { toolVersion = fs.readFileSync(path.join(__dirname, '..', 'VERSION'), 'utf8').trim() || toolVersion; }
catch { /* VERSION non è indispensabile per la cattura. */ }

function parseArgs(argv) {
  const options = {
    host: 'localhost',
    port: 64915,
    duration: 0,
    output: path.join(process.cwd(), 'device-logs'),
    reload: false,
    target: null,
    wsUrl: null,
    stopFile: null,
    name: 'device',
    commandTimeout: 4000,
    compatNetworkHook: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--reload') options.reload = true;
    else if (arg === '--host') options.host = argv[++i];
    else if (arg === '--port') options.port = Number(argv[++i]);
    else if (arg === '--duration') options.duration = Number(argv[++i]);
    else if (arg === '--output') options.output = path.resolve(argv[++i]);
    else if (arg === '--target') options.target = argv[++i];
    else if (arg === '--ws-url') options.wsUrl = argv[++i];
    else if (arg === '--stop-file') options.stopFile = path.resolve(argv[++i]);
    else if (arg === '--name') options.name = argv[++i];
    else if (arg === '--command-timeout') options.commandTimeout = Number(argv[++i]);
    else if (arg === '--compat-network-hook') options.compatNetworkHook = true;
    else if (arg === '--help' || arg === '-h') options.help = true;
    else throw new Error(`Opzione sconosciuta: ${arg}`);
  }
  if (!Number.isInteger(options.port) || options.port < 1 || options.port > 65535) {
    throw new Error('La porta deve essere un numero tra 1 e 65535.');
  }
  if (!Number.isFinite(options.duration) || options.duration < 0) {
    throw new Error('La durata deve essere 0 (fino a Ctrl+C) oppure un numero positivo di secondi.');
  }
  if (!Number.isInteger(options.commandTimeout) || options.commandTimeout < 500 || options.commandTimeout > 30000) {
    throw new Error('Il timeout CDP deve essere compreso tra 500 e 30000 millisecondi.');
  }
  return options;
}

function usage() {
  console.log(`Uso:
  node lib/cdp-capture.js [opzioni]

Opzioni:
  --port NUMERO       Porta locale restituita da ares-inspect (default: 64915)
  --host HOST         Host del tunnel (default: localhost)
  --duration SECONDI  0 = registra fino a Ctrl+C (default: 0)
  --output CARTELLA   Cartella di destinazione (default: ./device-logs)
  --target ID         ID pagina CDP; se omesso viene scoperto da /json/list o /json
  --ws-url URL        URL WebSocket CDP completo (salta la discovery HTTP)
  --stop-file FILE    Termina quando viene creato FILE (usato dal tool CMD)
  --name NOME         Prefisso sicuro per i file generati
  --command-timeout MS Timeout dei comandi CDP (default: 4000)
  --compat-network-hook Inietta un hook XHR/fetch di fallback per WebKit legacy
  --reload            Ricarica la pagina dopo aver attivato la registrazione
  -h, --help          Mostra questo aiuto

Nota: chiudere il vecchio DevTools prima di avviare la cattura; Chrome 38 accetta
un solo client debugger per pagina.`);
}

function getJson(host, port, route) {
  return new Promise((resolve, reject) => {
    const request = http.get({ host, port, path: route, timeout: 5000 }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => {
        if (response.statusCode !== 200) {
          reject(new Error(`${route} ha risposto HTTP ${response.statusCode}`));
          return;
        }
        try {
          resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
        } catch (error) {
          reject(new Error(`Risposta JSON non valida da ${route}: ${error.message}`));
        }
      });
    });
    request.on('timeout', () => request.destroy(new Error(`Timeout leggendo ${route}`)));
    request.on('error', reject);
  });
}

async function discoverTargets(host, port) {
  const errors = [];
  for (const route of ['/json/list', '/json']) {
    try {
      const response = await getJson(host, port, route);
      const targets = Array.isArray(response) ? response : [response];
      if (targets.length > 0) return targets;
      errors.push(`${route}: nessun target`);
    } catch (error) {
      errors.push(`${route}: ${error.message}`);
    }
  }
  throw new Error(`Nessun target DevTools trovato (${errors.join('; ')}).`);
}

function headerList(headers) {
  if (!headers) return [];
  return Object.entries(headers).map(([name, value]) => ({ name, value: String(value) }));
}

function queryList(url) {
  try {
    return [...new URL(url).searchParams.entries()].map(([name, value]) => ({ name, value }));
  } catch {
    return [];
  }
}

function isoFromTimestamp(timestamp, monotonicOffset) {
  let milliseconds;
  if (!Number.isFinite(timestamp)) milliseconds = Date.now();
  else if (timestamp > 1e12) milliseconds = timestamp;
  else if (timestamp > 1e9) milliseconds = timestamp * 1000;
  else if (Number.isFinite(monotonicOffset)) milliseconds = (timestamp + monotonicOffset) * 1000;
  else milliseconds = Date.now();
  return new Date(milliseconds).toISOString();
}

function remoteValue(value) {
  if (!value) return '';
  if (Object.prototype.hasOwnProperty.call(value, 'value')) {
    if (typeof value.value === 'string') return value.value;
    try { return JSON.stringify(value.value); } catch { return String(value.value); }
  }
  if (value.unserializableValue) return value.unserializableValue;
  return value.description || value.className || value.type || '';
}

function cdpTimings(response) {
  const timing = response && response.timing;
  if (!timing) {
    return { blocked: -1, dns: -1, connect: -1, send: -1, wait: -1, receive: -1, ssl: -1 };
  }
  const delta = (end, start) => (
    Number.isFinite(timing[end]) && Number.isFinite(timing[start]) && timing[end] >= 0 && timing[start] >= 0
      ? Math.max(0, timing[end] - timing[start])
      : -1
  );
  return {
    blocked: timing.dnsStart >= 0 ? Math.max(0, timing.dnsStart) : 0,
    dns: delta('dnsEnd', 'dnsStart'),
    connect: delta('connectEnd', 'connectStart'),
    send: delta('sendEnd', 'sendStart'),
    wait: delta('receiveHeadersEnd', 'sendEnd'),
    receive: -1,
    ssl: delta('sslEnd', 'sslStart'),
  };
}

function makeHarEntry(params, sequence, monotonicOffset) {
  const request = params.request || {};
  return {
    _requestId: params.requestId,
    _sequence: sequence,
    _resourceType: params.type || 'Other',
    _startTimestamp: params.timestamp,
    _endTimestamp: null,
    _failed: false,
    _failureText: null,
    startedDateTime: isoFromTimestamp(params.wallTime || params.timestamp, monotonicOffset),
    time: 0,
    request: {
      method: request.method || 'GET',
      url: request.url || '',
      httpVersion: 'HTTP/1.1',
      cookies: [],
      headers: headerList(request.headers),
      queryString: queryList(request.url || ''),
      headersSize: -1,
      bodySize: request.postData ? Buffer.byteLength(request.postData) : 0,
      ...(request.postData ? {
        postData: {
          mimeType: request.headers && (request.headers['Content-Type'] || request.headers['content-type']) || '',
          text: request.postData,
        },
      } : {}),
    },
    response: {
      status: 0,
      statusText: '',
      httpVersion: 'HTTP/1.1',
      cookies: [],
      headers: [],
      content: { size: 0, mimeType: '' },
      redirectURL: '',
      headersSize: -1,
      bodySize: -1,
    },
    cache: {},
    timings: { blocked: -1, dns: -1, connect: -1, send: -1, wait: -1, receive: -1, ssl: -1 },
    serverIPAddress: '',
    connection: '',
  };
}

function applyResponse(entry, response) {
  if (!response) return;
  entry.response = {
    status: response.status || 0,
    statusText: response.statusText || '',
    httpVersion: response.protocol || 'HTTP/1.1',
    cookies: [],
    headers: headerList(response.headers),
    content: {
      size: Number.isFinite(response.encodedDataLength) ? response.encodedDataLength : 0,
      mimeType: response.mimeType || '',
      ...(response.headers && (response.headers['Content-Encoding'] || response.headers['content-encoding'])
        ? { compression: 0 } : {}),
    },
    redirectURL: response.headers && (response.headers.Location || response.headers.location) || '',
    headersSize: typeof response.headersText === 'string' ? Buffer.byteLength(response.headersText) : -1,
    bodySize: Number.isFinite(response.encodedDataLength) ? response.encodedDataLength : -1,
  };
  entry.timings = cdpTimings(response);
  entry.serverIPAddress = response.remoteIPAddress || '';
  entry.connection = response.connectionId != null ? String(response.connectionId) : '';
  entry._fromDiskCache = Boolean(response.fromDiskCache);
}

function finishEntry(entry, timestamp) {
  if (!entry) return;
  entry._endTimestamp = timestamp;
  if (Number.isFinite(timestamp) && Number.isFinite(entry._startTimestamp)) {
    entry.time = Math.max(0, (timestamp - entry._startTimestamp) * 1000);
    if (entry.timings.receive < 0) entry.timings.receive = entry.time;
  }
}

const COMPAT_NETWORK_PREFIX = '__DEVICE_LOG_CAPTURE_NETWORK_V1__';

function compatibilityNetworkHookSource() {
  return `(function() {
    var root = typeof globalThis !== 'undefined' ? globalThis : window;
    if (root.__deviceLogCaptureNetworkHook) return;
    var prefix = '${COMPAT_NETWORK_PREFIX}';
    function absoluteUrl(value) {
      try {
        var anchor = document.createElement('a');
        anchor.href = String(value || '');
        return anchor.href;
      } catch (error) { return String(value || ''); }
    }
    function emit(payload) {
      try { console.log(prefix + JSON.stringify(payload)); } catch (error) { /* best effort */ }
    }
    var NativeXHR = root.XMLHttpRequest;
    var nativeFetch = root.fetch;
    var hookState = {NativeXHR: NativeXHR, nativeOpen: null, nativeSend: null, nativeFetch: nativeFetch};
    root.__deviceLogCaptureNetworkHook = hookState;
    if (NativeXHR && NativeXHR.prototype) {
      var nativeOpen = NativeXHR.prototype.open;
      var nativeSend = NativeXHR.prototype.send;
      hookState.nativeOpen = nativeOpen;
      hookState.nativeSend = nativeSend;
      NativeXHR.prototype.open = function(method, url) {
        this.__dlcMethod = String(method || 'GET').toUpperCase();
        this.__dlcUrl = absoluteUrl(url);
        return nativeOpen.apply(this, arguments);
      };
      NativeXHR.prototype.send = function() {
        var request = this;
        var startedAt = Date.now();
        var method = this.__dlcMethod || 'GET';
        var url = this.__dlcUrl || '';
        var emitted = false;
        function complete() {
          if (emitted) return;
          emitted = true;
          emit({kind: 'xhr', method: method, url: url, status: Number(request.status) || 0,
            statusText: String(request.statusText || ''), startedAt: startedAt, endedAt: Date.now()});
        }
        try { this.addEventListener('loadend', complete, false); }
        catch (error) { this.onreadystatechange = function() { if (request.readyState === 4) complete(); }; }
        return nativeSend.apply(this, arguments);
      };
    }
    if (typeof nativeFetch === 'function') {
      root.fetch = function(input, init) {
        var startedAt = Date.now();
        var method = String((init && init.method) || (input && input.method) || 'GET').toUpperCase();
        var url = absoluteUrl((input && input.url) || input);
        return nativeFetch.apply(this, arguments).then(function(response) {
          emit({kind: 'fetch', method: method, url: url, status: Number(response.status) || 0,
            statusText: String(response.statusText || ''), startedAt: startedAt, endedAt: Date.now()});
          return response;
        }, function(error) {
          emit({kind: 'fetch', method: method, url: url, status: 0,
            statusText: String(error && error.message || 'Fetch failed'), startedAt: startedAt, endedAt: Date.now()});
          throw error;
        });
      };
    }
  })();`;
}

function compatibilityNetworkHookCleanupSource() {
  return `(function() {
    var root = typeof globalThis !== 'undefined' ? globalThis : window;
    var state = root.__deviceLogCaptureNetworkHook;
    if (!state) return;
    try {
      if (state.NativeXHR && state.NativeXHR.prototype) {
        if (state.nativeOpen) state.NativeXHR.prototype.open = state.nativeOpen;
        if (state.nativeSend) state.NativeXHR.prototype.send = state.nativeSend;
      }
      if (state.nativeFetch) root.fetch = state.nativeFetch;
      try { delete root.__deviceLogCaptureNetworkHook; }
      catch (error) { root.__deviceLogCaptureNetworkHook = null; }
    } catch (error) { /* best effort */ }
  })();`;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) { usage(); return; }
  if (typeof WebSocket !== 'function') {
    throw new Error('Serve Node.js 22 o successivo (WebSocket integrato non disponibile).');
  }

  let target;
  if (options.wsUrl) {
    const idMatch = options.wsUrl.match(/\/devtools\/(?:page|browser)\/([^/?#]+)/i);
    target = { id: idMatch ? idMatch[1] : 'direct', title: options.name, url: '' };
  } else {
    const targets = await discoverTargets(options.host, options.port);
    target = options.target ? targets.find((item) => item.id === options.target) : targets[0];
    if (!target) throw new Error(`Target ${options.target} non trovato.`);
  }

  fs.mkdirSync(options.output, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const safeName = String(options.name || 'device').replace(/[^a-z0-9._-]+/gi, '-').replace(/^-+|-+$/g, '') || 'device';
  const baseName = `${safeName}-${stamp}`;
  const harPath = path.join(options.output, `${baseName}.har`);
  const logPath = path.join(options.output, `${baseName}.log`);

  let commandId = 0;
  let sequence = 0;
  let monotonicOffset = null;
  let stopping = false;
  let flushTimer;
  let durationTimer;
  let stopFileTimer;
  let compatibilityHookInstalled = false;
  let hookRegistration = null;
  const entries = [];
  const current = new Map();
  const logLines = [];
  const recentConsole = new Map();
  const syntheticNetworkKeys = new Set();
  const syntheticNetworkEntries = new Map();
  const nativeNetworkUrls = new Set();
  const pending = new Map();
  const startedAt = new Date().toISOString();
  const socketUrl = options.wsUrl || `ws://${options.host}:${options.port}/devtools/page/${target.id}`;
  const ws = new WebSocket(socketUrl);

  function send(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = ++commandId;
      const timer = setTimeout(() => {
        if (!pending.has(id)) return;
        pending.delete(id);
        reject(new Error(`${method}: nessuna risposta entro ${options.commandTimeout} ms`));
      }, options.commandTimeout);
      pending.set(id, { method, resolve, reject, timer });
      try {
        ws.send(JSON.stringify({ id, method, params }));
      } catch (error) {
        clearTimeout(timer);
        pending.delete(id);
        reject(new Error(`${method}: ${error.message}`));
      }
    });
  }

  function harDocument() {
    return {
      log: {
        version: '1.2',
        creator: { name: 'DeviceLogCaptureTool', version: toolVersion },
        pages: [{
          startedDateTime: startedAt,
          id: 'page_1',
          title: target.title || target.url || 'device',
          pageTimings: {},
        }],
        entries: entries.map((entry) => ({ ...entry, pageref: 'page_1' })),
      },
    };
  }

  function flush() {
    fs.writeFileSync(harPath, `${JSON.stringify(harDocument(), null, 2)}\n`, 'utf8');
    fs.writeFileSync(logPath, `${logLines.join('\n')}${logLines.length ? '\n' : ''}`, 'utf8');
  }

  function addConsole(message) {
    const time = isoFromTimestamp(message.timestamp, monotonicOffset);
    const level = String(message.level || 'log').toUpperCase();
    const source = message.source || 'console';
    const values = (message.parameters || []).map(remoteValue).filter(Boolean);
    let text = values.length ? values.join(' ') : (message.text || '');
    if (message.text && values.length && !text.includes(message.text)) text = `${message.text} ${text}`;
    if (addInjectedNetworkFromConsole(message, text)) return;
    const numericTimestamp = Number(message.timestamp);
    const timeBucket = Number.isFinite(numericTimestamp) ? Math.round(numericTimestamp * (numericTimestamp > 1e12 ? 0.1 : 100)) : 0;
    const fingerprint = `${timeBucket}|${level}|${text}`;
    if (recentConsole.has(fingerprint)) return;
    recentConsole.set(fingerprint, Date.now());
    if (recentConsole.size > 2000) {
      const oldest = recentConsole.keys().next().value;
      recentConsole.delete(oldest);
    }
    addSyntheticNetworkFromConsole(message, text);
    const location = message.url ? ` (${message.url}:${message.line || 0}:${message.column || 0})` : '';
    logLines.push(`[${time}] [${level}] [${source}] ${text}${location}`);
  }

  function addInjectedNetworkFromConsole(message, text) {
    const markerIndex = text.indexOf(COMPAT_NETWORK_PREFIX);
    if (markerIndex < 0) return false;
    let payload;
    try { payload = JSON.parse(text.slice(markerIndex + COMPAT_NETWORK_PREFIX.length)); }
    catch { return true; }
    const url = String(payload.url || '');
    if (!/^https?:\/\//i.test(url) || nativeNetworkUrls.has(url)) return true;
    const startedAtMs = Number(payload.startedAt);
    const endedAtMs = Number(payload.endedAt);
    const key = `hook|${Math.round(startedAtMs || 0)}|${url}`;
    if (syntheticNetworkKeys.has(key)) return true;
    syntheticNetworkKeys.add(key);
    const startSeconds = Number.isFinite(startedAtMs) ? startedAtMs / 1000 : Number(message.timestamp);
    const endSeconds = Number.isFinite(endedAtMs) ? endedAtMs / 1000 : startSeconds;
    const entry = makeHarEntry({
      requestId: `hook-${sequence + 1}`,
      request: {method: String(payload.method || 'GET').toUpperCase(), url, headers: {}},
      timestamp: startSeconds,
      wallTime: startSeconds,
      type: 'XHR',
    }, ++sequence, monotonicOffset);
    entry._fromInjectedHook = true;
    entry._captureNote = 'Ricostruita tramite hook XHR/fetch: il firmware non espone eventi Network completi.';
    entry.response.status = Number(payload.status) || 0;
    entry.response.statusText = String(payload.statusText || '');
    finishEntry(entry, endSeconds);
    entries.push(entry);
    syntheticNetworkEntries.set(url, entry);
    return true;
  }

  function addSyntheticNetworkFromConsole(message, text) {
    const isLoggedRequest = /\bXHR Req\s*:/i.test(text);
    const isNetworkError = String(message.source || '').toLowerCase() === 'network'
      || /Failed to load resource/i.test(text);
    if (!isLoggedRequest && !isNetworkError) return;

    const urls = text.match(/https?:\/\/[^\s"'<>]+/gi) || [];
    if (isNetworkError && message.url && /^https?:\/\//i.test(message.url)) urls.push(message.url);
    const statusMatch = text.match(/\bstatus(?:\s+of)?\s+(\d{3})\b/i);
    const status = statusMatch ? Number(statusMatch[1]) : 0;
    for (const rawUrl of urls) {
      const url = rawUrl.replace(/[),.;]+$/, '');
      if (nativeNetworkUrls.has(url)) continue;
      const timestamp = Number(message.timestamp);
      const bucket = Number.isFinite(timestamp) ? Math.round(timestamp * 100) : 0;
      const key = `${bucket}|${url}`;
      if (syntheticNetworkKeys.has(key)) continue;
      syntheticNetworkKeys.add(key);

      const entry = makeHarEntry({
        requestId: `console-${sequence + 1}`,
        request: { method: 'GET', url, headers: {} },
        timestamp: Number.isFinite(timestamp) ? timestamp : undefined,
        type: 'XHR',
      }, ++sequence, monotonicOffset);
      entry._fromConsole = true;
      entry._captureNote = 'Ricostruita dalla console: il vecchio WebKit non espone eventi Network live.';
      entry.response.status = status;
      entry.response.statusText = status ? 'Rilevato dalla console' : 'Risposta non esposta dal runtime';
      finishEntry(entry, Number.isFinite(timestamp) ? timestamp : undefined);
      entries.push(entry);
      syntheticNetworkEntries.set(url, entry);
    }
  }

  function addRuntimeConsole(params) {
    const message = {
      timestamp: params.timestamp,
      level: params.type,
      source: 'console-api',
      parameters: params.args,
      text: '',
    };
    const frame = params.stackTrace && params.stackTrace.callFrames && params.stackTrace.callFrames[0];
    if (frame) {
      message.url = frame.url;
      message.line = (frame.lineNumber || 0) + 1;
      message.column = (frame.columnNumber || 0) + 1;
    }
    addConsole(message);
  }

  function handleEvent(message) {
    const params = message.params || {};
    switch (message.method) {
      case 'Network.requestWillBeSent': { // Redirect e nuova richiesta condividono requestId.
        if (Number.isFinite(params.wallTime) && Number.isFinite(params.timestamp)) {
          monotonicOffset = params.wallTime - params.timestamp;
        }
        const previous = current.get(params.requestId);
        if (previous && params.redirectResponse) {
          applyResponse(previous, params.redirectResponse);
          finishEntry(previous, params.timestamp);
        }
        const requestUrl = params.request && params.request.url;
        if (requestUrl) {
          nativeNetworkUrls.add(requestUrl);
          const synthetic = syntheticNetworkEntries.get(requestUrl);
          if (synthetic) {
            const syntheticIndex = entries.indexOf(synthetic);
            if (syntheticIndex >= 0) entries.splice(syntheticIndex, 1);
            syntheticNetworkEntries.delete(requestUrl);
          }
        }
        const entry = makeHarEntry(params, ++sequence, monotonicOffset);
        entries.push(entry);
        current.set(params.requestId, entry);
        break;
      }
      case 'Network.responseReceived': {
        const entry = current.get(params.requestId);
        if (entry) {
          entry._resourceType = params.type || entry._resourceType;
          applyResponse(entry, params.response);
        }
        break;
      }
      case 'Network.dataReceived': {
        const entry = current.get(params.requestId);
        if (entry) entry.response.content.size += params.encodedDataLength || params.dataLength || 0;
        break;
      }
      case 'Network.loadingFinished': {
        const entry = current.get(params.requestId);
        finishEntry(entry, params.timestamp);
        if (entry && Number.isFinite(params.encodedDataLength)) {
          entry.response.bodySize = params.encodedDataLength;
          entry.response.content.size = Math.max(entry.response.content.size, params.encodedDataLength);
        }
        current.delete(params.requestId);
        break;
      }
      case 'Network.loadingFailed': {
        const entry = current.get(params.requestId);
        finishEntry(entry, params.timestamp);
        if (entry) {
          entry._failed = true;
          entry._failureText = params.errorText || 'Network.loadingFailed';
          entry.response.statusText = params.errorText || entry.response.statusText;
        }
        current.delete(params.requestId);
        break;
      }
      case 'Console.messageAdded':
        addConsole(params.message || {});
        break;
      case 'Runtime.consoleAPICalled':
        addRuntimeConsole(params);
        break;
      case 'Log.entryAdded': {
        const entry = params.entry || {};
        addConsole({
          timestamp: entry.timestamp,
          level: entry.level || 'log',
          source: entry.source || 'log-domain',
          text: entry.text || '',
          url: entry.url,
          line: entry.lineNumber,
        });
        break;
      }
      case 'Network.requestWillBeSentExtraInfo': {
        const entry = current.get(params.requestId);
        if (entry && params.headers) entry.request.headers = headerList(params.headers);
        break;
      }
      case 'Network.responseReceivedExtraInfo': {
        const entry = current.get(params.requestId);
        if (entry) {
          if (params.headers) entry.response.headers = headerList(params.headers);
          if (Number.isFinite(params.statusCode)) entry.response.status = params.statusCode;
        }
        break;
      }
      case 'Network.requestServedFromCache': {
        const entry = current.get(params.requestId);
        if (entry) entry._fromDiskCache = true;
        break;
      }
      case 'Runtime.exceptionThrown': {
        const details = params.exceptionDetails || params.details || {};
        addConsole({
          timestamp: params.timestamp,
          level: 'error',
          source: 'javascript',
          text: details.text || (details.exception && remoteValue(details.exception)) || 'Eccezione JavaScript',
          url: details.url,
          line: details.lineNumber,
          column: details.columnNumber,
        });
        break;
      }
      default:
        break;
    }
  }

  async function stop(reason, exitCode = 0) {
    if (stopping) return;
    stopping = true;
    clearInterval(flushTimer);
    clearTimeout(durationTimer);
    clearInterval(stopFileTimer);
    if (ws.readyState === WebSocket.OPEN) {
      if (hookRegistration) {
        try { await send(hookRegistration.method, hookRegistration.params); } catch { /* Protocollo legacy. */ }
        hookRegistration = null;
      }
      if (compatibilityHookInstalled) {
        try {
          await send('Runtime.evaluate', {expression: compatibilityNetworkHookCleanupSource(), silent: true});
          logLines.push(`[${new Date().toISOString()}] [INFO] [capture] Hook network temporaneo rimosso`);
        } catch { /* La chiusura non deve bloccarsi se Runtime non risponde. */ }
        compatibilityHookInstalled = false;
      }
    }
    for (const command of pending.values()) clearTimeout(command.timer);
    pending.clear();
    for (const entry of current.values()) finishEntry(entry, null);
    logLines.push(`[${new Date().toISOString()}] [INFO] [capture] Fine cattura: ${reason}`);
    flush();
    console.log(`\nCattura terminata (${reason}).`);
    console.log(`HAR: ${harPath}`);
    console.log(`LOG: ${logPath}`);
    console.log(`Richieste: ${entries.length}; righe console: ${Math.max(0, logLines.length - 2)}`);
    if (ws.readyState === WebSocket.OPEN) ws.close();
    setTimeout(() => process.exit(exitCode), 50);
  }

  ws.addEventListener('open', async () => {
    console.log(`Connesso a: ${target.title || target.id}`);
    console.log(`URL pagina: ${target.url || '(non disponibile)'}`);
    logLines.push(`[${startedAt}] [INFO] [capture] Inizio cattura target=${target.id} url=${target.url || ''}`);
    try {
      const enableDomain = async (method) => {
        try { await send(method); return {enabled: true, error: null}; }
        catch (error) { return {enabled: false, error}; }
      };
      const [networkState, consoleState, runtimeState, pageState, logState] = await Promise.all([
        enableDomain('Network.enable'),
        enableDomain('Console.enable'),
        enableDomain('Runtime.enable'),
        enableDomain('Page.enable'),
        enableDomain('Log.enable'),
      ]);
      const networkEnabled = networkState.enabled;
      const consoleEnabled = consoleState.enabled;
      const runtimeEnabled = runtimeState.enabled;
      const pageEnabled = pageState.enabled;
      const logEnabled = logState.enabled;
      const states = {Network: networkState, Console: consoleState, Runtime: runtimeState, Page: pageState, Log: logState};
      logLines.push(`[${new Date().toISOString()}] [INFO] [capture] Domini disponibili: ${Object.entries(states).map(([name, state]) => `${name}=${state.enabled ? 'si' : 'no'}`).join(' ')}`);
      for (const [name, state] of Object.entries(states)) {
        if (!state.enabled) logLines.push(`[${new Date().toISOString()}] [WARN] [capture] ${name} non disponibile: ${state.error.message}`);
      }
      if (!networkEnabled && !consoleEnabled && !runtimeEnabled && !logEnabled) {
        throw new Error('Il target non espone alcun dominio utile tra Network, Console, Runtime e Log.');
      }

      const hookSource = compatibilityNetworkHookSource();
      let hookInstalled = false;
      let hookPersistent = false;
      if (runtimeEnabled && (options.compatNetworkHook || !networkEnabled)) {
        if (pageEnabled) {
          try {
            const registration = await send('Page.addScriptToEvaluateOnNewDocument', {source: hookSource});
            hookPersistent = true;
            if (registration.identifier) {
              hookRegistration = {method: 'Page.removeScriptToEvaluateOnNewDocument', params: {identifier: registration.identifier}};
            }
          }
          catch {
            try {
              const registration = await send('Page.addScriptToEvaluateOnLoad', {scriptSource: hookSource});
              hookPersistent = true;
              if (registration.identifier) {
                hookRegistration = {method: 'Page.removeScriptToEvaluateOnLoad', params: {identifier: registration.identifier}};
              }
            }
            catch { /* Metodo assente sui protocolli più vecchi. */ }
          }
        }
        try {
          const evaluation = await send('Runtime.evaluate', {expression: hookSource, returnByValue: true, silent: true});
          hookInstalled = !evaluation.exceptionDetails;
          compatibilityHookInstalled = hookInstalled;
        } catch { /* Runtime può essere abilitato ma vietare evaluate. */ }
        logLines.push(`[${new Date().toISOString()}] [INFO] [capture] Hook network compatibilità: ${hookInstalled ? 'attivo' : 'non disponibile'}${hookPersistent ? ' e persistente al reload' : ''}`);
      }
      if (options.reload) {
        if (!pageEnabled) {
          logLines.push(`[${new Date().toISOString()}] [WARN] [capture] Reload ignorato: dominio Page non disponibile`);
        } else {
          const reloadParams = {ignoreCache: false};
          if (hookInstalled && !hookPersistent) reloadParams.scriptToEvaluateOnLoad = hookSource;
          try {
            await send('Page.reload', reloadParams);
            logLines.push(`[${new Date().toISOString()}] [INFO] [capture] Page.reload richiesto`);
          } catch (error) {
            logLines.push(`[${new Date().toISOString()}] [WARN] [capture] Reload non eseguito: ${error.message}`);
          }
        }
      }
      flush();
      console.log(`Registrazione in corso. ${options.duration ? `Durata: ${options.duration}s.` : 'Premere Ctrl+C per terminare.'}`);
      flushTimer = setInterval(flush, 5000);
      if (options.duration) durationTimer = setTimeout(() => stop('durata completata'), options.duration * 1000);
      if (options.stopFile) {
        stopFileTimer = setInterval(() => {
          if (fs.existsSync(options.stopFile)) stop('stop richiesto dal tool');
        }, 250);
      }
    } catch (error) {
      await stop(`errore CDP: ${error.message}`, 1);
    }
  });

  ws.addEventListener('message', (event) => {
    let message;
    try { message = JSON.parse(String(event.data)); } catch { return; }
    if (message.id) {
      const command = pending.get(message.id);
      if (!command) return;
      pending.delete(message.id);
      clearTimeout(command.timer);
      if (message.error) command.reject(new Error(`${command.method}: ${message.error.message || JSON.stringify(message.error)}`));
      else command.resolve(message.result || {});
      return;
    }
    handleEvent(message);
  });

  ws.addEventListener('error', () => {
    if (!stopping) stop('errore WebSocket (verificare che DevTools sia chiuso)', 1);
  });
  ws.addEventListener('close', (event) => {
    if (!stopping) stop(`WebSocket chiuso (codice ${event.code})`, 1);
  });
  process.on('SIGINT', () => stop('Ctrl+C'));
  process.on('SIGTERM', () => stop('processo terminato'));
}

main().catch((error) => {
  console.error(`Errore: ${error.message}`);
  process.exit(1);
});
