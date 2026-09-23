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
const reportResponses = [];
const staticRoot = process.env.DASHBOARD_STATIC_ROOT || path.join(root, 'src/apps/dashboard/static');
let jobStatus = 'succeeded';
let jobFailures = 0;
let dashboardState = {state: 'awake', viewers: 1};
let authenticated = false;
let secretRevealed = false;
let managementState = {refresh: {state: 'current', pending: false}, pending_jobs: 0, accepting_jobs: true};
const now = Math.floor(Date.now() / 1000);
const metric = {stamp: now, cpu: {capacity: 2, used_fraction: 0.34, counters: {throttled_usec: 500}}, memory: {current_bytes: 3 * 1073741824, limit_bytes: 4 * 1073741824, events: {oom_kill: 0}}, temperatures: [{sensor: 'fixture', celsius: 45}]};
const metrics = Array.from({length: 30}, (_, i) => ({...metric, stamp: now - (30 - i) * 60}));
const summary = {calls: 12000, requests_per_second: 13.4, unique_ips: 86, bytes: 73400320, errors: 24, rate_limited: 7, cache_hits: 9300, cache_hit_ratio: 0.775, latency_ms: {p50: 5, p95: 25, p99: 100, approximate: true}, latest_metrics: metric, retention: {first_request: now - 604800}, breakdowns: Object.fromEntries(Object.entries({auth: ['anonymous', 'valid', 'rejected'], endpoint: ['query.example.test', 'search.example.test'], translation: ['kjv', 'asv'], search: ['faith hope'], reference: ['John 3:16'], book: ['43'], referrer: ['https://reader.example.test/'], user_agent: ['Fixture reader/1.0'], ip: ['192.0.2.10'], status: ['200', '429']}).map(([key, values]) => [key, values.map((value, i) => ({value, calls: 6000 / (i + 1), bytes: 1048576, errors: i}))]))};
for (const [dimension, values] of Object.entries(summary.breakdowns)) for (const row of values) {
  row.filters = {[dimension]: row.value, origin_only: 'true'};
  if (['translation', 'book', 'search', 'reference'].includes(dimension)) Object.assign(row.filters, {successful: 'true', usage: dimension});
  if (['search', 'reference'].includes(dimension)) row.filters.endpoint_kind = dimension === 'search' ? 'search' : 'query';
  if (dimension === 'book') row.label = 'John';
}
// Each planned response belongs to one resource and time range. Holding a
// response lets the browser exercise concurrent loads and obsolete requests
// without relying on machine-dependent network delays.
function planReport(name, seconds, body, {status = 200, hold = false} = {}) {
  let arrived, release, finished;
  const requested = new Promise(resolve => {arrived = resolve;});
  const gate = new Promise(resolve => {release = resolve;});
  const completed = new Promise(resolve => {finished = resolve;});
  reportResponses.push({name, seconds, body, status, arrived, gate, finished});
  if (!hold) release();
  return {requested, release, completed};
}
function historyReport(calls) {
  return {series: [{stamp: now - 60, calls, errors: 0}, {stamp: now, calls: calls + 1, errors: 1}]};
}
const reportRequestCount = () => requests.filter(name => ['/api/overview', '/api/history'].includes(name)).length;
async function renderedFlow() {
  return page.getByRole('img', {name: 'Origin requests and errors by time', exact: true}).evaluateAll(nodes => {
    const chart = nodes[0] && window.echarts?.getInstanceByDom(nodes[0]);
    return chart?.getOption().series?.[0]?.data?.[0]?.[1] ?? null;
  });
}
async function waitForFlow(calls) {
  await page.waitForFunction(expected => {
    const node = document.querySelector('[aria-label="Origin requests and errors by time"]');
    return node && window.echarts?.getInstanceByDom(node)?.getOption().series?.[0]?.data?.[0]?.[1] === expected;
  }, calls);
}
async function settleRendering() {
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
}
async function assertHistoricalReportsDoNotPoll(label) {
  const before = reportRequestCount();
  if (page.clock) await page.clock.fastForward(16000);
  else await page.waitForTimeout(16000);
  await settleRendering();
  assert.equal(reportRequestCount(), before, `${label} reports do not repeat an expensive historical query after 15 seconds`);
}
const worker = {pid: 123, rss_bytes: 134217728, private_bytes: 67108864, translation_status: {kjv: {ready: false, reason: 'Only part of the query translation is resident.'}}, cache: {ttl_seconds: 2592000, query_translations: {kjv: {chapters: 1, estimated_bytes: 17000, expired_chapters: 0}}, search_corpora: {translations: {}}}};
const mcpRequests = [
  {id: 15, mcp_method: 'initialize', mcp_outcome: 'success', mcp_client_name: 'Fixture MCP client', mcp_client_version: '2.0', duration_ms: 4},
  {id: 14, mcp_method: 'tools/call', mcp_tool: 'call_api_operation', mcp_outcome: 'success', upstream_service: 'api', upstream_api_version: 'v3', upstream_operation: 'getChapter', duration_ms: 12},
  {id: 13, mcp_method: 'tools/call', mcp_tool: 'call_api_operation', mcp_outcome: 'tool_error', upstream_service: 'api', upstream_api_version: 'v3', upstream_operation: 'getChapter', mcp_error: true, duration_ms: 20},
  {id: 12, mcp_method: 'resources/read', mcp_outcome: 'unknown', duration_ms: 100},
  {id: 11, status: 403, method: 'GET', user_agent: 'FixtureCrawler/1.0', mcp_error: true, duration_ms: 1},
].map(row => ({stamp: now, endpoint: 'mcp.example.test', endpoint_kind: 'mcp', version: '', method: 'POST', path: '/',
  status: 200, remote_addr: '192.0.2.20', auth: 'anonymous', user_agent: 'FixtureMCP/2.0', referrer: '', ...row}));
const mcpDimensions = ['endpoint', 'mcp_method', 'mcp_tool', 'mcp_client_name', 'mcp_client_version', 'mcp_outcome',
  'upstream_service', 'upstream_api_version', 'upstream_operation', 'status', 'user_agent', 'referrer'];
const failedMcp = row => row.status >= 400 || row.mcp_error === true;
function selectedMcpRows(params) {
  return mcpRequests.filter(row => mcpDimensions.every(key => !params.get(key) || String(row[key] ?? '') === params.get(key)) &&
    (!params.get('user_agent_contains') || row.user_agent.includes(params.get('user_agent_contains'))));
}
function mcpReport(params) {
  const rows = selectedMcpRows(params);
  const filters = {...Object.fromEntries(params), endpoint_kind: 'mcp', origin_only: 'true'};
  for (const key of ['start', 'end', 'top', 'bucket_seconds']) delete filters[key];
  const breakdowns = Object.fromEntries(mcpDimensions.map(dimension => [dimension,
    [...new Set(rows.map(row => row[dimension]).filter(value => value !== undefined && value !== ''))].map(value => {
      const matching = rows.filter(row => row[dimension] === value);
      return {value, calls: matching.length, errors: matching.filter(failedMcp).length, bytes: 1024,
        duration_ms: matching.reduce((sum, row) => sum + row.duration_ms, 0) / matching.length,
        filters: {...filters, [dimension]: value}};
    })]));
  return {calls: rows.length, mcp_requests: rows.length, mcp_errors: rows.filter(failedMcp).length, errors: rows.filter(failedMcp).length,
    http_errors: rows.filter(row => row.status >= 400).length, mcp_tool_calls: rows.filter(row => row.mcp_method === 'tools/call').length,
    unique_ips: 1, duration_ms: rows.reduce((sum, row) => sum + row.duration_ms, 0) / Math.max(1, rows.length),
    latency_ms: {p95: 100}, filters, breakdowns,
    series: rows.map((row, index) => ({stamp: now - (rows.length - index) * 60, calls: 1, errors: failedMcp(row) ? 1 : 0, duration_ms: row.duration_ms}))};
}
const searchWorker = {...worker, translation_status: {kjv: {ready: true}}, cache: {...worker.cache, search_corpora: {translations: {kjv: {verses: 31102, estimated_bytes: 34000000, indexes: [{case_sensitive: false, fold_diacritics: true}]}}}, translation_cache: {translations: {kjv: {estimated_bytes: 13000000}}}}};
const inventory = {domains: [{domain: 'mcp.example.test', type: 'mcp', kind: 'mcp', live: true, settings: {ACCESS_MODE: 'open'}}], endpoints: [{domain: 'query.example.test', label: 'v2', type: 'runtime', kind: 'query', live: true, settings: {ACCESS_MODE: 'open'}, endpoint_settings: {WORKERS: '9', MEMORY_TTL: '30d'}}]};
const upgradePlan = {format: 1, plan_id: 'a'.repeat(64), version: '3.2.0', pending: 2, state: 'pending', note: 'Static synchronization is separate.', targets: [
  {id: 'management', kind: 'management', status: 'pending', eligible: true, serving: 'ready', outcome: 'failed', reason: 'Retry failed upgrade'},
  {id: 'runtime/query.example.test/v2', kind: 'runtime', status: 'pending', eligible: true, serving: 'ready', outcome: 'applied', reason: 'Implementation changed'},
  {id: 'mcp/mcp.example.test', kind: 'mcp', status: 'current', eligible: false, serving: 'ready', outcome: 'applied', reason: 'Current'},
  {id: 'static/api.example.test', kind: 'static', status: 'current', eligible: false, serving: 'ready', outcome: 'applied', reason: 'Current'},
]};
const capacityFixture = {state: 'observed', stale: false, sampled_at: now, window_seconds: 86400, headroom_fraction: .25,
  note: 'Peak demand with explicit headroom; no limits change automatically.',
  collection: {state: 'catching_up', unread_bytes: 1048576, unread_files: 2, budgeted_spool_bytes: 2000000000,
    retained_archive_bytes: 10000000000, producer_bytes_per_second: 1048576, collector_bytes_per_second: 2097152,
    backlog_growth_bytes_per_second: -1048576, backlog_observed_seconds: 120, rate_window_seconds: 300},
  limits: [{id: 'telemetry_spool', label: 'Telemetry transport', setting: 'TELEMETRY_SPOOL_MAX_GIB', unit: 'GiB', available: true,
    used: 1.8, effective_limit: 1, high_water: 2, samples: 60, observed_seconds: 300, saturated_samples: 45, saturated_seconds: 225,
    episodes: 2, saturation_threshold: .9, configuration: {owner: 'saved', value: '1', editable: true},
    recommendation: {status: 'suggested', value: 3, reason: 'Observed peak with 25% headroom.'}}],
  incidents: [{id: 'telemetry_spool', since: now - 120, last_sent: now - 60, last_event: 'onset'}]};
const operations = [
  {id: 'system.update', title: 'Upgrade selected targets', fields: [{name: 'targets', type: 'upgrade_targets', required: true}, {name: 'plan_id', type: 'plan_id', required: true}]},
  {id: 'settings.set', title: 'Set a system configuration value', fields: [{name: 'key', required: true}, {name: 'value', required: true}]},
  {id: 'runtime.cache', title: 'Manage translation memory', fields: [{name: 'domain', type: 'domain', required: true}, {name: 'endpoint', required: true}, {name: 'action', choices: ['warm', 'drop', 'reload'], required: true}, {name: 'translation', required: true}]},
  {id: 'pages.write', title: 'Edit page content', fields: [{name: 'domain', required: true}, {name: 'kind', choices: ['docs', 'openapi'], required: true}, {name: 'content', type: 'multiline', required: true}]},
  {id: 'runtime.set', title: 'Set runtime endpoint configuration', fields: [{name: 'domain', required: true}, {name: 'endpoint'}, {name: 'key', choices: ['WORKERS', 'MEMORY_TTL'], required: true}, {name: 'value', required: true}]},
  {id: 'logs.view', title: 'View diagnostics', fields: [{name: 'domain', required: true}]},
  {id: 'logs.reset', title: 'Start fresh traffic history', description: 'Discard recorded requests and begin a fresh history.', fields: []},
  {id: 'token.add', title: 'Issue an API token', secret_output: true, fields: [{name: 'domain', required: true}, {name: 'label', required: true}]},
  {id: 'mcp.status', title: 'MCP service status', mutates: false, domain_types: ['mcp'], fields: [{name: 'domain', required: true}]},
  {id: 'mcp.update', title: 'Update MCP service', domain_types: ['mcp'], fields: [{name: 'domain', required: true}]},
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
    const planned = reportResponses.findIndex(response => response.name === name && response.seconds === Number(url.searchParams.get('end')) - Number(url.searchParams.get('start')));
    if (planned >= 0) {
      const response = reportResponses.splice(planned, 1)[0];
      response.arrived();
      await response.gate;
      try {
        await route.fulfill({status: response.status, contentType: response.status >= 400 ? 'application/problem+json' : 'application/json', body: JSON.stringify(response.body)});
      } finally {response.finished();}
      return;
    }
    if (name === 'jobs/job-fixture' && jobFailures > 0) {jobFailures -= 1; return route.fulfill({status: 503, contentType: 'application/problem+json', body: JSON.stringify({detail: 'The dashboard is restarting.'})});}
    if (name === 'auth/status') value = {authenticated, telegram_configured: true, ...(authenticated ? {csrf_token: 'fixture-csrf'} : {})};
    else if (name === 'auth/password') {assert.equal(body.password, 'fixture-password-only'); value = {challenge_id: 'fixture-challenge', expires_in: 60};}
    else if (name === 'auth/token') {assert.equal(body.token, 'fixture-one-use-code'); authenticated = true; value = {authenticated: true, csrf_token: 'fixture-csrf'};}
    else if (name === 'dashboard/heartbeat') {heartbeatRequests.push(body); value = dashboardState;}
    else if (name === 'dashboard/state') value = dashboardState;
    else if (name === 'overview') value = summary;
    else if (name === 'mcp') {assert.equal(url.searchParams.get('endpoint_kind'), 'mcp'); value = mcpReport(url.searchParams);}
    else if (name === 'audience') {const breakdowns = url.searchParams.get('endpoint_kind') === 'mcp' ? mcpReport(url.searchParams).breakdowns : summary.breakdowns; value = {referrers: breakdowns.referrer, user_agents: breakdowns.user_agent};}
    else if (name === 'endpoints') value = inventory;
    else if (name === 'history') value = {series: Array.from({length: 30}, (_, i) => ({stamp: now - (30 - i) * 60, calls: 100 + i * 10, errors: i % 3}))};
    else if (name === 'capacity') value = capacityFixture;
    else if (name === 'upgrades') value = upgradePlan;
    else if (name === 'metrics') value = {metrics, retention: summary.retention};
    else if (name === 'requests') value = {items: url.searchParams.get('endpoint_kind') === 'mcp' ? selectedMcpRows(url.searchParams) : [{id: 1, stamp: now, endpoint: 'query.example.test', version: 'v2', method: 'GET', path: '/v2/kjv/43/3.json', status: 200, duration_ms: 2, remote_addr: '192.0.2.10', auth: 'valid', referrer: 'https://reader.example.test/', user_agent: 'Fixture reader/1.0'}], next_cursor: null};
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
  // The manager deploys its favicon separately from the dashboard bundle.
  if (url.pathname === '/favicon.png') return route.fulfill({status: 200, contentType: 'image/svg+xml',
    body: '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><rect width="40" height="40" rx="8" fill="#38bdf8"/><text x="6" y="28" font-size="23" fill="#0b1422">gB</text></svg>'});
  const relative = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
  const target = path.resolve(staticRoot, relative);
  assert.ok(target.startsWith(path.resolve(staticRoot) + path.sep));
  const type = {'.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png'}[path.extname(target)] || 'application/octet-stream';
  return route.fulfill({status: 200, contentType: type, headers: {'Content-Security-Policy': "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"}, body: await fs.readFile(target)});
});

try {
  if (page.clock) await page.clock.install();
  await page.goto('https://dashboard.example.test/');
  await page.getByLabel('Password', {exact: true}).fill('fixture-password-only');
  await page.getByRole('button', {name: 'Continue with Telegram'}).click();
  await page.getByLabel('Telegram code', {exact: true}).fill('fixture-one-use-code');
  await page.getByRole('button', {name: 'Verify and open dashboard'}).click();
  await page.getByRole('heading', {name: 'Traffic & performance'}).waitFor();
  await page.getByText('12,000', {exact: true}).waitFor();
  await waitForFlow(100);
  for (const label of ['Origin requests and errors by time', 'Anonymous, authenticated and rejected request breakdown']) {
    await page.getByRole('img', {name: label, exact: true}).locator('canvas').waitFor({state: 'visible'});
  }
  assert.ok(await page.locator('canvas').count() >= 2, 'ECharts renders the request and access charts');
  assert.ok(heartbeatRequests.length > 0, 'Authenticated viewer keeps reporting awake');
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await fs.mkdir(path.join(root, 'test-artifacts'), {recursive: true});
  await page.screenshot({path: path.join(root, 'test-artifacts/dashboard-dark.png'), fullPage: true});
  await page.getByLabel('Color theme').selectOption('light');
  assert.equal(await page.locator('html').getAttribute('data-bs-theme'), 'light');
  await page.screenshot({path: path.join(root, 'test-artifacts/dashboard-light.png'), fullPage: true});
  await assertHistoricalReportsDoNotPoll('24-hour');

  const weekSummary = planReport('overview', 604800, {...summary, calls: 700007}, {hold: true});
  planReport('history', 604800, historyReport(701));
  await page.getByLabel('Time range', {exact: true}).selectOption('7 days');
  await weekSummary.requested;
  await page.getByText('12,000', {exact: true}).waitFor({state: 'hidden'});
  await waitForFlow(701);
  assert.equal(await page.getByText('700,007', {exact: true}).count(), 0, 'Seven-day request flow is usable while its summary is still loading');
  weekSummary.release();
  await page.getByText('700,007', {exact: true}).waitFor();
  await assertHistoricalReportsDoNotPoll('Seven-day');

  planReport('overview', 2592000, {...summary, calls: 3000030});
  const monthHistory = planReport('history', 2592000, historyReport(3001), {hold: true});
  await page.getByLabel('Time range', {exact: true}).selectOption('30 days');
  await monthHistory.requested;
  await page.getByText('3,000,030', {exact: true}).waitFor();
  assert.notEqual(await renderedFlow(), 701, 'Changing range clears the old chart while the new request flow is loading');
  monthHistory.release();
  await waitForFlow(3001);
  await assertHistoricalReportsDoNotPoll('Thirty-day');

  const staleSummary = planReport('overview', 604800, {...summary, calls: 999999}, {hold: true});
  const staleHistory = planReport('history', 604800, historyReport(9999), {hold: true});
  await page.getByLabel('Time range', {exact: true}).selectOption('7 days');
  await Promise.all([staleSummary.requested, staleHistory.requested]);
  await page.getByText('3,000,030', {exact: true}).waitFor({state: 'hidden'});
  assert.notEqual(await renderedFlow(), 3001, 'Neither previous-range panel stays visible while replacement requests are pending');
  planReport('overview', 2592000, {...summary, calls: 3100030});
  planReport('history', 2592000, historyReport(3101));
  await page.getByLabel('Time range', {exact: true}).selectOption('30 days');
  await page.getByText('3,100,030', {exact: true}).waitFor();
  await waitForFlow(3101);
  staleSummary.release(); staleHistory.release();
  await Promise.all([staleSummary.completed, staleHistory.completed]);
  await settleRendering();
  assert.equal(await page.getByText('3,100,030', {exact: true}).count(), 1, 'A late summary cannot overwrite the newly selected range');
  assert.equal(await renderedFlow(), 3101, 'A late request-flow result cannot overwrite the newly selected range');

  planReport('overview', 604800, {state: 'preparing', retry_after: 2, progress: {processed: 100, total: 200}}, {status: 202});
  const preparedSummary = planReport('overview', 604800, {...summary, calls: 700007}, {hold: true});
  planReport('history', 604800, historyReport(701));
  await page.getByLabel('Time range', {exact: true}).selectOption('7 days');
  await waitForFlow(701);
  const flowRequestsWhilePreparing = requests.filter(name => name === '/api/history').length;
  await preparedSummary.requested;
  await page.getByRole('status').getByText('Preparing request totals for this time range…', {exact: true}).waitFor();
  assert.equal(await renderedFlow(), 701, 'A ready chart remains visible during summary preparation');
  assert.equal(requests.filter(name => name === '/api/history').length, flowRequestsWhilePreparing, 'Preparation retries only the unfinished report');
  preparedSummary.release();
  await page.getByText('700,007', {exact: true}).waitFor();

  const summaryFailure = 'Synthetic summary failure. Request flow is still available.';
  planReport('overview', 2592000, {detail: summaryFailure}, {status: 503});
  planReport('history', 2592000, historyReport(3001));
  await page.getByLabel('Time range', {exact: true}).selectOption('30 days');
  await page.getByText(`Request totals: ${summaryFailure}`, {exact: true}).waitFor();
  await waitForFlow(3001);
  const recoveredSummary = planReport('overview', 2592000, {...summary, calls: 3000030}, {hold: true});
  planReport('history', 2592000, historyReport(3001));
  await page.getByRole('button', {name: 'Refresh all', exact: true}).click();
  await recoveredSummary.requested;
  await page.getByText(`Request totals: ${summaryFailure}`, {exact: true}).waitFor({state: 'hidden'});
  recoveredSummary.release();
  await page.getByText('3,000,030', {exact: true}).waitFor();

  const flowFailure = 'Synthetic request-flow failure. The summary is still available.';
  planReport('overview', 604800, {...summary, calls: 700007});
  planReport('history', 604800, {detail: flowFailure}, {status: 503});
  await page.getByLabel('Time range', {exact: true}).selectOption('7 days');
  await page.getByText('700,007', {exact: true}).waitFor();
  await page.locator('.panel').filter({has: page.getByRole('heading', {name: 'Request flow', exact: true})}).getByText(`Request flow: ${flowFailure}`, {exact: true}).waitFor();
  planReport('overview', 604800, {...summary, calls: 700007});
  planReport('history', 604800, historyReport(701));
  await page.getByRole('button', {name: 'Refresh all', exact: true}).click();
  await waitForFlow(701);
  await page.getByText(`Request flow: ${flowFailure}`, {exact: true}).waitFor({state: 'hidden'});

  await page.getByLabel('Time range', {exact: true}).selectOption('Live');
  await page.getByText('12,000', {exact: true}).waitFor();
  await waitForFlow(100);
  const nextLiveSummary = page.waitForResponse(response => new URL(response.url()).pathname === '/api/overview');
  const nextLiveHistory = page.waitForResponse(response => new URL(response.url()).pathname === '/api/history');
  if (page.clock) await page.clock.fastForward(2100);
  await Promise.all([nextLiveSummary, nextLiveHistory]);
  await page.getByLabel('Time range', {exact: true}).selectOption('24 hours');
  await page.getByText('12,000', {exact: true}).waitFor();
  await waitForFlow(100);
  assert.equal(reportResponses.length, 0, 'Every planned reporting response was exercised');
  const overviewRequestsBeforeNavigation = reportRequestCount();
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
  await page.getByLabel('Search recorded request data', {exact: true}).fill('reader');
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
  await page.getByRole('button', {name: 'MCP traffic', exact: true}).click();
  await page.getByRole('heading', {name: 'MCP requests and errors', exact: true}).waitFor();
  await page.locator('.metric').filter({has: page.getByText('MCP requests', {exact: true})}).getByText('5', {exact: true}).waitFor();
  assert.equal(await page.locator('.metric').filter({has: page.getByText('Errors', {exact: true})}).locator('strong').textContent(), '2', 'HTTP and protocol errors share the MCP error total');
  await page.locator('canvas').nth(1).waitFor();
  await page.getByText('Fixture MCP client', {exact: true}).waitFor();
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await page.screenshot({path: path.join(root, 'test-artifacts/dashboard-mcp.png'), fullPage: true});
  const mcpDomains = page.locator('.panel').filter({has: page.getByRole('heading', {name: 'MCP domains', exact: true})});
  await mcpDomains.getByRole('button', {name: 'mcp.example.test', exact: true}).click();
  await page.getByRole('cell', {name: 'tool error', exact: true}).waitFor();
  const protocolFailure = page.getByRole('row').filter({has: page.getByRole('cell', {name: 'tool error', exact: true})});
  assert.equal(await protocolFailure.locator('.status-badge.warning').filter({hasText: /^200$/}).count(), 1, 'HTTP 200 tool errors are visibly marked');
  assert.equal(await page.getByLabel('Version', {exact: true}).count(), 0, 'MCP has no hosted API-version selector');
  const unknownOutcome = page.getByRole('row').filter({has: page.getByRole('cell', {name: 'unknown', exact: true})});
  assert.equal(await unknownOutcome.locator('.status-badge.muted').count(), 1, 'Unknown streamed outcomes remain unknown');
  assert.equal(requestQueries.filter(request => request.name === '/api/requests').at(-1).query.endpoint, 'mcp.example.test');
  await page.getByRole('button', {name: 'MCP traffic', exact: true}).click();
  await page.getByRole('heading', {name: 'Upstream API operations', exact: true}).waitFor();
  await page.getByRole('button', {name: /^endpoint_kind: mcp/}).click();
  const upstreamOperations = page.locator('.panel').filter({has: page.getByRole('heading', {name: 'Upstream API operations', exact: true})});
  await upstreamOperations.getByRole('button', {name: 'getChapter', exact: true}).click();
  await page.getByLabel('Upstream operation', {exact: true}).waitFor();
  const operationQuery = requestQueries.filter(request => request.name === '/api/requests').at(-1).query;
  assert.equal(operationQuery.upstream_operation, 'getChapter');
  assert.equal(operationQuery.endpoint, 'mcp.example.test', 'Removing the service chip preserves domain scope through drilldown');
  assert.equal(operationQuery.endpoint_kind, 'mcp');
  assert.equal(operationQuery.version, undefined);
  await page.getByRole('button', {name: 'Clear all', exact: true}).click();
  await page.getByRole('button', {name: 'MCP traffic', exact: true}).click();
  const mcpAgents = page.locator('.panel').filter({has: page.getByRole('heading', {name: 'User agents and robots', exact: true})});
  await mcpAgents.getByLabel('Find user agent', {exact: true}).fill('Crawler');
  await mcpAgents.getByRole('button', {name: 'Search', exact: true}).click();
  await mcpAgents.getByRole('button', {name: 'FixtureCrawler/1.0', exact: true}).click();
  await page.getByRole('cell', {name: '403', exact: true}).waitFor();
  assert.equal(requestQueries.filter(request => request.name === '/api/requests').at(-1).query.user_agent, 'FixtureCrawler/1.0', 'Rejected robot requests remain discoverable');
  await page.getByLabel('Endpoint kind', {exact: true}).selectOption('');
  await page.getByRole('button', {name: 'Apply filters'}).click();
  await page.getByRole('button', {name: /^endpoint_kind: mcp/}).waitFor({state: 'hidden'});
  assert.equal(requestQueries.filter(request => request.name === '/api/requests').at(-1).query.endpoint_kind, undefined);
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
  await page.getByRole('heading', {name: 'Capacity and sizing advice', exact: true}).waitFor();
  await page.getByText('Telemetry transport', {exact: true}).waitFor();
  const beforeAdvice = actions.length;
  await page.getByRole('button', {name: 'Review suggested setting', exact: true}).click();
  assert.equal(actions.length, beforeAdvice, 'Displaying a sizing recommendation never changes a limit');
  await page.getByRole('button', {name: 'Run operation'}).click();
  await page.getByRole('dialog').getByText('succeeded', {exact: true}).waitFor();
  assert.deepEqual(actions.at(-1), {operation: 'settings.set', arguments: {key: 'TELEMETRY_SPOOL_MAX_GIB', value: '3'}, confirm: true});
  await page.getByRole('button', {name: 'Close details'}).click();
  await page.screenshot({path: path.join(root, 'test-artifacts/dashboard-capacity.png'), fullPage: true});

  assert.ok(requests.includes('/api/metrics'), 'Resource charts load their independent metrics endpoint');
  for (const [label, expected] of [['CPU usage over time', 34], ['Memory usage over time', 3]]) {
    const chart = page.getByRole('img', {name: label, exact: true});
    await chart.locator('canvas').waitFor();
    const points = await chart.evaluate(node => window.echarts.getInstanceByDom(node).getOption().series[0].data);
    assert.equal(points.length, metrics.length, `${label} plots the metric series`);
    assert.equal(points.at(-1)[1], expected, `${label} uses the latest independent metrics value`);
  }
  assert.equal(reportRequestCount(), overviewRequestsBeforeNavigation, 'Traffic, audience, MCP, translations and resources do not load hidden overview reports');
  await page.getByRole('button', {name: 'Events', exact: true}).click();
  await page.getByText('Fixture sync completed', {exact: true}).waitFor();
  await page.getByRole('navigation', {name: 'Main navigation'}).getByRole('button', {name: 'Manage', exact: true}).click();
  await page.getByRole('button', {name: /Upgrade targets Review changes/}).click();
  await page.getByLabel('Upgrade management', {exact: true}).waitFor();
  assert.equal(await page.getByLabel('Upgrade management', {exact: true}).isChecked(), true);
  assert.equal(await page.getByLabel('Upgrade static/api.example.test', {exact: true}).isDisabled(), true, 'Unchanged static code is not eligible without an explicit force');
  await page.getByRole('button', {name: 'Clear selection', exact: true}).click();
  assert.equal(await page.getByRole('button', {name: 'Review selected upgrades', exact: true}).isDisabled(), true, 'Empty selections cannot become upgrade-all');
  await page.getByLabel('Upgrade runtime/query.example.test/v2', {exact: true}).check();
  await page.screenshot({path: path.join(root, 'test-artifacts/dashboard-upgrades.png'), fullPage: true});
  await page.getByRole('button', {name: 'Review selected upgrades', exact: true}).click();
  await page.getByRole('button', {name: 'Run operation'}).click();
  await page.getByRole('dialog').getByText('succeeded', {exact: true}).waitFor();
  assert.deepEqual(actions.at(-1), {operation: 'system.update', arguments: {targets: ['runtime/query.example.test/v2'], plan_id: upgradePlan.plan_id, force: false, retry: false}, confirm: true});
  await page.getByRole('button', {name: 'Close details'}).click();
  await page.getByRole('navigation', {name: 'Main navigation'}).getByRole('button', {name: 'Manage', exact: true}).click();
  await page.getByRole('button', {name: /Domains Status, endpoints/}).click();
  await page.getByRole('button', {name: /mcp.example.test.*MCP at \//}).click();
  assert.equal(await page.getByRole('button', {name: /Runtime settings|Pages and OpenAPI|Endpoints and repositories/}).count(), 0, 'MCP domains expose no Bible endpoint or generated-page controls');
  await page.getByRole('button', {name: /MCP service MCP service status/}).click();
  await page.getByRole('button', {name: 'Update MCP service', exact: true}).click();
  assert.equal(await page.getByLabel('endpoint', {exact: true}).count(), 0);
  await page.screenshot({path: path.join(root, 'test-artifacts/dashboard-mcp-management.png'), fullPage: true});
  await page.getByRole('button', {name: 'Review operation'}).click();
  await page.getByRole('button', {name: 'Run operation'}).click();
  await page.getByRole('dialog').getByText('succeeded', {exact: true}).waitFor();
  assert.deepEqual(actions.at(-1), {operation: 'mcp.update', arguments: {domain: 'mcp.example.test'}, confirm: true});
  await page.getByRole('button', {name: 'Close details'}).click();
  await page.getByRole('navigation', {name: 'Management navigation'}).getByRole('button', {name: 'Domains', exact: true}).click();
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
  assert.equal(reportRequestCount(), overviewRequestsBeforeNavigation, 'Event and management actions do not refresh hidden overview reports');
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
  console.log('Dashboard browser checks passed: authentication flow, independent historical reports and preparation, stale-response cancellation, local failures and refresh recovery, Live-only report polling, independent resource metrics, charts, scoped rankings, MCP traffic/errors/clients/robots/operations, dedicated MCP domain controls, audience filters, translation/worker layers, CLI menu navigation, waiting jobs, one-time output, themes and mobile layout.');
} catch (error) {
  await fs.mkdir(path.join(root, 'test-artifacts'), {recursive: true});
  await page.screenshot({path: path.join(root, 'test-artifacts/dashboard-failure.png'), fullPage: true});
  console.error('Browser errors:', failures);
  throw error;
} finally {
  await context.close();
  await browser.close();
}
