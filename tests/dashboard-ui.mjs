// Browser checks use deterministic, explicitly synthetic API responses. They
// never contact a real dashboard, Telegram, repository or server management API.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const modulePath = process.env.PLAYWRIGHT_MODULE;
if (!modulePath) throw new Error('Set PLAYWRIGHT_MODULE to the installed playwright/index.mjs for browser checks.');
const {chromium} = await import(pathToFileURL(modulePath).href);
const browser = await chromium.launch({headless: true, ...(process.env.CHROMIUM_EXECUTABLE_PATH ? {executablePath: process.env.CHROMIUM_EXECUTABLE_PATH, args: ['--no-sandbox', '--disable-dev-shm-usage']} : {})});
const context = await browser.newContext({viewport: {width: 1440, height: 1000}, colorScheme: 'dark'});
const page = await context.newPage();
const failures = [];
const actions = [];
const heartbeatRequests = [];
const requests = [];
const requestQueries = [];
const staticRoot = process.env.DASHBOARD_STATIC_ROOT || path.join(root, 'src/apps/dashboard/static');
let jobStatus = 'succeeded';
let jobFailures = 0;
let dashboardState = {state: 'awake', viewers: 1};
let authenticated = false;
let secretRevealed = false;
let managementState = {refresh: {state: 'current', pending: false}, pending_jobs: 0, accepting_jobs: true};
const now = Math.floor(Date.now() / 1000);
const metric = {stamp: now, cpu: {capacity: 2, used_fraction: 0.34, counters: {throttled_usec: 500}}, memory: {current_bytes: 3 * 1073741824, limit_bytes: 4 * 1073741824, events: {oom_kill: 0}}, temperatures: [{sensor: 'fixture', celsius: 45}]};
const summary = {calls: 12000, requests_per_second: 13.4, unique_ips: 86, bytes: 73400320, errors: 24, rate_limited: 7, cache_hits: 9300, cache_hit_ratio: 0.775, latency_ms: {p50: 5, p95: 25, p99: 100, approximate: true}, latest_metrics: metric, retention: {first_request: now - 604800}, breakdowns: Object.fromEntries(Object.entries({auth: ['anonymous', 'valid', 'rejected'], endpoint: ['query.example.test', 'search.example.test'], translation: ['kjv', 'asv'], search: ['faith hope'], reference: ['John 3:16'], book: ['43'], referrer: ['https://reader.example.test/'], user_agent: ['Fixture reader/1.0'], ip: ['192.0.2.10'], status: ['200', '429']}).map(([key, values]) => [key, values.map((value, i) => ({value, calls: 6000 / (i + 1), bytes: 1048576, errors: i}))]))};
for (const [dimension, values] of Object.entries(summary.breakdowns)) for (const row of values) {
  row.filters = {[dimension]: row.value, origin_only: 'true'};
  if (['translation', 'book', 'search', 'reference'].includes(dimension)) Object.assign(row.filters, {successful: 'true', usage: dimension});
  if (['search', 'reference'].includes(dimension)) row.filters.endpoint_kind = dimension === 'search' ? 'search' : 'query';
  if (dimension === 'book') row.label = 'John';
}
const worker = {pid: 123, rss_bytes: 134217728, private_bytes: 67108864, translation_status: {kjv: {ready: false, reason: 'Only part of the query translation is resident.'}}, cache: {ttl_seconds: 2592000, query_translations: {kjv: {chapters: 1, estimated_bytes: 17000, expired_chapters: 0}}, search_corpora: {translations: {}}}};
const searchWorker = {...worker, translation_status: {kjv: {ready: true}}, cache: {...worker.cache, search_corpora: {translations: {kjv: {verses: 31102, estimated_bytes: 34000000, indexes: [{case_sensitive: false, fold_diacritics: true}]}}}, translation_cache: {translations: {kjv: {estimated_bytes: 13000000}}}}};
const inventory = {endpoints: [{domain: 'query.example.test', label: 'v2', type: 'runtime', kind: 'query', live: true, settings: {ACCESS_MODE: 'open'}, endpoint_settings: {WORKERS: '9', MEMORY_TTL: '30d'}}]};
const operations = [
  {id: 'runtime.cache', title: 'Manage translation memory', fields: [{name: 'domain', type: 'domain', required: true}, {name: 'endpoint', required: true}, {name: 'action', choices: ['warm', 'drop', 'reload'], required: true}, {name: 'translation', required: true}]},
  {id: 'pages.write', title: 'Edit page content', fields: [{name: 'domain', required: true}, {name: 'kind', choices: ['docs', 'openapi'], required: true}, {name: 'content', type: 'multiline', required: true}]},
  {id: 'runtime.set', title: 'Set runtime endpoint configuration', fields: [{name: 'domain', required: true}, {name: 'endpoint'}, {name: 'key', choices: ['WORKERS', 'MEMORY_TTL'], required: true}, {name: 'value', required: true}]},
  {id: 'logs.view', title: 'View diagnostics', fields: [{name: 'domain', required: true}]},
  {id: 'logs.reset', title: 'Start fresh traffic history', description: 'Discard recorded requests and begin a fresh history.', fields: []},
  {id: 'token.add', title: 'Issue an API token', secret_output: true, fields: [{name: 'domain', required: true}, {name: 'label', required: true}]},
];
page.on('pageerror', error => failures.push(error.message));
await page.route('**/*', async route => {
  const request = route.request();
  const url = new URL(request.url());
  assert.equal(url.origin, 'https://dashboard.example.test', 'All assets and API requests stay on the dashboard origin');
  if (url.pathname.startsWith('/api/')) {
    requests.push(url.pathname); requestQueries.push({name: url.pathname, query: Object.fromEntries(url.searchParams)});
    let value;
    const body = request.method() === 'POST' ? request.postDataJSON() : null;
    const name = url.pathname.slice(5);
    if (name === 'jobs/job-fixture' && jobFailures > 0) {jobFailures -= 1; return route.fulfill({status: 503, contentType: 'application/problem+json', body: JSON.stringify({detail: 'The dashboard is restarting.'})});}
    if (name === 'auth/status') value = {authenticated, telegram_configured: true, ...(authenticated ? {csrf_token: 'fixture-csrf'} : {})};
    else if (name === 'auth/password') {assert.equal(body.password, 'fixture-password-only'); value = {challenge_id: 'fixture-challenge', expires_in: 60};}
    else if (name === 'auth/token') {assert.equal(body.token, 'fixture-one-use-code'); authenticated = true; value = {authenticated: true, csrf_token: 'fixture-csrf'};}
    else if (name === 'dashboard/heartbeat') {heartbeatRequests.push(body); value = dashboardState;}
    else if (name === 'dashboard/state') value = dashboardState;
    else if (name === 'overview') value = summary;
    else if (name === 'audience') value = {referrers: summary.breakdowns.referrer, user_agents: summary.breakdowns.user_agent};
    else if (name === 'endpoints') value = inventory;
    else if (name === 'history') value = {series: Array.from({length: 30}, (_, i) => ({stamp: now - (30 - i) * 60, calls: 100 + i * 10, errors: i % 3})), metrics: Array.from({length: 30}, (_, i) => ({...metric, stamp: now - (30 - i) * 60}))};
    else if (name === 'requests') value = {items: [{id: 1, stamp: now, endpoint: 'query.example.test', version: 'v2', method: 'GET', path: '/v2/kjv/43/3.json', status: 200, duration_ms: 2, remote_addr: '192.0.2.10', auth: 'valid', referrer: 'https://reader.example.test/', user_agent: 'Fixture reader/1.0'}], next_cursor: null};
    else if (name === 'translations') value = {endpoints: [{domain: 'query.example.test', label: 'v2', kind: 'query', generation: 'fixture', complete: true, expected_workers: 1, workers: [worker]}, {domain: 'search.example.test', label: 'v2', kind: 'search', generation: 'fixture', complete: true, expected_workers: 9, configured_warm_translations: ['kjv'], workers: Array.from({length: 9}, (_, index) => ({...searchWorker, pid: 200 + index})), available_translations: [{translation: 'kjv', allocated_bytes: 40000000}, {translation: 'asv', allocated_bytes: 30000000}]}]};
    else if (name === 'storage') value = {components: [{name: 'Bibles', kind: 'files', bytes: 1000000000, path: '/srv/getbible'}], total_bytes: 1000000000, filesystem_available_bytes: 800000000000};
    else if (name === 'operations') value = operations;
    else if (name === 'management/state') value = managementState;
    else if (name === 'jobs') value = [{id: 'job-fixture', operation: 'token.add', status: 'succeeded', created: now}];
    else if (name === 'jobs/job-fixture') value = {id: 'job-fixture', operation: 'token.add', status: jobStatus, started: jobStatus === 'waiting' ? null : now, created: now, output: jobStatus === 'waiting' ? 'Waiting for another management command. The operation resumes automatically.' : 'Operation complete. Secret is available once.', secret_available: jobStatus === 'succeeded' && !secretRevealed};
    else if (name === 'jobs/job-fixture/reveal') {secretRevealed = true; value = {one_time_output: 'synthetic-token-do-not-use'};}
    else if (name === 'actions') {assert.equal(request.headers()['x-csrf-token'], 'fixture-csrf'); actions.push(body); if (body.operation === 'logs.reset') dashboardState = {state: 'awake', viewers: 1}; value = {job_id: 'job-fixture', status: 'queued'};}
    else if (name === 'events') value = {items: [{id: 1, stamp: now, endpoint: 'query.example.test', source: 'journal', payload: {event: 'sync.completed', message: 'Fixture sync completed'}}]};
    else if (name === 'sessions') value = {sessions: [{id: 'session-fixture', ip: '192.0.2.10', user_agent: 'Fixture browser', created_at: now, expires_at: now + 2592000}]};
    else if (name === 'auth/logout') {authenticated = false; value = {authenticated: false};}
    else throw new Error(`Unexpected API route: ${name}`);
    return route.fulfill({status: 200, contentType: 'application/json', body: JSON.stringify(value)});
  }
  const relative = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
  const target = path.resolve(staticRoot, relative);
  assert.ok(target.startsWith(path.resolve(staticRoot) + path.sep));
  const type = {'.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png'}[path.extname(target)] || 'application/octet-stream';
  return route.fulfill({status: 200, contentType: type, headers: {'Content-Security-Policy': "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"}, body: await fs.readFile(target)});
});

try {
  await page.goto('https://dashboard.example.test/');
  await page.getByLabel('Password', {exact: true}).fill('fixture-password-only');
  await page.getByRole('button', {name: 'Continue with Telegram'}).click();
  await page.getByLabel('Telegram code', {exact: true}).fill('fixture-one-use-code');
  await page.getByRole('button', {name: 'Verify and open dashboard'}).click();
  await page.getByRole('heading', {name: 'Traffic & performance'}).waitFor();
  await page.getByText('12,000', {exact: true}).waitFor();
  assert.ok(await page.locator('canvas').count() >= 2, 'ECharts renders the request and access charts');
  assert.ok(heartbeatRequests.length > 0, 'Authenticated viewer keeps reporting awake');
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await fs.mkdir(path.join(root, 'test-artifacts'), {recursive: true});
  await page.screenshot({path: path.join(root, 'test-artifacts/dashboard-dark.png'), fullPage: true});
  await page.getByLabel('Color theme').selectOption('light');
  assert.equal(await page.locator('html').getAttribute('data-bs-theme'), 'light');
  await page.screenshot({path: path.join(root, 'test-artifacts/dashboard-light.png'), fullPage: true});
  await page.locator('.panel').filter({has: page.getByRole('heading', {name: 'Frequent searches'})}).getByRole('button', {name: /faith hope/}).click();
  await page.getByText('192.0.2.10', {exact: true}).waitFor();
  assert.deepEqual(requestQueries.filter(request => request.name === '/api/requests').at(-1).query.usage, 'search');
  assert.equal(requestQueries.filter(request => request.name === '/api/requests').at(-1).query.endpoint_kind, 'search');
  assert.equal(requestQueries.filter(request => request.name === '/api/requests').at(-1).query.successful, 'true');
  await page.getByLabel('Responses', {exact: true}).selectOption('');
  await page.getByRole('button', {name: 'Apply filters'}).click();
  await page.getByRole('button', {name: /^successful: true/}).waitFor({state: 'hidden'});
  assert.equal(requestQueries.filter(request => request.name === '/api/requests').at(-1).query.usage, undefined);
  await page.getByRole('button', {name: 'Clear all', exact: true}).click();
  await page.getByLabel('Client IP', {exact: true}).fill('192.0.2.10');
  await page.getByLabel('Search all request data', {exact: true}).fill('reader');
  await page.getByRole('button', {name: 'Apply filters'}).click();
  await page.getByRole('button', {name: /^q: reader/}).waitFor();
  assert.equal(requestQueries.filter(request => request.name === '/api/requests').at(-1).query.q, 'reader');
  await page.getByRole('button', {name: 'Clear all', exact: true}).click();
  await page.getByRole('button', {name: 'Audience', exact: true}).click();
  const referrers = page.locator('.panel').filter({has: page.getByRole('heading', {name: 'Referrers', exact: true})});
  await referrers.getByRole('button', {name: 'https://reader.example.test/', exact: true}).click();
  await page.getByLabel('Exact referrer', {exact: true}).waitFor();
  assert.equal(await page.getByLabel('Exact referrer', {exact: true}).inputValue(), 'https://reader.example.test/');
  await page.getByRole('button', {name: 'Clear all', exact: true}).click();
  await page.getByRole('button', {name: 'Translations', exact: true}).click();
  const searchMemory = page.locator('.panel').filter({has: page.getByRole('heading', {name: 'search.example.test / v2', exact: true})});
  await searchMemory.getByRole('button', {name: /KJV/}).waitFor();
  assert.equal(await searchMemory.getByRole('button', {name: /KJV/}).count(), 1, 'One resident translation row represents all nine workers');
  await searchMemory.getByText('31,102 verses', {exact: false}).waitFor();
  await searchMemory.getByText('1 chapter', {exact: false}).waitFor();
  await page.getByLabel('Runtime endpoint', {exact: true}).selectOption('search.example.test/v2');
  assert.equal(await page.getByRole('button', {name: 'Already warm', exact: true}).first().isDisabled(), true);
  await page.screenshot({path: path.join(root, 'test-artifacts/dashboard-translations.png'), fullPage: true});
  await searchMemory.getByRole('button', {name: /KJV/}).click();
  assert.equal(await searchMemory.getByRole('button', {name: /^20[0-8]$/}).count(), 9, 'Translation drilldown exposes each worker');
  await page.screenshot({path: path.join(root, 'test-artifacts/dashboard-workers.png'), fullPage: true});
  await searchMemory.getByRole('button', {name: 'Back to translations'}).click();
  await searchMemory.getByRole('button', {name: 'Reload', exact: true}).click();
  await page.getByRole('button', {name: 'Run operation'}).click();
  assert.deepEqual(actions.at(-1), {operation: 'runtime.cache', arguments: {domain: 'search.example.test', endpoint: 'v2', action: 'reload', translation: 'kjv'}, confirm: true});
  await page.getByRole('button', {name: 'Reveal issued credential once'}).click();
  await page.getByText('synthetic-token-do-not-use', {exact: true}).waitFor();
  assert.equal(secretRevealed, true);
  await page.getByRole('button', {name: 'Close details'}).click();
  await page.getByRole('button', {name: 'Resources', exact: true}).click();
  await page.getByText('45 °C', {exact: true}).waitFor();
  await page.getByText('Bibles', {exact: true}).waitFor();
  await page.getByRole('button', {name: 'Events', exact: true}).click();
  await page.getByText('Fixture sync completed', {exact: true}).waitFor();
  await page.getByRole('button', {name: 'Manage', exact: true}).click();
  await page.getByRole('button', {name: /Domains Status, endpoints/}).click();
  await page.getByRole('button', {name: /query.example.test.*query/}).click();
  await page.screenshot({path: path.join(root, 'test-artifacts/dashboard-manage-domain.png'), fullPage: true});
  await page.getByRole('button', {name: /Runtime settings Set runtime/}).click();
  await page.getByRole('button', {name: /\/v2\//}).click();
  await page.getByLabel('key', {exact: true}).selectOption('WORKERS');
  assert.equal(await page.getByLabel('value', {exact: true}).inputValue(), '9', 'Runtime settings use current endpoint values');
  await page.getByRole('navigation', {name: 'Management navigation'}).getByRole('button', {name: 'query.example.test', exact: true}).click();
  await page.getByRole('button', {name: /Pages and OpenAPI Edit page content/}).click();
  await page.getByLabel('kind', {exact: true}).selectOption('docs');
  await page.getByLabel('content', {exact: true}).fill('<h1>Fixture page</h1>');
  managementState = {refresh: {state: 'waiting', pending: true}, pending_jobs: 1, accepting_jobs: false};
  await page.getByText('Management services are updating', {exact: true}).waitFor();
  assert.equal(await page.getByRole('button', {name: 'Review operation'}).isDisabled(), true);
  managementState = {refresh: {state: 'current', pending: false}, pending_jobs: 0, accepting_jobs: true};
  await page.getByText('Management services are updating', {exact: true}).waitFor({state: 'hidden'});
  await page.getByRole('button', {name: 'Review operation'}).click();
  jobStatus = 'waiting';
  await page.getByRole('button', {name: 'Run operation'}).click();
  await page.getByText('Waiting to start', {exact: true}).waitFor();
  await page.getByText('waiting', {exact: true}).waitFor();
  jobFailures = 1;
  jobStatus = 'succeeded';
  await page.getByText('Reconnecting to operation progress… The accepted job continues on the server.', {exact: true}).waitFor();
  await page.getByRole('dialog').getByText('succeeded', {exact: true}).waitFor();
  assert.equal(actions.at(-1).arguments.content, '<h1>Fixture page</h1>');
  await page.getByRole('button', {name: 'Close details'}).click();
  await page.getByRole('button', {name: 'Overview', exact: true}).click();
  dashboardState = {state: 'unavailable', error: 'The recorded history uses an incompatible schema. Start fresh history to continue.'};
  await page.reload();
  await page.getByRole('heading', {name: 'Traffic history needs attention', exact: true}).waitFor();
  await page.getByRole('button', {name: 'Manage traffic history', exact: true}).click();
  await page.getByRole('button', {name: /History Start fresh traffic history/}).click();
  await page.getByText('Discard recorded requests and begin a fresh history.', {exact: true}).waitFor();
  await page.getByRole('button', {name: 'Review operation'}).click();
  await page.getByRole('button', {name: 'Run operation'}).click();
  assert.equal(actions.at(-1).operation, 'logs.reset', 'History reset remains reachable with unavailable analytics');
  await page.getByRole('button', {name: 'Close details'}).click();
  await page.getByRole('button', {name: 'Overview', exact: true}).click();
  await page.getByText('12,000', {exact: true}).waitFor();
  assert.equal(await page.getByText('The recorded history uses an incompatible schema. Start fresh history to continue.', {exact: true}).count(), 0, 'Recovered history clears its outage notice');
  await page.setViewportSize({width: 390, height: 844});
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await page.screenshot({path: path.join(root, 'test-artifacts/dashboard-mobile.png'), fullPage: true});
  await page.getByRole('button', {name: 'Toggle navigation'}).click();
  await page.getByRole('button', {name: 'Sessions', exact: true}).click();
  await page.getByText('Fixture browser', {exact: true}).waitFor();
  assert.deepEqual(failures, [], 'No browser runtime errors');
  console.log('Dashboard browser checks passed: authentication flow, charts, scoped rankings, audience filters, translation/worker layers, CLI menu navigation, waiting jobs, one-time output, themes and mobile layout.');
} catch (error) {
  await fs.mkdir(path.join(root, 'test-artifacts'), {recursive: true});
  await page.screenshot({path: path.join(root, 'test-artifacts/dashboard-failure.png'), fullPage: true});
  console.error('Browser errors:', failures);
  throw error;
} finally {
  await context.close();
  await browser.close();
}
