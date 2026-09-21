import assert from 'node:assert/strict';
import {test} from 'node:test';
import {reportPaths, startReports} from '../src/reporting.js';

const settled = () => new Promise(resolve => setImmediate(resolve));

function harness(options = {}) {
    const calls = [], changes = [], errors = [], timers = new Map();
    let id = 0;
    const stop = startReports({
        paths: () => ({overview: 'overview?range=week', history: 'history?range=week'}),
        onChange: (name, state) => changes.push({name, state}),
        onError: error => errors.push(error),
        load: (path, {signal}) => new Promise((resolve, reject) => calls.push({path, signal, resolve, reject})),
        schedule: (callback, delay) => {timers.set(++id, {callback, delay}); return id;},
        cancel: timer => timers.delete(timer),
        ...options,
    });
    return {calls, changes, errors, timers, stop,
        latest: name => changes.filter(change => change.name === name).at(-1)?.state,
        tick: () => {const [key, timer] = timers.entries().next().value; timers.delete(key); timer.callback();},
    };
}

test('report requests follow the visible page and resource metrics ignore traffic filters', () => {
    const range = {start: 100, end: 100 + 604800};
    const overview = reportPaths('Overview', range, false, {search: 'faith & hope'});
    assert.deepEqual(Object.keys(overview), ['overview', 'history']);
    const query = new URLSearchParams(overview.overview.split('?')[1]);
    assert.equal(query.get('search'), 'faith & hope');
    assert.equal(query.get('start'), '100');
    assert.equal(query.get('end'), String(range.end));
    assert.equal(query.get('bucket_seconds'), '1512');
    assert.equal(query.get('dimensions').includes('mcp_tool'), false);
    assert.deepEqual(Object.keys(reportPaths('Resources', range, false, {search: 'faith'})), ['metrics']);
    assert.equal(reportPaths('Resources', range, false, {search: 'faith'}).metrics.includes('search'), false);
    for (const page of ['Traffic', 'Events', 'Translations', 'Manage', 'Sessions', '']) {
        assert.deepEqual(reportPaths(page, range, false), {});
    }
    const live = new URLSearchParams(reportPaths('Overview', range, true, {}, 2000).history.split('?')[1]);
    assert.equal(live.get('start'), '1100');
    assert.equal(live.get('end'), '2000');
    assert.equal(live.get('bucket_seconds'), '5');
});

test('a ready chart appears before totals finish and survives an independent totals failure', async () => {
    const run = harness();
    const chart = {series: [{stamp: 100, calls: 30}]};
    run.calls[1].resolve(chart);
    await settled();
    assert.deepEqual(run.latest('history').data, chart);
    assert.equal(run.latest('overview').loading, true);
    const failure = new Error('Totals unavailable');
    run.calls[0].reject(failure);
    await settled();
    assert.equal(run.latest('overview').error, failure);
    assert.deepEqual(run.latest('history').data, chart);
    assert.deepEqual(run.errors, [], 'Panel failures do not become persistent global errors');
    assert.equal(run.timers.size, 0, 'Completed historical reports do not poll');
    run.stop();
});

test('preparing historical panels retry alone until ready without refetching a ready sibling', async () => {
    const run = harness();
    run.calls[0].resolve({calls: 300000});
    run.calls[1].resolve({state: 'preparing', retry_after: 2, progress: {complete: 5}});
    await settled();
    assert.equal(run.latest('overview').data.calls, 300000);
    assert.equal(run.latest('history').preparing, true);
    assert.equal(run.latest('history').data, null);
    assert.deepEqual(run.latest('history').progress, {complete: 5});
    assert.equal(run.timers.size, 1);
    assert.equal([...run.timers.values()][0].delay, 2000);
    run.tick();
    assert.equal(run.calls.length, 3);
    assert.match(run.calls[2].path, /^history/);
    run.calls[2].resolve({series: [{stamp: 100, calls: 300000}]});
    await settled();
    assert.equal(run.latest('history').preparing, false);
    assert.equal(run.latest('history').loading, false);
    assert.equal(run.timers.size, 0);
    run.stop();
});

test('superseded ranges abort requests and ignore late successes, failures and authentication errors', async () => {
    const old = harness();
    const count = old.changes.length;
    old.stop();
    assert.equal(old.calls.every(call => call.signal.aborted), true);
    const current = harness({paths: () => ({overview: 'overview?range=month'})});
    current.calls[0].resolve({calls: 9000000});
    await settled();
    old.calls[0].resolve({calls: 300000});
    old.calls[1].reject(Object.assign(new Error('Old session failure'), {status: 401}));
    await settled();
    assert.equal(old.changes.length, count);
    assert.deepEqual(old.errors, []);
    assert.equal(current.latest('overview').data.calls, 9000000);
    current.stop();
});

test('Live refresh is scheduled after completion and cannot overlap a pending request', async () => {
    const run = harness({live: true, paths: () => ({history: 'history?live=true'})});
    assert.equal(run.calls.length, 1);
    assert.equal(run.timers.size, 0);
    run.calls[0].resolve({series: []});
    await settled();
    assert.equal(run.timers.size, 1);
    run.tick();
    assert.equal(run.calls.length, 2);
    assert.equal(run.timers.size, 0);
    assert.equal(run.latest('history').loading, true);
    run.calls[1].reject(new Error('Temporary failure'));
    await settled();
    assert.equal(run.timers.size, 1);
    assert.deepEqual(run.latest('history').data, {series: []});
    run.stop();
    assert.equal(run.timers.size, 0);
});

test('session expiry reaches the authentication handler and does not schedule a retry', async () => {
    const run = harness({live: true, paths: () => ({overview: 'overview'})});
    const error = Object.assign(new Error('Session expired'), {status: 401});
    run.calls[0].reject(error);
    await settled();
    assert.deepEqual(run.errors, [error]);
    assert.equal(run.timers.size, 0);
    run.stop();
});

test('Audience and MCP reports request only their own report with the selected filters', () => {
    const range = {start: 100, end: 200};
    const audience = reportPaths('Audience', range, false, {dimension: 'referrer', referrer_contains: 'reader'});
    assert.deepEqual(Object.keys(audience), ['audience']);
    assert.equal(new URLSearchParams(audience.audience.split('?')[1]).get('dimension'), 'referrer');
    const mcp = reportPaths('MCP traffic', range, false, {endpoint_kind: 'mcp', origin_only: 'true'});
    assert.deepEqual(Object.keys(mcp), ['mcp']);
    assert.equal(new URLSearchParams(mcp.mcp.split('?')[1]).get('endpoint_kind'), 'mcp');
});
