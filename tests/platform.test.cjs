const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../app/platform.js'), 'utf8');
function nativeFixture() {
  const messages = [], timers = new Map(); let timerID = 0;
  const window = { webkit: { messageHandlers: { airwave: { postMessage: message => messages.push(message) } } } };
  vm.runInNewContext(source, { window, setTimeout: (fn, ms) => { timers.set(++timerID, { fn, ms }); return timerID; }, clearTimeout: id => timers.delete(id) });
  return { window, api: window.AirwavePlatform, messages, timers };
}
test('Apple bridge correlates replies and keeps the document-picker timeout distinct', async () => {
  const f = nativeFixture();
  const catalog = f.api.loadLibrary();
  const imported = f.api.importLibrary();
  assert.deepEqual(f.messages.map(x => x.action), ['library', 'importLibrary']);
  assert.deepEqual([...f.timers.values()].map(x => x.ms), [30000, 300000]);
  f.window.__airwaveNativeReply(f.messages[1].id, { items: ['new'] }, null);
  assert.deepEqual(await imported, { items: ['new'] });
  f.window.__airwaveNativeReply(f.messages[0].id, null, null);
  assert.equal(await catalog, null);
  assert.equal(f.timers.size, 0);
});
test('Apple bridge rejects native errors and ignores replies after timeout', async () => {
  const f = nativeFixture();
  const failed = f.api.request('play');
  f.window.__airwaveNativeReply(f.messages[0].id, null, 'Unsupported media');
  await assert.rejects(failed, /Unsupported media/);
  const expired = f.api.request('library');
  [...f.timers.values()][0].fn();
  await assert.rejects(expired, /timed out/);
  assert.doesNotThrow(() => f.window.__airwaveNativeReply(f.messages[1].id, {}, null));
});
test('web adapter keeps static hosting usable when no private-library endpoint exists', async () => {
  const window = {}; let request;
  vm.runInNewContext(source, { window, location: { protocol: 'https:' }, setTimeout, clearTimeout, fetch: async (...args) => { request = args; return { status: 404 }; } });
  assert.equal(await window.AirwavePlatform.loadLibrary(), null);
  assert.equal(request[0], '/api/library');
  assert.equal(request[1].credentials, 'same-origin');
});
