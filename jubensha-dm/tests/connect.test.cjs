// Run from jubensha-dm: node --test tests/connect.test.cjs
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function setup(file, handlers = {}) {
  const streams = [], timers = new Map(), listeners = new Set();
  let timerId = 0, removed = false;
  const badge = {classList: {toggle() {}}, remove() {removed = true;}};
  const document = {body: {appendChild() {}}, createElement: () => badge,
    visibilityState: 'visible', addEventListener: (_, f) => listeners.add(f),
    removeEventListener: (_, f) => listeners.delete(f)};
  class EventSource {
    constructor() {this.readyState = 0; streams.push(this);}
    close() {this.readyState = 2;}
  }
  const context = vm.createContext({document, EventSource, URLSearchParams,
    setTimeout: f => {timers.set(++timerId, f); return timerId;},
    clearTimeout: id => timers.delete(id)});
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', file), 'utf8'), context);
  const conn = vm.runInContext('connect', context)({role: 'player'}, handlers);
  return {streams, timers, listeners, conn, removed: () => removed,
    wake: () => [...listeners].forEach(f => f())};
}

for (const file of ['Resources/web/common.js', 'jubensha/static/common.js']) {
  test(`${file}: close cancels reconnect and removes UI/listener`, async () => {
    const s = setup(file);
    await s.streams[0].onerror();
    assert.equal(s.timers.size, 1);
    s.conn.close();
    assert.equal(s.timers.size, 0);
    assert.equal(s.listeners.size, 0);
    assert.ok(s.removed());
    s.wake();
    assert.equal(s.streams.length, 1);
  });
  test(`${file}: waking cancels scheduled retry`, async () => {
    const s = setup(file);
    await s.streams[0].onerror();
    s.wake();
    assert.equal(s.streams.length, 2);
    assert.equal(s.timers.size, 0);
    s.conn.close();
  });
  test(`${file}: stale asynchronous check cannot affect new connection`, async () => {
    let resolve;
    const s = setup(file, {check: () => new Promise(r => {resolve = r;})});
    const pending = s.streams[0].onerror();
    s.wake();
    resolve(false);
    await pending;
    assert.equal(s.streams.length, 2);
    assert.equal(s.streams[1].readyState, 0);
    assert.equal(s.timers.size, 0);
    assert.equal(s.listeners.size, 1);
    s.conn.close();
  });
  test(`${file}: kicked ends lifecycle`, () => {
    let kicked = 0;
    const s = setup(file, {kicked: () => kicked++});
    s.streams[0].onmessage({data: '{"type":"kicked"}'});
    assert.equal(kicked, 1);
    assert.equal(s.listeners.size, 0);
    assert.ok(s.removed());
    s.wake();
    assert.equal(s.streams.length, 1);
  });
}
