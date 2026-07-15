import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
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
