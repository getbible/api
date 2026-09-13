import assert from 'node:assert/strict';
import {test} from 'node:test';
import {translationMemory, translationState, valueRange} from '../src/translation-memory.js';
const worker = (pid, cache) => ({pid, cache});
const searchCache = {query_translations: {kjv: {chapters: 1, estimated_bytes: 17000}}, search_corpora: {translations: {kjv: {verses: 31102, estimated_bytes: 34000000, indexes: [{case_sensitive: false, fold_diacritics: true}]}}}, translation_cache: {translations: {kjv: {estimated_bytes: 13000000}}}, ttl_seconds: 86400};

test('nine workers create one translation with independent chapter, verse and snapshot data', () => {
    const rows = translationMemory({kind: 'search', complete: true, expected_workers: 9, workers: Array.from({length: 9}, (_, i) => worker(i + 10, searchCache))});
    assert.equal(rows.length, 1);
    assert.equal(rows[0].resident.length, 9);
    assert.equal(rows[0].ready, true);
    assert.equal(rows[0].workers[0].query_chapters, 1);
    assert.equal(rows[0].workers[0].search_verses, 31102);
    assert.deepEqual(valueRange(rows[0].resident, 'search_bytes'), {min: 34000000, max: 34000000});
    assert.equal(rows[0].snapshot_bytes, undefined);
});

test('one query chapter and absent workers cannot be labelled fully warmed', () => {
    const endpoint = {kind: 'query', complete: false, expected_workers: 2, workers: [worker(1, {query_translations: {kjv: {chapters: 1}}})]};
    const row = translationState(endpoint, 'kjv');
    assert.equal(row.ready, false);
    assert.equal(row.status, 'Partly resident');
    assert.equal(row.expected, 2);
    assert.equal(translationState(endpoint, 'de').status, 'Not reported');
});

test('stale caches remain visible, and disk/configuration alone never establishes residency', () => {
    const endpoint = {kind: 'search', complete: true, configured_warm_translations: ['kjv', 'de'], workers: [worker(1, {...searchCache, search_corpora: {translations: {kjv: {verses: 31102, stale: true}}}})]};
    assert.equal(translationState(endpoint, 'kjv').status, 'Recheck on use');
    assert.equal(translationState(endpoint, 'kjv').ready, false);
    assert.equal(translationState(endpoint, 'de').status, 'Not in memory');
    assert.equal(translationState(endpoint, 'de').configured, true);
    assert.equal(translationMemory(endpoint).length, 1);
});

test('a partial report cannot disable warm even when every responding worker has search data', () => {
    const row = translationState({kind: 'search', complete: false, expected_workers: 3, workers: [worker(1, searchCache), worker(2, searchCache)]}, 'kjv');
    assert.equal(row.ready, false);
    assert.equal(row.readyCount, 2);
});


test('a search corpus without the configured index is only partly ready', () => {
    const endpoint = {kind: 'search', complete: true, workers: [worker(1, {search_corpora: {translations: {kjv: {verses: 31102, indexes: []}}}})]};
    assert.equal(translationState(endpoint, 'kjv').ready, false);
    assert.equal(translationState(endpoint, 'kjv').status, 'Partly resident');
});

test('reported full query warming and budget-limited partial state are distinct', () => {
    const queryWorker = {pid: 5, cache: {query_translations: {kjv: {chapters: 1189}}}, translation_status: {kjv: {ready: true}}};
    const endpoint = {kind: 'query', complete: true, workers: [queryWorker]};
    assert.equal(translationState(endpoint, 'kjv').ready, true);
    queryWorker.translation_status.kjv = {ready: false, retention_limited: true, reason: 'Cache capacity retains only part of the translation.'};
    const limited = translationState(endpoint, 'kjv');
    assert.equal(limited.ready, false);
    assert.equal(limited.workers[0].retention_limited, true);
    assert.equal(limited.reasons.length, 1);
});
