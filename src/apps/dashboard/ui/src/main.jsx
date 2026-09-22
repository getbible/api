import React, { useCallback, useEffect, useId, useMemo, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { api, post, query, number, bytes, date, setCsrf } from './api.js';
import { Chart, lineOption, donutOption } from './charts.jsx';
import './style.css';
import { ErrorNotice, Empty, Busy, Panel, Badge, Meter, DataTable } from './components.jsx';
import Management from './management.jsx';
import Capacity from './capacity.jsx';
import Translations from './translations.jsx';
import Audience from './audience.jsx';
import McpTraffic from './analytics-mcp.jsx';
import {useReports, ReportState} from './reporting.jsx';
import {rankingFilters, activeJob, editTrafficFilter, mcpDimensions, mcpOutcomes, mcpFilters, requestFailed} from './analytics.js';
const pages = ['Overview', 'Traffic', 'MCP traffic', 'Audience', 'Translations', 'Resources', 'Events', 'Manage', 'Sessions'];
const durations = { 'Live': 900, '24 hours': 86400, '7 days': 604800, '30 days': 2592000, '6 months': 15552000 };
const array = (value, key) => Array.isArray(value) ? value : value?.[key] ?? value?.items ?? [];
function Detail({ title, value, onClose, children }) {
    const ref = useRef(null);
    const id = useId();
    useEffect(() => {
        const modal = new window.bootstrap.Modal(ref.current);
        const close = () => onClose();
        ref.current.addEventListener('hidden.bs.modal', close);
        modal.show();
        return () => { ref.current?.removeEventListener('hidden.bs.modal', close); modal.hide(); modal.dispose(); };
    }, []);
    return <div ref={ref} className="modal" tabIndex="-1" aria-labelledby={id}><div className="modal-dialog modal-xl modal-dialog-scrollable"><div className="modal-content"><div className="modal-header"><h2 className="modal-title fs-5" id={id}>{title}</h2><button className="btn-close" data-bs-dismiss="modal" aria-label="Close details"/></div><div className="modal-body">{children || <pre className="record-detail">{JSON.stringify(value, null, 2)}</pre>}</div></div></div></div>;
}
function Login({ onLogin }) {
    const [password, setPassword] = useState('');
    const [token, setToken] = useState('');
    const [challenge, setChallenge] = useState(null);
    const [remaining, setRemaining] = useState(60);
    const [error, setError] = useState(null);
    const [busy, setBusy] = useState(false);
    const [blocked, setBlocked] = useState(false);
    useEffect(() => {
        if (!challenge)
            return;
        const timer = setInterval(() => setRemaining(Math.max(0, Math.ceil((challenge.deadline - Date.now()) / 1000))), 250);
        return () => clearInterval(timer);
    }, [challenge]);
    async function submit(event) {
        event.preventDefault();
        setError(null);
        setBusy(true);
        try {
            if (!challenge) {
                const result = await post('auth/password', { password });
                setPassword('');
                setChallenge({ ...result, deadline: Date.now() + result.expires_in * 1000 });
            }
            else {
                await post('auth/token', { challenge_id: challenge.challenge_id, token });
                setToken('');
                onLogin(await api('auth/status'));
            }
        }
        catch (e) {
            setError(e);
            if (e.status === 403 || e.status === 423)
                setBlocked(true);
        }
        finally {
            setBusy(false);
        }
    }
    return <main className="login-page"><div className="login-brand"><img src="/favicon.png" alt=""/><span>getBible</span><small>OPERATIONS</small></div><section className="login-box panel"><span className="eyebrow">PRIVATE CONSOLE</span><h1>{challenge ? 'Check Telegram' : 'Sign in to your server'}</h1><p>{challenge ? 'Enter the one-use code sent to your configured Telegram group.' : 'Your password and a Telegram code protect access to this console.'}</p><ErrorNotice error={error}/><form onSubmit={submit}><label className="form-label" htmlFor="credential">{challenge ? 'Telegram code' : 'Password'}</label><input autoFocus className="form-control form-control-lg" id="credential" type={challenge ? 'text' : 'password'} autoComplete={challenge ? 'one-time-code' : 'current-password'} spellCheck="false" autoCapitalize="none" value={challenge ? token : password} disabled={busy || blocked} onChange={e => challenge ? setToken(e.target.value) : setPassword(e.target.value)} required/>{challenge && <div className={`mt-3 ${remaining < 15 ? 'text-danger' : 'text-secondary'}`} aria-live="polite">{remaining ? `${remaining}s remaining` : 'Code expired. Unblock your IP through the CLI to try again.'}</div>}<button className="btn btn-primary w-100 mt-4" disabled={busy || blocked || (challenge && !remaining)}>{busy ? 'Please wait…' : challenge ? 'Verify and open dashboard' : 'Continue with Telegram'}</button></form><p className="login-note">{challenge ? 'An incorrect or expired code blocks this IP until it is unblocked through the CLI.' : 'Three incorrect passwords block this IP. Successful sessions last up to 30 days.'}</p></section><small className="text-secondary">Traffic recording continues while this console is asleep.</small></main>;
}
function Ranking({ rows = [], label, onSelect }) {
    const max = Math.max(1, ...rows.map(r => r.calls));
    return rows.length ? <div className="rankings">{rows.slice(0, 8).map((row, i) => <button key={`${row.value}-${i}`} className="ranking" onClick={() => onSelect?.(row.value, row)}><span className="rank-index">{String(i + 1).padStart(2, '0')}</span><span className="rank-name" title={String(row.label || row.value)}>{row.label || row.value || 'Unspecified'}<Meter value={row.calls} max={max} label={`${label}: ${row.value}`}/></span><strong>{number(row.calls)}</strong></button>)}</div> : <Empty />;
}
function Overview({ overview, timeline, onFilter, onDetail, onZoom }) {
    const summary = overview.data || {};
    const history = timeline.data || {};
    const b = summary.breakdowns || {};
    const metrics = summary.latest_metrics || {};
    const cards = [
        ['Origin requests', number(summary.calls), `${number(summary.unique_ips)} unique IPs`],
        ['Request rate', number(summary.requests_per_second, 1), 'requests / second'],
        ['P95 latency', summary.latency_ms?.p95 == null ? '—' : `${number(summary.latency_ms.p95, 1)} ms`, 'histogram estimate'],
        ['Cache hit rate', summary.cache_hit_ratio == null ? '—' : `${number(summary.cache_hit_ratio * 100, 1)}%`, `${number(summary.cache_hits)} origin cache hits`],
        ['Errors', number(summary.errors), `${number(summary.rate_limited)} rate limited`],
    ];
    return <><ReportState report={overview} label="Request totals"><div className="metric-grid">{cards.map(([name, value, detail]) => <div className="metric panel" key={name}><span>{name}</span><strong>{value}</strong><small>{detail}</small></div>)}</div></ReportState><div className="overview-grid"><Panel className="flow-panel" title="Request flow" detail="Origin traffic over the selected period" actions={<Badge tone="info">{bytes(summary.bytes)} transferred</Badge>}><ReportState report={timeline} label="Request flow"><Chart label="Origin requests and errors by time" height={310} onZoom={onZoom} option={lineOption(history.series || [], [['calls', 'Requests'], ['errors', 'Errors']], { zoom: true })}/></ReportState></Panel>{overview.data && <><Panel title="Access breakdown" detail="Credential state at the origin"><Chart label="Anonymous, authenticated and rejected request breakdown" option={donutOption(b.auth || [])} height={310}/></Panel><Panel className="endpoints-panel" title="API endpoints" detail="Select an endpoint to inspect its traffic"><DataTable rows={b.endpoint || b.domain || []} onSelect={row => onFilter('endpoint', row.value, row.filters)} columns={[{ key: 'value', label: 'Endpoint' }, { key: 'calls', label: 'Requests', render: r => number(r.calls) }, { key: 'errors', label: 'Errors', render: r => number(r.errors) }, { key: 'bytes', label: 'Transfer', render: r => bytes(r.bytes) }]}/></Panel><Panel title="Response codes" detail="Failures and rate limits"><Ranking rows={b.status || []} label="Response status" onSelect={(v, row) => onFilter('status', v, rankingFilters('status', row))}/></Panel><Panel title="Popular translations" detail="Successful origin requests"><Ranking rows={b.translation || []} label="Translation" onSelect={(v, row) => onFilter('translation', v, rankingFilters('translation', row))}/></Panel><Panel title="Frequent searches" detail="Successful origin requests"><Ranking rows={b.search || []} label="Search" onSelect={(v, row) => onFilter('search', v, rankingFilters('search', row))}/></Panel><Panel title="Scripture references" detail="Successful origin requests"><Ranking rows={b.reference || []} label="Reference" onSelect={(v, row) => onFilter('reference', v, rankingFilters('reference', row))}/></Panel><Panel title="Books of the Bible" detail="Successful origin requests"><Ranking rows={b.book || []} label="Book" onSelect={(v, row) => onFilter('book', v, rankingFilters('book', row))}/></Panel><Panel title="Active IP addresses" detail="Inspect high-volume origin consumers"><Ranking rows={b.ip || []} label="Client IP" onSelect={(v, row) => onFilter('ip', v, rankingFilters('ip', row))}/></Panel><Panel title="Referrers" detail="Origin requests, including errors"><Ranking rows={b.referrer || []} label="Referrer" onSelect={(v, row) => onFilter('referrer', v, row.filters)}/></Panel><Panel title="User agents" detail="Origin requests, including errors"><Ranking rows={b.user_agent || []} label="User agent" onSelect={(v, row) => onFilter('user_agent', v, row.filters)}/></Panel><Panel title="Collector health" detail="Continuous capture, independent of this dashboard"><div className="fact-list"><div><span>Available history</span><strong>{date(summary.retention?.first_request)}</strong></div><div><span>Last sample</span><strong>{date(metrics.stamp)}</strong></div><div><span>Observed scope</span><strong>Origin only</strong></div><button className="btn btn-outline-secondary btn-sm" onClick={() => onDetail('Retention and capture health', summary.retention || {})}>Retention details</button></div></Panel></>}</div></>;
}
function Traffic({ filters, setFilters, range, live, onError, onDetail }) {
    const [data, setData] = useState(null);
    const [cursor, setCursor] = useState('');
    const [previous, setPrevious] = useState([]);
    const [capturedRange, setCapturedRange] = useState(range);
    const [draft, setDraft] = useState(filters);
    useEffect(() => { setDraft(filters); setCursor(''); setPrevious([]); }, [filters]);
    useEffect(() => {
        const controller = new AbortController();
        let stopped = false;
        let timer;
        async function poll() {
            const end = live && !cursor ? Math.floor(Date.now() / 1000) : cursor ? capturedRange.end : range.end;
            const start = live && !cursor ? end - 900 : cursor ? capturedRange.start : range.start;
            try {const value = await api(`requests?${query({start, end, ...filters, cursor, limit: 100})}`, {signal: controller.signal}); if (!stopped) {setData(value); if (!cursor) setCapturedRange({start: live ? end - 900 : range.start, end});}}
            catch (e) {if (!stopped && e.name !== 'AbortError') onError(e);}
            if (!stopped && live && !cursor) timer = setTimeout(poll, 2000);
        }
        poll();
        return () => {stopped = true; clearTimeout(timer); controller.abort();};
    }, [filters, range.start, range.end, cursor, live]);
    function submit(event) { event.preventDefault(); setFilters(draft); }
    const mcpScope = draft.endpoint_kind === 'mcp';
    const requestRows = array(data, 'requests');
    const hasMcp = filters.endpoint_kind === 'mcp' || requestRows.some(row => row.endpoint_kind === 'mcp');
    const fields = [
        ['endpoint', mcpScope ? 'MCP domain' : 'Endpoint'], ['ip', 'Client IP'],
        ...(mcpScope ? mcpDimensions : [['version', 'Version'], ['translation', 'Translation'], ['reference', 'Reference'], ['search', 'Search query'], ['book', 'Book number']]),
        ['status', 'HTTP status'], ['referrer', 'Exact referrer'], ['user_agent', 'Exact user agent'],
        ['referrer_contains', 'Referrer contains'], ['user_agent_contains', 'User agent contains'],
        ['path_contains', 'Request path contains'], ['q', 'Search recorded request data'],
    ];
    return <Panel title="Request explorer" detail="Inspect recorded request details; credentials are excluded"><form className="filter-grid" onSubmit={submit}>{fields.map(([key, label]) => <label key={key}>{label}<input className="form-control form-control-sm" value={draft[key] || ''} onChange={e => setDraft(editTrafficFilter(draft, key, e.target.value))}/></label>)}<label>Endpoint kind<select aria-label="Endpoint kind" className="form-select form-select-sm" value={draft.endpoint_kind || ''} onChange={e => setDraft(editTrafficFilter(draft, 'endpoint_kind', e.target.value))}><option value="">All kinds</option><option value="static">Static API</option><option value="query">Query</option><option value="search">Search</option><option value="mcp">MCP</option></select></label>{mcpScope && <label>MCP outcome<select aria-label="MCP outcome" className="form-select form-select-sm" value={draft.mcp_outcome || ''} onChange={e => setDraft(editTrafficFilter(draft, 'mcp_outcome', e.target.value))}><option value="">All outcomes</option>{mcpOutcomes.map(value => <option key={value} value={value}>{value.replaceAll('_', ' ')}</option>)}</select></label>}<label>Responses<select aria-label="Responses" className="form-select form-select-sm" value={draft.successful || ''} onChange={e => setDraft(editTrafficFilter(draft, 'successful', e.target.value))}><option value="">All responses</option><option value="true">Successful responses</option></select></label><label>Authentication<select aria-label="Authentication" className="form-select form-select-sm" value={draft.auth || ''} onChange={e => setDraft({ ...draft, auth: e.target.value })}><option value="">All traffic</option><option value="anonymous">Anonymous</option><option value="valid">Authenticated</option><option value="rejected">Rejected credential</option></select></label><div className="d-flex gap-2 align-items-end"><button className="btn btn-primary btn-sm">Apply filters</button><button type="button" className="btn btn-outline-secondary btn-sm" onClick={() => { setDraft({}); setFilters({}); }}>Clear</button></div></form>{data ? <DataTable rows={requestRows} onSelect={r => onDetail('Request details', r)} columns={[{ key: 'timestamp', label: 'Time', render: r => date(r.stamp) }, { key: 'endpoint', label: 'Endpoint' }, { key: 'method', label: 'Method' }, { key: 'path', label: 'Request', render: r => <span className="truncate" title={r.path}>{r.path}</span> }, { key: 'status', label: 'Status', render: r => <Badge tone={requestFailed(r) ? 'warning' : 'success'}>{r.status}</Badge> }, { key: 'duration_ms', label: 'Latency', render: r => `${number(r.duration_ms, 1)} ms` }, ...(hasMcp ? [
        {key: 'mcp_method', label: 'MCP operation', render: r => r.mcp_method ? <span className="consumer-value">{r.mcp_method}{r.mcp_tool && <small className="d-block">{r.mcp_tool}</small>}{r.upstream_operation && <small className="d-block">{[r.upstream_service, r.upstream_api_version, r.upstream_operation].filter(Boolean).join(' · ')}</small>}</span> : '—'},
        {key: 'mcp_outcome', label: 'MCP outcome', render: r => r.endpoint_kind === 'mcp' ? <Badge tone={requestFailed(r) ? 'warning' : r.mcp_outcome === 'success' ? 'success' : 'muted'}>{(r.mcp_outcome || 'unknown').replaceAll('_', ' ')}</Badge> : '—'},
        {key: 'mcp_client_name', label: 'Declared MCP client', render: r => r.mcp_client_name ? <span className="consumer-value">{r.mcp_client_name}{r.mcp_client_version && <small className="d-block">{r.mcp_client_version}</small>}</span> : '—'},
    ] : []), { key: 'remote_addr', label: 'Client IP' }, { key: 'referrer', label: 'Referrer', render: r => r.referrer ? <button className="table-link truncate" title={r.referrer} onClick={() => setFilters({...filters, referrer: r.referrer})}>{r.referrer}</button> : '—' }, { key: 'user_agent', label: 'User agent', render: r => r.user_agent ? <button className="table-link truncate" title={r.user_agent} onClick={() => setFilters({...filters, user_agent: r.user_agent})}>{r.user_agent}</button> : '—' }, { key: 'auth', label: 'Auth' }]}/> : <Busy />}<div className="table-footer"><small>Latest captures first · up to 100 requests per page</small><div className="btn-group"><button className="btn btn-outline-secondary btn-sm" disabled={!previous.length} onClick={() => { setCursor(previous.at(-1)); setPrevious(previous.slice(0, -1)); }}>Previous</button><button className="btn btn-outline-secondary btn-sm" disabled={!data?.next_cursor} onClick={() => { setPrevious([...previous, cursor]); setCursor(data.next_cursor); }}>Next</button></div></div></Panel>;
}
function Events({range, live, onError, onDetail}) {
    const [data, setData] = useState(null);
    const [cursor, setCursor] = useState('');
    const [previous, setPrevious] = useState([]);
    const [capturedRange, setCapturedRange] = useState(range);
    useEffect(() => {
        let stopped = false; let timer;
        const controller = new AbortController();
        async function poll() {
            const end = live && !cursor ? Math.floor(Date.now() / 1000) : cursor ? capturedRange.end : range.end;
            try {const value = await api(`events?${query({start: live ? end - 900 : range.start, end, cursor, limit: 100})}`, {signal: controller.signal}); if (!stopped) {setData(value); if (!cursor) setCapturedRange({start: live ? end - 900 : range.start, end});}}
            catch (e) {if (!stopped && e.name !== 'AbortError') onError(e);}
            if (!stopped && live && !cursor) timer = setTimeout(poll, 2000);
        }
        poll(); return () => {stopped = true; clearTimeout(timer); controller.abort();};
    }, [range.start, range.end, live, cursor]);
    return <Panel title="Operational events" detail="Service messages, alerts, synchronization and management audit records">
        {data ? <DataTable rows={array(data, 'items')} onSelect={r => onDetail('Event details', r)} columns={[
            {key: 'stamp', label: 'Time', render: r => date(r.stamp)},
            {key: 'endpoint', label: 'Endpoint'},
            {key: 'event', label: 'Event', render: r => r.event || r.payload?.event || r.source},
            {key: 'level', label: 'Level', render: r => r.level || r.payload?.level || 'info'},
            {key: 'message', label: 'Message', render: r => <span className="truncate">{r.message || r.payload?.message || r.payload?.MESSAGE || ''}</span>},
        ]}/> : <Busy/>}
        <div className="table-footer"><small>Latest captures first</small><div className="btn-group"><button className="btn btn-sm btn-outline-secondary" disabled={!previous.length} onClick={() => {setCursor(previous.at(-1)); setPrevious(previous.slice(0, -1));}}>Previous</button><button className="btn btn-sm btn-outline-secondary" disabled={!data?.next_cursor} onClick={() => {setPrevious([...previous, cursor]); setCursor(data.next_cursor);}}>Next</button></div></div>
    </Panel>;
}

function Resources({ report, refresh, onError, onDetail, execute }) {
    const history = report.data || {};
    const [storage, setStorage] = useState(null);
    useEffect(() => {
        const controller = new AbortController();
        let stopped = false;
        api(`storage?refresh=${refresh > 0}`, {signal: controller.signal})
            .then(value => {if (!stopped) setStorage(value);})
            .catch(error => {if (!stopped && error.name !== 'AbortError') onError(error);});
        return () => {stopped = true; controller.abort();};
    }, [refresh]);
    const metric = history.metrics?.at(-1) || {};
    return <><Capacity refresh={refresh} execute={execute}/><ReportState report={report} label="Resource metrics"/><div className="resource-grid">{report.data && <><Panel title="CPU" detail={metric.scope === 'host' ? 'Host CPU utilization' : 'Usage within the container’s effective CPU allowance'}><Chart label="CPU usage over time" option={lineOption((history.metrics || []).map(row => ({ ...row, cpu_percent: row.cpu?.used_fraction == null ? null : row.cpu.used_fraction * 100 })), [['cpu_percent', 'CPU usage %']])}/><div className="fact-list"><div><span>Current utilization</span><strong>{number(metric.cpu?.used_fraction == null ? null : metric.cpu.used_fraction * 100, 1)}%</strong></div><div><span>Throttled time</span><strong>{number(metric.cpu?.counters?.throttled_usec)} μs</strong></div><div><span>Temperature</span><strong>{!metric.temperatures?.length ? 'Sensor unavailable' : `${number(Math.max(...metric.temperatures.map(t => t.celsius)), 1)} °C`}</strong></div></div></Panel><Panel title="Memory" detail={metric.scope === 'host' ? 'Host memory usage, including other services' : 'Measured container usage includes more than translation caches'}><Chart label="Memory usage over time" option={lineOption((history.metrics || []).map(row => ({ ...row, memory_gib: row.memory?.current_bytes == null ? null : row.memory.current_bytes / 1073741824 })), [['memory_gib', 'Memory GiB']])}/><div className="fact-list"><div><span>Current / limit</span><strong>{bytes(metric.memory?.current_bytes)} / {bytes(metric.memory?.limit_bytes)}</strong></div><div><span>OOM events</span><strong>{number(metric.memory?.events?.oom_kill)}</strong></div></div></Panel></>}<Panel className="wide" title="Persistent storage" detail="Mounted data on the host; application budgets do not impose a filesystem quota" actions={<button className="btn btn-sm btn-outline-secondary" onClick={() => onDetail('Storage accounting', storage)}>Inspect accounting</button>}>{storage ? <DataTable rows={array(storage, 'components')} onSelect={r => onDetail('Storage details', r)} columns={[{ key: 'name', label: 'Data', render: r => r.name || r.category || r.path }, { key: 'bytes', label: 'Allocated', render: r => bytes(r.bytes ?? r.allocated_bytes) }, { key: 'limit_bytes', label: 'Budget', render: r => r.limit_bytes ? bytes(r.limit_bytes) : '—' }, { key: 'path', label: 'Location' }]}/> : <Busy />}</Panel><Panel className="wide" title="Pressure and collection details"><div className="fact-list"><button className="btn btn-outline-secondary" onClick={() => onDetail('Latest resource sample', metric)}>Inspect latest resource sample</button><button className="btn btn-outline-secondary" onClick={() => onDetail('Retention', history.retention)}>Inspect available history and pruning</button></div></Panel></div></>;
}
function JobViewer({ initial, onError, onComplete }) {
    const [job, setJob] = useState(initial);
    const [secret, setSecret] = useState(null);
    const [copied, setCopied] = useState(false);
    const [reconnecting, setReconnecting] = useState(false);
    const reportedDone = useRef(false);
    const id = initial.job_id || initial.id;
    useEffect(() => {
        let stopped = false;
        let timer;
        let retryDelay = 1000;
        async function poll() {
            try {
                const value = await api(`jobs/${encodeURIComponent(id)}`);
                if (!stopped) {
                    setJob(value);
                    setReconnecting(false);
                    retryDelay = 1000;
                    if (!activeJob(value.status) && !reportedDone.current) {reportedDone.current = true; onComplete?.();}
                    if (activeJob(value.status))
                        timer = setTimeout(poll, 1000);
                }
            }
            catch (e) {
                if (!stopped) {
                    if (!e.status || e.status >= 500) {
                        setReconnecting(true);
                        timer = setTimeout(poll, retryDelay);
                        retryDelay = Math.min(retryDelay * 2, 10000);
                    } else onError(e);
                }
            }
        }
        poll();
        return () => { stopped = true; clearTimeout(timer); };
    }, [id]);
    async function reveal() {
        try {
            const result = await post(`jobs/${encodeURIComponent(id)}/reveal`);
            setSecret(result.one_time_output || 'The one-time output is no longer available.');
        }
        catch (e) {
            onError(e);
        }
    }
    return <>{reconnecting && <div className="alert alert-info" role="status">Reconnecting to operation progress… The accepted job continues on the server.</div>}<div className="fact-list"><div><span>Operation</span><strong>{job.operation || 'Starting…'}</strong></div><div><span>Status</span><Badge tone={job.status === 'failed' ? 'warning' : 'info'}>{job.status}</Badge></div><div><span>Started</span><strong>{job.started ? date(job.started) : 'Waiting to start'}</strong></div></div><pre className="record-detail">{job.output || 'Waiting for operation output…'}</pre>{job.secret_available && !secret && <button className="btn btn-warning" onClick={reveal}>Reveal issued credential once</button>}{secret && <div className="alert alert-warning"><p>Copy this credential now. It is shown only once and is not saved in the job history.</p><pre className="record-detail">{secret}</pre><button className="btn btn-outline-secondary" onClick={async () => { try {
        await navigator.clipboard.writeText(secret);
        setCopied(true);
    }
    catch (e) {
        onError(e);
    } }}>{copied ? 'Copied' : 'Copy credential'}</button></div>}</>;
}
function Sessions({ onError, refresh, onRefresh }) {
    const [data, setData] = useState(null);
    useEffect(() => { api('sessions').then(setData).catch(onError); }, [refresh]);
    async function revoke(id) { try {
        await post(`sessions/${encodeURIComponent(id)}/revoke`);
        onRefresh();
    }
    catch (e) {
        onError(e);
    } }
    return <Panel title="Browser sessions" detail="Sleep preserves sessions. Revoking one requires that browser to authenticate again.">{data ? <DataTable rows={array(data, 'sessions')} columns={[{ key: 'ip', label: 'Client IP' }, { key: 'user_agent', label: 'Browser', render: r => <span className="truncate" title={r.user_agent}>{r.user_agent}</span> }, { key: 'created_at', label: 'Signed in', render: r => date(r.created_at) }, { key: 'expires_at', label: 'Expires', render: r => date(r.expires_at) }, { key: 'action', label: 'Access', render: r => <button className="btn btn-sm btn-outline-danger" onClick={() => revoke(r.id)}>Revoke session</button> }]}/> : <Busy />}</Panel>;
}
function App() {
    const [auth, setAuth] = useState(null);
    const [error, setError] = useState(null);
    const [page, setPage] = useState('Overview');
    const [managementSection, setManagementSection] = useState('');
    const [mode, setMode] = useState(() => localStorage.getItem('getbible-theme') || 'system');
    const [preset, setPreset] = useState('24 hours');
    const [custom, setCustom] = useState({ start: '', end: '' });
    const [filters, setFilters] = useState({});
    const [detail, setDetail] = useState(null);
    const [pending, setPending] = useState(null);
    const [submitting, setSubmitting] = useState(false);
    const submittingRef = useRef(false);
    const [pendingError, setPendingError] = useState(null);
    const [refresh, setRefresh] = useState(0);
    const [lastUpdate, setLastUpdate] = useState(null);
    const [wake, setWake] = useState('initializing');
    const [navOpen, setNavOpen] = useState(false);
    const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
    const viewer = useRef(crypto.randomUUID());
    const onError = useCallback(e => { if (e.status === 401) {
        setCsrf('');
        setAuth({ authenticated: false });
    }
    else
        setError(e); }, []);
    const range = useMemo(() => preset === 'Custom' && custom.start && custom.end ? { start: Math.floor(new Date(custom.start).getTime() / 1000), end: Math.floor(new Date(custom.end).getTime() / 1000) } : { start: now - (durations[preset] || 86400), end: now }, [preset, now, custom]);
    useEffect(() => { api('auth/status').then(setAuth).catch(onError); }, []);
    useEffect(() => {
        if (auth?.authenticated) return;
        setDetail(null); setPending(null);
        setWake('initializing'); setLastUpdate(null);
    }, [auth?.authenticated]);
    useEffect(() => {
        const media = matchMedia('(prefers-color-scheme: dark)');
        const apply = () => { document.documentElement.dataset.bsTheme = mode === 'system' ? media.matches ? 'dark' : 'light' : mode; };
        apply();
        localStorage.setItem('getbible-theme', mode);
        media.addEventListener('change', apply);
        return () => media.removeEventListener('change', apply);
    }, [mode]);
    useEffect(() => {
        if (!auth?.authenticated)
            return;
        let stopped = false;
        let timer;
        async function heartbeat() {
            try {
                const state = await post('dashboard/heartbeat', { viewer_id: viewer.current });
                if (!stopped)
                    setWake(state.state === 'awake' ? 'ready' : state.state);
            }
            catch (e) {
                if (!stopped)
                    onError(e);
            }
            if (!stopped)
                timer = setTimeout(heartbeat, 15000);
        }
        heartbeat();
        const visibility = () => { if (document.visibilityState === 'visible') {
            clearTimeout(timer);
            heartbeat();
        } };
        document.addEventListener('visibilitychange', visibility);
        return () => { stopped = true; clearTimeout(timer); document.removeEventListener('visibilitychange', visibility); };
    }, [auth?.authenticated]);
    useEffect(() => {
        if (!auth?.authenticated || wake === 'ready')
            return;
        let stopped = false;
        let timer;
        async function ready() {
            try {
                const result = await api('dashboard/state');
                if (stopped)
                    return;
                if (result.state === 'awake') {
                    setWake('ready');
                    setError(previous => previous?.historyUnavailable ? null : previous);
                    return;
                }
                if (result.state === 'unavailable') setWake('unavailable');
                if (result.error)
                    setError(Object.assign(new Error(result.error), {historyUnavailable: result.state === 'unavailable'}));
            }
            catch (e) {
                if (!stopped)
                    onError(e);
            }
            if (!stopped)
                timer = setTimeout(ready, 1000);
        }
        ready();
        return () => { stopped = true; clearTimeout(timer); };
    }, [auth?.authenticated, wake]);
    const reportUpdated = useCallback(() => setLastUpdate(new Date()), []);
    const reports = useReports({page: ['Overview', 'Resources'].includes(page) ? page : '',
        range, live: preset === 'Live', filters: page === 'Overview' ? filters : undefined, refresh,
        enabled: auth?.authenticated && wake === 'ready' && (preset !== 'Custom' || Boolean(custom.start && custom.end)),
        onError, onUpdate: reportUpdated});
    const summary = reports.overview?.data;
    function zoomRange({start, end}) {
        if (!(end > start)) return;
        const localInput = seconds => {
            const value = new Date(seconds * 1000);
            return new Date(value.getTime() - value.getTimezoneOffset() * 60000).toISOString().slice(0, 19);
        };
        setCustom({start: localInput(start), end: localInput(end)});
        setPreset('Custom');
    }
    function inspect(title, value) { setDetail({ title, value }); }
    function filter(key, value, scope) { setFilters({ ...filters, ...(scope || {[key]: value}) }); setPage('Traffic'); }
    function refreshAll() { setNow(Math.floor(Date.now() / 1000)); setRefresh(r => r + 1); }
    async function executeConfirmed() {
        if (submittingRef.current) return;
        submittingRef.current = true; setSubmitting(true); setPendingError(null);
        try {
            const result = await post('actions', { operation: pending.operation, arguments: pending.arguments, confirm: true });
            setPending(null);
            inspect('Operation details', { ...result, job_id: result.job_id || result.id });
            refreshAll();
        }
        catch (e) {
            setPendingError(e); onError(e);
        } finally {submittingRef.current = false; setSubmitting(false);}
    }
    if (!auth)
        return <main className="login-page"><Busy>Connecting to your server…</Busy><ErrorNotice error={error}/></main>;
    if (!auth.authenticated)
        return <Login onLogin={setAuth}/>;
    return <div className="console"><aside className={`sidebar ${navOpen ? 'expanded' : ''}`}><a className="brand" href="#overview" onClick={e => { e.preventDefault(); setPage('Overview'); }}><img src="/favicon.png" alt=""/><span>getBible<small>OPERATIONS</small></span></a><div className="workspace-label">SERVER CONSOLE</div><nav aria-label="Main navigation">{pages.map((label, i) => <button className={page === label ? 'active' : ''} aria-current={page === label ? 'page' : undefined} key={label} aria-label={label} onClick={() => { setPage(label); if (label === 'MCP traffic') setFilters(mcpFilters(filters)); if (label === 'Manage') setManagementSection(''); setNavOpen(false); }}><span className="nav-number">{String(i + 1).padStart(2, '0')}</span>{label}</button>)}</nav><div className="sidebar-bottom"><span className="eyebrow">CONSOLE STATE</span><strong>{wake === 'ready' ? 'Connected' : wake === 'unavailable' ? 'History unavailable' : 'Initializing'}</strong><small>Traffic is recorded continuously.</small><button className="btn btn-sm btn-outline-secondary" onClick={async () => { try {
        await post('auth/logout');
        setAuth({ authenticated: false });
        setCsrf('');
    }
    catch (e) {
        onError(e);
    } }}>Sign out</button></div></aside><div className="main-area"><header className="topbar"><button className="btn btn-sm btn-outline-secondary mobile-menu" onClick={() => setNavOpen(!navOpen)} aria-label="Toggle navigation">Menu</button><span className="breadcrumb-text">getBible <span>/</span> {page}</span><div className="topbar-controls"><small className="last-updated">{lastUpdate ? `Updated ${lastUpdate.toLocaleTimeString()}` : 'Initializing…'}</small><button className="btn btn-sm btn-outline-secondary" onClick={refreshAll} title="Refresh all dashboard data and locally cached metadata">Refresh all</button><label className="visually-hidden" htmlFor="theme">Color theme</label><select id="theme" className="form-select form-select-sm theme-select" value={mode} onChange={e => setMode(e.target.value)}><option value="system">System theme</option><option value="dark">Dark</option><option value="light">Light</option></select></div></header><main className="content"><div className="page-heading"><div><span className="eyebrow">{page === 'Overview' ? 'YOUR API AT A GLANCE' : 'GETBIBLE OPERATIONS'}</span><h1>{page === 'Overview' ? 'Traffic & performance' : page}</h1></div><div className="range-picker"><label className="visually-hidden" htmlFor="period">Time range</label><select className="form-select" id="period" value={preset} onChange={e => { setPreset(e.target.value); setNow(Math.floor(Date.now() / 1000)); }}>{[...Object.keys(durations), 'Custom'].map(v => <option key={v}>{v}</option>)}</select>{preset === 'Live' && <Badge tone="success">LIVE</Badge>}</div></div>{preset === 'Custom' && <div className="custom-range"><label>From<input className="form-control" type="datetime-local" step="1" value={custom.start} onChange={e => setCustom({ ...custom, start: e.target.value })}/></label><label>Until<input className="form-control" type="datetime-local" step="1" value={custom.end} onChange={e => setCustom({ ...custom, end: e.target.value })}/></label><small>Times use your browser's local time zone.</small></div>}<ErrorNotice error={error} dismiss={() => setError(null)}/>{summary?.retention?.first_request > range.start && <div className="alert alert-info py-2">Available request history starts {date(summary.retention.first_request)}. Earlier time in this selection has no retained detail.</div>}{Object.entries(filters).filter(([, v]) => v).length > 0 && <div className="filter-chips">{Object.entries(filters).filter(([, v]) => v).map(([key, value]) => <button className="btn btn-sm btn-outline-info" key={key} onClick={() => { const next = { ...filters }; delete next[key]; setFilters(next); }}>{key}: {String(value)} <span aria-label="Remove filter">×</span></button>)}<button className="btn btn-sm btn-link" onClick={() => setFilters({})}>Clear all</button></div>}{wake !== 'ready' && !['Manage', 'Translations', 'Resources', 'Sessions'].includes(page) ? wake === 'unavailable' ? <Panel title="Traffic history needs attention" detail="Server management remains available while traffic history is unavailable."><div className="fact-list"><p>Review the reported history error. To start fresh after an incompatible history format, open Logs, then History, and review the reset operation.</p><button className="btn btn-primary" onClick={() => {setManagementSection('logs'); setPage('Manage');}}>Manage traffic history</button></div></Panel> : <Busy>Initializing dashboard…</Busy> : page === 'Overview' ? <Overview overview={reports.overview} timeline={reports.history} onFilter={filter} onDetail={inspect} onZoom={zoomRange}/> : page === 'Traffic' ? <Traffic key={JSON.stringify([range, filters, preset, refresh])} live={preset === 'Live'} filters={filters} setFilters={setFilters} range={range} onError={onError} onDetail={inspect}/> : page === 'MCP traffic' ? <McpTraffic range={range} live={preset === 'Live'} filters={filters} refresh={refresh} onFilter={filter} onError={onError} onZoom={zoomRange}/> : page === 'Audience' ? <Audience range={range} live={preset === 'Live'} filters={filters} refresh={refresh} onFilter={filter} onError={onError}/> : page === 'Translations' ? <Translations onError={onError} execute={(operation, args, review) => (setPendingError(null), setPending({ operation, arguments: args, review }))} onDetail={inspect} refresh={refresh}/> : page === 'Resources' ? <Resources report={reports.metrics} refresh={refresh} onError={onError} onDetail={inspect} execute={(operation, args, review) => (setPendingError(null), setPending({operation, arguments: args, review}))}/> : page === 'Events' ? <Events key={JSON.stringify([range, preset, refresh])} range={range} live={preset === 'Live'} onError={onError} onDetail={inspect}/> : page === 'Manage' ? <Management key={managementSection || 'manage'} initialSection={managementSection} execute={(operation, args, review) => (setPendingError(null), setPending({ operation, arguments: args, review }))} onError={onError} onDetail={inspect} refresh={refresh}/> : <Sessions onError={onError} refresh={refresh} onRefresh={refreshAll}/>}<footer>Origin observations · CDN cache hits served before this server are outside this view.</footer></main></div>{detail && <Detail title={detail.title} value={detail.value} onClose={() => setDetail(null)}>{detail.title === 'Operation details' ? <JobViewer initial={detail.value} onError={onError} onComplete={refreshAll}/> : undefined}</Detail>}{pending && <Detail title="Review operation" onClose={() => setPending(null)}><ErrorNotice error={pendingError}/><p>{pending.review?.title || 'The following operation will run on this server.'}</p>{pending.review?.description && <p className="text-secondary">{pending.review.description}</p>}<pre className="record-detail">{JSON.stringify({ operation: pending.operation, arguments: Object.fromEntries(Object.entries(pending.arguments).map(([key, value]) => [key, /password|token|secret|credential/i.test(key) ? '[hidden]' : key === 'content' ? '[content supplied]' : value])) }, null, 2)}</pre><div className="d-flex gap-2"><button className="btn btn-primary" disabled={submitting} onClick={executeConfirmed}>{submitting ? 'Submitting…' : 'Run operation'}</button><button className="btn btn-outline-secondary" data-bs-dismiss="modal">Cancel</button></div></Detail>}</div>;
}
createRoot(document.getElementById('root')).render(<App />);
