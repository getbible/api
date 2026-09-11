import assert from 'node:assert/strict';
import {test} from 'node:test';
import {api, post, query, bytes, setCsrf, ApiError} from '../src/api.js';

test('management requests use cookies and CSRF without URL credentials', async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    assert.equal(url, '/api/actions');
    assert.equal(options.credentials, 'same-origin');
    assert.equal(options.cache, 'no-store');
    assert.equal(options.headers['X-CSRF-Token'], 'csrf-fixture');
    assert.deepEqual(JSON.parse(options.body), {operation: 'runtime.cache', arguments: {translation: 'kjv'}});
    return {ok: true, json: async () => ({job_id: 'fixture'})};
  };
  try {setCsrf('csrf-fixture'); assert.deepEqual(await post('actions', {operation: 'runtime.cache', arguments: {translation: 'kjv'}}), {job_id: 'fixture'});}
  finally {globalThis.fetch = original; setCsrf('');}
});

test('expired sessions preserve error status for reauthentication', async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async () => ({ok: false, status: 401, json: async () => ({detail: 'Session expired'})});
  try {await assert.rejects(api('overview'), error => error instanceof ApiError && error.status === 401 && error.message === 'Session expired');}
  finally {globalThis.fetch = original;}
});

test('filters preserve complete query strings and byte units', () => {
  const params = new URLSearchParams(query({search: 'faith & hope', reference: 'John 3:16', empty: '', absent: null}));
  assert.equal(params.get('search'), 'faith & hope');
  assert.equal(params.get('reference'), 'John 3:16');
  assert.equal(params.has('empty'), false);
  assert.equal(bytes(1073741824), '1 GiB');
  assert.equal(bytes(null), '—');
});
