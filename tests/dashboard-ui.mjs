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
const browser = await chromium.launch({headless: true});
const context = await browser.newContext({viewport: {width: 1440, height: 1000}, colorScheme: 'dark'});
const page = await context.newPage();
const failures = [];
const actions = [];
const heartbeatRequests = [];
const requests = [];
let authenticated = false;
let secretRevealed = false;
let managementState = {refresh: {state: 'current', pending: false}, pending_jobs: 0, accepting_jobs: true};
const now = Math.floor(Date.now() / 1000);
const metric = {stamp: now, cpu: {capacity: 2, used_fraction: 0.34, counters: {throttled_usec: 500}}, memory: {current_bytes: 3 * 1073741824, limit_bytes: 4 * 1073741824, events: {oom_kill: 0}}, temperatures: [{sensor: 'fixture', celsius: 45}]};
const summary = {calls: 12000, requests_per_second: 13.4, unique_ips: 86, bytes: 73400320, errors: 24, rate_limited: 7, cache_hits: 9300, cache_hit_ratio: 0.775, latency_ms: {p50: 5, p95: 25, p99: 100, approximate: true}, latest_metrics: metric, retention: {first_request: now - 604800}, breakdowns: Object.fromEntries(Object.entries({auth: ['anonymous', 'valid', 'rejected'], endpoint: ['query.example.test', 'search.example.test'], translation: ['kjv', 'asv'], search: ['faith hope'], reference: ['John 3:16'], book: ['43'], ip: ['192.0.2.10'], status: ['200', '429']}).map(([key, values]) => [key, values.map((value, i) => ({value, calls: 6000 / (i + 1), bytes: 1048576, errors: i}))]))};
const worker = {pid: 123, rss_bytes: 134217728, private_bytes: 67108864, cache: {ttl_seconds: 2592000, query_translations: {kjv: {chapters: 1189, estimated_bytes: 80000000, expired_chapters: 0}}, search_corpora: {translations: {}}}};
const operations = [
  {id: 'runtime.cache', title: 'Manage translation memory', fields: [{name: 'domain', type: 'domain', required: true}, {name: 'endpoint', required: true}, {name: 'action', choices: ['warm', 'drop', 'reload'], required: true}, {name: 'translation', required: true}]},
  {id: 'pages.write', title: 'Edit page content', fields: [{name: 'domain', required: true}, {name: 'kind', choices: ['docs', 'openapi'], required: true}, {name: 'content', type: 'multiline', required: true}]},
  {id: 'token.add', title: 'Issue an API token', secret_output: true, fields: [{name: 'domain', required: true}, {name: 'label', required: true}]},
];
page.on('pageerror', error => failures.push(error.message));
await page.route('**/*', async route => {
  const request = route.request();
  const url = new URL(request.url());
  assert.equal(url.origin, 'https://dashboard.example.test', 'All assets and API requests stay on the dashboard origin');
  if (url.pathname.startsWith('/api/')) {
    requests.push(url.pathname);
    let value;
    const body = request.method() === 'POST' ? request.postDataJSON() : null;
    const name = url.pathname.slice(5);
    if (name === 'auth/status') value = {authenticated, telegram_configured: true, ...(authenticated ? {csrf_token: 'fixture-csrf'} : {})};
    else if (name === 'auth/password') {assert.equal(body.password, 'fixture-password-only'); value = {challenge_id: 'fixture-challenge', expires_in: 60};}
    else if (name === 'auth/token') {assert.equal(body.token, 'fixture-one-use-code'); authenticated = true; value = {authenticated: true, csrf_token: 'fixture-csrf'};}
    else if (name === 'dashboard/heartbeat') {heartbeatRequests.push(body); value = {state: 'awake', viewers: 1};}
    else if (name === 'dashboard/state') value = {state: 'awake', viewers: 1};
    else if (name === 'overview') value = summary;
    else if (name === 'history') value = {series: Array.from({length: 30}, (_, i) => ({stamp: now - (30 - i) * 60, calls: 100 + i * 10, errors: i % 3})), metrics: Array.from({length: 30}, (_, i) => ({...metric, stamp: now - (30 - i) * 60}))};
    else if (name === 'requests') value = {items: [{id: 1, stamp: now, endpoint: 'query.example.test', version: 'v2', method: 'GET', path: '/v2/kjv/43/3.json', status: 200, duration_ms: 2, remote_addr: '192.0.2.10', auth: 'valid'}], next_cursor: null};
    else if (name === 'translations') value = {endpoints: [{domain: 'query.example.test', label: 'v2', kind: 'query', generation: 'fixture', complete: true, workers: [worker]}]};
    else if (name === 'storage') value = {components: [{name: 'Bibles', kind: 'files', bytes: 1000000000, path: '/srv/getbible'}], total_bytes: 1000000000, filesystem_available_bytes: 800000000000};
    else if (name === 'operations') value = operations;
    else if (name === 'management/state') value = managementState;
    else if (name === 'jobs') value = [{id: 'job-fixture', operation: 'token.add', status: 'succeeded', created: now}];
    else if (name === 'jobs/job-fixture') value = {id: 'job-fixture', operation: 'token.add', status: 'succeeded', created: now, output: 'Token created. Secret is available once.', secret_available: !secretRevealed};
    else if (name === 'jobs/job-fixture/reveal') {secretRevealed = true; value = {one_time_output: 'synthetic-token-do-not-use'};}
    else if (name === 'actions') {assert.equal(request.headers()['x-csrf-token'], 'fixture-csrf'); actions.push(body); value = {job_id: 'job-fixture', status: 'queued'};}
    else if (name === 'events') value = {items: [{id: 1, stamp: now, endpoint: 'query.example.test', source: 'journal', payload: {event: 'sync.completed', message: 'Fixture sync completed'}}]};
    else if (name === 'sessions') value = {sessions: [{id: 'session-fixture', ip: '192.0.2.10', user_agent: 'Fixture browser', created_at: now, expires_at: now + 2592000}]};
    else if (name === 'auth/logout') {authenticated = false; value = {authenticated: false};}
    else throw new Error(`Unexpected API route: ${name}`);
    return route.fulfill({status: 200, contentType: 'application/json', body: JSON.stringify(value)});
  }
  const relative = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
  const target = path.resolve(root, 'src/apps/dashboard/static', relative);
  assert.ok(target.startsWith(path.resolve(root, 'src/apps/dashboard/static') + path.sep));
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
  await page.getByRole('button', {name: 'Traffic', exact: true}).click();
  await page.getByText('192.0.2.10', {exact: true}).waitFor();
  await page.getByLabel('Client IP', {exact: true}).fill('192.0.2.10');
  await page.getByRole('button', {name: 'Apply filters'}).click();
  await page.getByRole('button', {name: 'Translations', exact: true}).click();
  await page.getByRole('button', {name: 'KJV', exact: true}).waitFor();
  await page.getByRole('button', {name: 'Reload', exact: true}).last().click();
  await page.getByRole('button', {name: 'Run operation'}).click();
  assert.deepEqual(actions.at(-1), {operation: 'runtime.cache', arguments: {domain: 'query.example.test', endpoint: 'v2', action: 'reload', translation: 'kjv'}, confirm: true});
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
  await page.getByLabel('Operation', {exact: true}).selectOption('pages.write');
  await page.getByLabel('domain', {exact: true}).fill('query.example.test');
  await page.getByLabel('kind', {exact: true}).selectOption('docs');
  await page.getByLabel('content', {exact: true}).fill('<h1>Fixture page</h1>');
  managementState = {refresh: {state: 'waiting', pending: true}, pending_jobs: 1, accepting_jobs: false};
  await page.getByText('Management services are updating', {exact: true}).waitFor();
  assert.equal(await page.getByRole('button', {name: 'Review operation'}).isDisabled(), true);
  managementState = {refresh: {state: 'current', pending: false}, pending_jobs: 0, accepting_jobs: true};
  await page.getByText('Management services are updating', {exact: true}).waitFor({state: 'hidden'});
  await page.getByRole('button', {name: 'Review operation'}).click();
  await page.getByRole('button', {name: 'Run operation'}).click();
  assert.equal(actions.at(-1).arguments.content, '<h1>Fixture page</h1>');
  await page.getByRole('button', {name: 'Close details'}).click();
  await page.getByRole('button', {name: 'Overview', exact: true}).click();
  await page.setViewportSize({width: 390, height: 844});
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await page.screenshot({path: path.join(root, 'test-artifacts/dashboard-mobile.png'), fullPage: true});
  await page.getByRole('button', {name: 'Toggle navigation'}).click();
  await page.getByRole('button', {name: 'Sessions', exact: true}).click();
  await page.getByText('Fixture browser', {exact: true}).waitFor();
  assert.deepEqual(failures, [], 'No browser runtime errors');
  console.log('Dashboard browser checks passed: authentication flow, charts, filters, worker actions, management forms, one-time output, themes and mobile layout.');
} catch (error) {
  await fs.mkdir(path.join(root, 'test-artifacts'), {recursive: true});
  await page.screenshot({path: path.join(root, 'test-artifacts/dashboard-failure.png'), fullPage: true});
  console.error('Browser errors:', failures);
  throw error;
} finally {
  await context.close();
  await browser.close();
}
