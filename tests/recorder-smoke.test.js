import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn, spawnSync} from 'node:child_process';
import test from 'node:test';
import {fileURLToPath, pathToFileURL} from 'node:url';

const testDir = path.dirname(fileURLToPath(import.meta.url));
const root = path.dirname(testDir);

test('recorder writes HAR and console log with legacy fallback deduplication', () => {
  const output = fs.mkdtempSync(path.join(os.tmpdir(), 'device-log-capture-test '));
  try {
    const result = spawnSync(process.execPath, [
      '--import', pathToFileURL(path.join(testDir, 'fake-websocket.js')).href,
      path.join(root, 'lib', 'cdp-capture.js'),
      '--ws-url', 'ws://fake.test/devtools/page/1',
      '--output', output,
      '--name', 'mock device',
      '--duration', '1',
    ], {encoding: 'utf8', timeout: 10000});
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);

    const harFile = fs.readdirSync(output).find((name) => name.endsWith('.har'));
    const logFile = fs.readdirSync(output).find((name) => name.endsWith('.log'));
    assert.ok(harFile, 'HAR not generated');
    assert.ok(logFile, 'LOG not generated');

    const har = JSON.parse(fs.readFileSync(path.join(output, harFile), 'utf8'));
    const entries = har.log.entries;
    assert.equal(entries.length, 3);
    const native = entries.filter((entry) => !entry._fromConsole);
    const recovered = entries.filter((entry) => entry._fromConsole);
    assert.equal(native.length, 1);
    assert.equal(recovered.length, 2);
    assert.equal(entries.filter((entry) => entry.request.url.includes('/native')).length, 1);
    assert.equal(entries.find((entry) => entry.request.url.includes('/native')).response.status, 200);
    assert.equal(entries.find((entry) => entry.request.url.includes('/missing')).response.status, 404);

    const log = fs.readFileSync(path.join(output, logFile), 'utf8');
    assert.match(log, /XHR Req: https:\/\/example\.test\/fallback/);
    assert.match(log, /Fine cattura: durata completata/);
  } finally {
    fs.rmSync(output, {recursive: true, force: true});
  }
});

test('recorder falls back from /json/list to /json', () => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'device-log-discovery-test '));
  const readyFile = path.join(temp, 'port.txt');
  const output = path.join(temp, 'output');
  const server = spawn(process.execPath, [path.join(testDir, 'fake-inspector-server.js'), readyFile], {
    stdio: 'ignore',
  });
  try {
    const deadline = Date.now() + 5000;
    while (!fs.existsSync(readyFile) && Date.now() < deadline) {
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 25);
    }
    assert.ok(fs.existsSync(readyFile), 'fake inspector did not start');
    const port = fs.readFileSync(readyFile, 'utf8').trim();
    const result = spawnSync(process.execPath, [
      '--import', pathToFileURL(path.join(testDir, 'fake-websocket.js')).href,
      path.join(root, 'lib', 'cdp-capture.js'),
      '--host', '127.0.0.1',
      '--port', port,
      '--output', output,
      '--duration', '1',
    ], {encoding: 'utf8', timeout: 10000});
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.match(result.stdout, /Connesso a: Target \/json/);
    assert.ok(fs.readdirSync(output).some((name) => name.endsWith('.har')));
  } finally {
    server.kill();
    fs.rmSync(temp, {recursive: true, force: true});
  }
});
