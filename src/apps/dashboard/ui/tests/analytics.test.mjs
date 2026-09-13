import assert from 'node:assert/strict';
import {test} from 'node:test';
import {rankingFilters, activeJob, editTrafficFilter} from '../src/analytics.js';

test('usage drilldowns preserve the returned successful origin and endpoint scope', () => {
    const row = {value: 'faith & hope', filters: {search: 'faith & hope', successful: 'true', endpoint_kind: 'search', origin_only: 'true', usage: 'search'}};
    assert.deepEqual(rankingFilters('search', row, {version: 'v2'}), {version: 'v2', ...row.filters});
});

test('book labels do not replace the numeric identifier in drilldown filters', () => {
    const row = {value: '73', label: 'Extra book', filters: {book: '73', usage: 'book', successful: 'true'}};
    assert.equal(rankingFilters('book', row).book, '73');
});

test('waiting management jobs continue polling instead of announcing completion', () => {
    for (const state of ['queued', 'waiting', 'running']) assert.equal(activeJob(state), true);
    for (const state of ['succeeded', 'failed']) assert.equal(activeJob(state), false);
});


test('explicit traffic controls remove conflicting ranking scope without losing the selected consumer', () => {
    const filters = {usage: 'search', successful: 'true', search: 'faith', endpoint_kind: 'search', origin_only: 'true'};
    const all = editTrafficFilter(filters, 'successful', '');
    assert.equal(all.usage, undefined);
    assert.equal(all.search, 'faith');
    assert.equal(all.origin_only, 'true');
    const error = editTrafficFilter(filters, 'status', '404');
    assert.equal(error.usage, undefined);
    assert.equal(error.successful, undefined);
    assert.equal(error.status, '404');
    assert.equal(editTrafficFilter(filters, 'endpoint_kind', 'query').usage, undefined);
});
