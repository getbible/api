import React, { useCallback, useEffect, useId, useMemo, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { api, post, query, number, bytes, date, setCsrf } from './api.js';
import { Chart, lineOption, donutOption } from './charts.jsx';
import './style.css';
const pages = ['Overview', 'Traffic', 'Translations', 'Resources', 'Events', 'Manage', 'Sessions'];
const durations = { 'Live': 900, '24 hours': 86400, '7 days': 604800, '30 days': 2592000, '6 months': 15552000 };
const array = (value, key) => Array.isArray(value) ? value : value?.[key] ?? value?.items ?? [];
function ErrorNotice({ error, dismiss }) {
    return error ? <div className="alert alert-danger d-flex align-items-start gap-3" role="alert"><span className="flex-grow-1">{error.message || String(error)}</span>{dismiss && <button className="btn-close" aria-label="Dismiss error" onClick={dismiss}/>}</div> : null;
}
function Empty({ children = 'No records in this time range.' }) { return <div className="empty-state">{children}</div>; }
function Busy({ children = 'Loading…' }) { return <div className="empty-state"><span className="spinner-border spinner-border-sm me-2" aria-hidden="true"/>{children}</div>; }
function Panel({ title, detail, children, className = '', actions }) {
    return <section className={`panel ${className}`}><div className="panel-title"><div><h2>{title}</h2>{detail && <small>{detail}</small>}</div>{actions}</div>{children}</section>;
}
function Badge({ children, tone = 'muted' }) { return <span className={`status-badge ${tone}`}>{children}</span>; }
function Meter({ value, max, label }) { return <div className="progress" role="progressbar" aria-label={label} aria-valuenow={value || 0} aria-valuemin="0" aria-valuemax={max || 100}><div className="progress-bar" style={{ width: `${Math.min(100, (value || 0) * 100 / (max || 100))}%` }}/></div>; }
function DataTable({ columns, rows, onSelect, rowKey }) {
    return rows.length ? <div className="table-responsive"><table className="table align-middle table-hover mb-0"><thead><tr>{columns.map(c => <th key={c.key} scope="col">{c.label}</th>)}</tr></thead><tbody>{rows.map((row, index) => <tr key={rowKey?.(row) ?? index}>{columns.map((c, ci) => <td key={c.key}>{ci === 0 && onSelect ? <button className="table-link" onClick={() => onSelect(row)}>{c.render ? c.render(row) : row[c.key]}</button> : c.render ? c.render(row) : row[c.key] ?? '—'}</td>)}</tr>)}</tbody></table></div> : <Empty />;
}
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
    return rows.length ? <div className="rankings">{rows.slice(0, 8).map((row, i) => <button key={`${row.value}-${i}`} className="ranking" onClick={() => onSelect?.(row.value)}><span className="rank-index">{String(i + 1).padStart(2, '0')}</span><span className="rank-name" title={String(row.value)}>{row.value || 'Unspecified'}<Meter value={row.calls} max={max} label={`${label}: ${row.value}`}/></span><strong>{number(row.calls)}</strong></button>)}</div> : <Empty />;
}
function Overview({ summary, history, onFilter, onDetail, onZoom }) {
    const b = summary.breakdowns || {};
    const metrics = summary.latest_metrics || {};
    const cards = [
        ['Origin requests', number(summary.calls), `${number(summary.unique_ips)} unique IPs`],
        ['Request rate', number(summary.requests_per_second, 1), 'requests / second'],
        ['P95 latency', summary.latency_ms?.p95 == null ? '—' : `${number(summary.latency_ms.p95, 1)} ms`, 'histogram estimate'],
        ['Cache hit rate', summary.cache_hit_ratio == null ? '—' : `${number(summary.cache_hit_ratio * 100, 1)}%`, `${number(summary.cache_hits)} origin cache hits`],
        ['Errors', number(summary.errors), `${number(summary.rate_limited)} rate limited`],
    ];
    return <><div className="metric-grid">{cards.map(([name, value, detail]) => <div className="metric panel" key={name}><span>{name}</span><strong>{value}</strong><small>{detail}</small></div>)}</div><div className="overview-grid"><Panel className="flow-panel" title="Request flow" detail="Origin traffic over the selected period" actions={<Badge tone="info">{bytes(summary.bytes)} transferred</Badge>}><Chart label="Origin requests and errors by time" height={310} onZoom={onZoom} option={lineOption(history.series || [], [['calls', 'Requests'], ['errors', 'Errors']], { zoom: true })}/></Panel><Panel title="Access breakdown" detail="Credential state at the origin"><Chart label="Anonymous, authenticated and rejected request breakdown" option={donutOption(b.auth || [])} height={310}/></Panel><Panel className="endpoints-panel" title="API endpoints" detail="Select an endpoint to inspect its traffic"><DataTable rows={b.endpoint || b.domain || []} onSelect={row => onFilter('endpoint', row.value)} columns={[{ key: 'value', label: 'Endpoint' }, { key: 'calls', label: 'Requests', render: r => number(r.calls) }, { key: 'errors', label: 'Errors', render: r => number(r.errors) }, { key: 'bytes', label: 'Transfer', render: r => bytes(r.bytes) }]}/></Panel><Panel title="Response codes" detail="Failures and rate limits"><Ranking rows={b.status || []} label="Response status" onSelect={v => onFilter('status', v)}/></Panel><Panel title="Popular translations"><Ranking rows={b.translation || []} label="Translation" onSelect={v => onFilter('translation', v)}/></Panel><Panel title="Frequent searches"><Ranking rows={b.search || []} label="Search" onSelect={v => onFilter('search', v)}/></Panel><Panel title="Scripture references"><Ranking rows={b.reference || []} label="Reference" onSelect={v => onFilter('reference', v)}/></Panel><Panel title="Books of the Bible"><Ranking rows={b.book || []} label="Book" onSelect={v => onFilter('book', v)}/></Panel><Panel title="Active IP addresses" detail="Inspect high-volume origin consumers"><Ranking rows={b.ip || []} label="Client IP" onSelect={v => onFilter('ip', v)}/></Panel><Panel title="Collector health" detail="Continuous capture, independent of this dashboard"><div className="fact-list"><div><span>Available history</span><strong>{date(summary.retention?.first_request)}</strong></div><div><span>Last sample</span><strong>{date(metrics.stamp)}</strong></div><div><span>Observed scope</span><strong>Origin only</strong></div><button className="btn btn-outline-secondary btn-sm" onClick={() => onDetail('Retention and capture health', summary.retention || {})}>Retention details</button></div></Panel></div></>;
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
    return <Panel title="Request explorer" detail="Inspect recorded request details; credentials are excluded"><form className="filter-grid" onSubmit={submit}>{[['endpoint', 'Endpoint'], ['version', 'Version'], ['ip', 'Client IP'], ['translation', 'Translation'], ['reference', 'Reference'], ['search', 'Search query'], ['status', 'Status']].map(([key, label]) => <label key={key}>{label}<input className="form-control form-control-sm" value={draft[key] || ''} onChange={e => setDraft({ ...draft, [key]: e.target.value })}/></label>)}<label>Authentication<select className="form-select form-select-sm" value={draft.auth || ''} onChange={e => setDraft({ ...draft, auth: e.target.value })}><option value="">All traffic</option><option value="anonymous">Anonymous</option><option value="valid">Authenticated</option><option value="rejected">Rejected credential</option></select></label><div className="d-flex gap-2 align-items-end"><button className="btn btn-primary btn-sm">Apply filters</button><button type="button" className="btn btn-outline-secondary btn-sm" onClick={() => { setDraft({}); setFilters({}); }}>Clear</button></div></form>{data ? <DataTable rows={array(data, 'requests')} onSelect={r => onDetail('Request details', r)} columns={[{ key: 'timestamp', label: 'Time', render: r => date(r.stamp) }, { key: 'endpoint', label: 'Endpoint' }, { key: 'method', label: 'Method' }, { key: 'path', label: 'Request', render: r => <span className="truncate" title={r.path}>{r.path}</span> }, { key: 'status', label: 'Status', render: r => <Badge tone={r.status >= 400 ? 'warning' : 'success'}>{r.status}</Badge> }, { key: 'duration_ms', label: 'Latency', render: r => `${number(r.duration_ms, 1)} ms` }, { key: 'remote_addr', label: 'Client IP' }, { key: 'auth', label: 'Auth' }]}/> : <Busy />}<div className="table-footer"><small>Latest captures first · up to 100 requests per page</small><div className="btn-group"><button className="btn btn-outline-secondary btn-sm" disabled={!previous.length} onClick={() => { setCursor(previous.at(-1)); setPrevious(previous.slice(0, -1)); }}>Previous</button><button className="btn btn-outline-secondary btn-sm" disabled={!data?.next_cursor} onClick={() => { setPrevious([...previous, cursor]); setCursor(data.next_cursor); }}>Next</button></div></div></Panel>;
}
function Events({range, live, onError, onDetail}) {
    const [data, setData] = useState(null);
    const [cursor, setCursor] = useState('');
    const [previous, setPrevious] = useState([]);
    const [capturedRange, setCapturedRange] = useState(range);
    useEffect(() => {
        let stopped = false; let timer;
        async function poll() {
            const end = live && !cursor ? Math.floor(Date.now() / 1000) : cursor ? capturedRange.end : range.end;
            try {const value = await api(`events?${query({start: live ? end - 900 : range.start, end, cursor, limit: 100})}`); if (!stopped) {setData(value); if (!cursor) setCapturedRange({start: live ? end - 900 : range.start, end});}}
            catch (e) {if (!stopped) onError(e);}
            if (!stopped && live && !cursor) timer = setTimeout(poll, 2000);
        }
        poll(); return () => {stopped = true; clearTimeout(timer);};
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

function Translations({ onError, execute, onDetail, refresh }) {
    const [data, setData] = useState(null);
    const [selected, setSelected] = useState('');
    const [code, setCode] = useState('kjv');
    useEffect(() => {
        let stopped = false; let timer;
        async function poll() {
            try {const value = await api('translations'); if (!stopped) setData(value);}
            catch(e) {if (!stopped) onError(e);}
            if (!stopped) timer = setTimeout(poll, 5000);
        }
        poll(); return () => {stopped = true; clearTimeout(timer);};
    }, [refresh]);
    const endpoints = array(data, 'endpoints');
    const selectedEndpoint = endpoints.find(endpoint => `${endpoint.domain}/${endpoint.label}` === selected);
    const available = selectedEndpoint?.available_translations || [];
    function action(endpoint, translation, name) {
        execute('runtime.cache', { domain: endpoint.domain, endpoint: endpoint.label, action: name, translation });
    }
    return <>
    <Panel title="Translation memory" detail="Warm on demand, retain within the configured lifetime and memory budget.">
      <div className="filter-grid">
        <label>Runtime endpoint<select className="form-select" value={selected} onChange={e => setSelected(e.target.value)}><option value="">Select endpoint</option>{endpoints.map(e => <option key={`${e.domain}/${e.label}`} value={`${e.domain}/${e.label}`}>{e.domain} / {e.label} · {e.kind}</option>)}</select></label>
        <label>Translation<input list="available-translations" className="form-control" value={code} onChange={e => setCode(e.target.value)} placeholder="kjv" pattern="[a-z0-9_-]+"/><datalist id="available-translations">{available.map(item => <option key={item.translation} value={item.translation}/>)}</datalist></label>
        <div className="d-flex gap-2 align-items-end">{['warm', 'drop', 'reload'].map(name => <button className={`btn btn-${name === 'drop' ? 'outline-danger' : 'outline-primary'}`} disabled={!selected || !/^[a-z0-9_-]+$/.test(code)} key={name} onClick={() => action(endpoints.find(e => `${e.domain}/${e.label}` === selected), code, name)}>{name[0].toUpperCase() + name.slice(1)}</button>)}</div>
      </div>
    </Panel>
    {data ? endpoints.length ? endpoints.map(endpoint => {
            const residents = [];
            for (const worker of endpoint.workers || []) {
                const query = worker.cache?.query_translations || {};
                const search = worker.cache?.search_corpora?.translations || {};
                const snapshots = worker.cache?.translation_cache?.translations || {};
                for (const code of new Set([...Object.keys(query), ...Object.keys(search), ...Object.keys(snapshots)])) {
                    const checked = [search[code], snapshots[code]].filter(Boolean);
                    residents.push({code, pid: worker.pid,
                        query_bytes: query[code]?.estimated_bytes, search_bytes: search[code]?.estimated_bytes,
                        snapshot_bytes: snapshots[code]?.estimated_bytes, chapters: query[code]?.chapters,
                        verses: search[code]?.verses, ttl: worker.cache?.ttl_seconds,
                        stale: query[code]?.expired_chapters > 0 || checked.some(item => item.stale || (item.checked_at != null && item.checked_at + worker.cache.ttl_seconds <= Date.now() / 1000)),
                        details: {query: query[code], search: search[code], snapshot: snapshots[code]}});
                }
            }
            return <Panel key={`${endpoint.domain}/${endpoint.label}`} title={`${endpoint.domain} / ${endpoint.label}`} detail={`${endpoint.kind} · ${endpoint.workers?.length || 0} workers · object estimates can overlap; use worker RSS/private memory for measured usage`} actions={<Badge tone={endpoint.complete ? 'success' : 'warning'}>{endpoint.complete ? 'All workers reported' : 'Partial report'}</Badge>}>
        <DataTable rows={residents} onSelect={r => onDetail(`${r.code.toUpperCase()} · worker ${r.pid}`, r.details)} columns={[
                    { key: 'code', label: 'Translation', render: r => r.code.toUpperCase() },
                    { key: 'pid', label: 'Worker' },
                    { key: 'query_bytes', label: 'Query estimate', render: r => bytes(r.query_bytes) },
                    { key: 'search_bytes', label: 'Search estimate', render: r => bytes(r.search_bytes) },
                    { key: 'snapshot_bytes', label: 'Snapshot estimate', render: r => bytes(r.snapshot_bytes) },
                    { key: 'chapters', label: 'Resident data', render: r => r.chapters != null ? `${number(r.chapters)} chapters` : r.verses != null ? `${number(r.verses)} verses` : 'Translation snapshot' },
                    { key: 'stale', label: 'Freshness', render: r => <Badge tone={r.stale ? 'warning' : 'success'}>{r.stale ? 'Recheck on use' : 'Warm'}</Badge> },
                    { key: 'ttl', label: 'Memory TTL', render: r => `${number(r.ttl / 86400, 1)} days` },
                    { key: 'actions', label: 'All workers', render: r => <div className="btn-group"><button className="btn btn-sm btn-outline-primary" onClick={() => action(endpoint, r.code, 'reload')}>Reload</button><button className="btn btn-sm btn-outline-danger" onClick={() => action(endpoint, r.code, 'drop')}>Drop</button></div> },
                ]}/>
        <details className="worker-details"><summary>{number(endpoint.available_translations?.length || 0)} translations on disk</summary>
          <DataTable rows={endpoint.available_translations || []} onSelect={row => onDetail(`${row.translation.toUpperCase()} on disk`, row)} columns={[
            {key: 'translation', label: 'Translation', render: row => row.translation.toUpperCase()},
            {key: 'allocated_bytes', label: 'Allocated disk', render: row => bytes(row.allocated_bytes)},
            {key: 'logical_bytes', label: 'File contents', render: row => bytes(row.logical_bytes)},
            {key: 'files', label: 'Files', render: row => number(row.files)},
            {key: 'warm', label: 'Memory', render: row => <button className="btn btn-sm btn-outline-primary" onClick={() => action(endpoint, row.translation, 'warm')}>Warm translation</button>},
          ]}/>
        </details>
        <details className="worker-details"><summary>Measured worker memory and cache limits</summary><DataTable rows={endpoint.workers || []} onSelect={worker => onDetail(`Worker ${worker.pid} · ${endpoint.label}`, worker)} columns={[{ key: 'pid', label: 'Worker PID' }, { key: 'rss_bytes', label: 'RSS including shared pages', render: r => bytes(r.rss_bytes) }, { key: 'private_bytes', label: 'Private memory', render: r => bytes(r.private_bytes) }, { key: 'generation', label: 'Generation', render: () => endpoint.generation || '—' }]}/></details>
        {!!endpoint.errors?.length && <div className="alert alert-warning m-3">{endpoint.errors.map((e, i) => <div key={i}>{typeof e === 'string' ? e : e.error || 'Worker did not report.'}</div>)}</div>}
      </Panel>;
        }) : <Empty>No runtime endpoints are configured.</Empty> : <Busy />}
  </>;
}
function Resources({ summary, history, refresh, onError, onDetail }) {
    const [storage, setStorage] = useState(null);
    useEffect(() => { api(`storage?refresh=${refresh > 0}`).then(setStorage).catch(onError); }, [refresh]);
    const metric = summary.latest_metrics || history.metrics?.at(-1) || {};
    return <div className="resource-grid"><Panel title="Container CPU" detail="Usage within the container's effective CPU allowance"><Chart label="Container CPU usage over time" option={lineOption((history.metrics || []).map(row => ({ ...row, cpu_percent: row.cpu?.used_fraction == null ? null : row.cpu.used_fraction * 100 })), [['cpu_percent', 'CPU usage %']])}/><div className="fact-list"><div><span>Current utilization</span><strong>{number(metric.cpu?.used_fraction == null ? null : metric.cpu.used_fraction * 100, 1)}%</strong></div><div><span>Throttled time</span><strong>{number(metric.cpu?.counters?.throttled_usec)} μs</strong></div><div><span>Temperature</span><strong>{!metric.temperatures?.length ? 'Sensor unavailable' : `${number(Math.max(...metric.temperatures.map(t => t.celsius)), 1)} °C`}</strong></div></div></Panel><Panel title="Container memory" detail="Measured usage includes more than translation caches"><Chart label="Container memory usage over time" option={lineOption((history.metrics || []).map(row => ({ ...row, memory_gib: row.memory?.current_bytes == null ? null : row.memory.current_bytes / 1073741824 })), [['memory_gib', 'Memory GiB']])}/><div className="fact-list"><div><span>Current / limit</span><strong>{bytes(metric.memory?.current_bytes)} / {bytes(metric.memory?.limit_bytes)}</strong></div><div><span>OOM events</span><strong>{number(metric.memory?.events?.oom_kill)}</strong></div></div></Panel><Panel className="wide" title="Persistent storage" detail="Mounted data on the host; application budgets do not impose a filesystem quota" actions={<button className="btn btn-sm btn-outline-secondary" onClick={() => onDetail('Storage accounting', storage)}>Inspect accounting</button>}>{storage ? <DataTable rows={array(storage, 'components')} onSelect={r => onDetail('Storage details', r)} columns={[{ key: 'name', label: 'Data', render: r => r.name || r.category || r.path }, { key: 'bytes', label: 'Allocated', render: r => bytes(r.bytes ?? r.allocated_bytes) }, { key: 'limit_bytes', label: 'Budget', render: r => r.limit_bytes ? bytes(r.limit_bytes) : '—' }, { key: 'path', label: 'Location' }]}/> : <Busy />}</Panel><Panel className="wide" title="Pressure and collection details"><div className="fact-list"><button className="btn btn-outline-secondary" onClick={() => onDetail('Latest resource sample', metric)}>Inspect latest resource sample</button><button className="btn btn-outline-secondary" onClick={() => onDetail('Retention', summary.retention)}>Inspect available history and pruning</button></div></Panel></div>;
}
function OperationField({field, values, setValues, onError}) {
    const change = value => setValues({...values, [field.name]: value});
    const props = {className: 'form-control', required: field.required && !field.allow_empty};
    let input;
    if (field.type === 'file') {
        input = <input {...props} type="file" accept=".png,.jpg,.jpeg,.webp,.ico,.svg" onChange={event => {
            const file = event.target.files?.[0];
            if (!file) return;
            if (file.size > 1048576) {onError(new Error('Choose an image smaller than 1 MiB.')); event.target.value = ''; return;}
            const reader = new FileReader();
            reader.onload = () => setValues({...values, filename: file.name, [field.name]: String(reader.result).split(',')[1]});
            reader.onerror = () => onError(new Error('The selected file could not be read.'));
            reader.readAsDataURL(file);
        }}/>;
    } else if (field.type === 'multiline') {
        input = <textarea {...props} rows={12} spellCheck="false" value={values[field.name] || ''} onChange={e => change(e.target.value)} />;
    } else if (field.type === 'boolean') {
        input = <select className="form-select" value={String(values[field.name] ?? false)} onChange={e => change(e.target.value === 'true')}><option value="false">No</option><option value="true">Yes</option></select>;
    } else if (field.choices || field.enum) {
        input = <select className="form-select" required={field.required && !field.allow_empty} value={values[field.name] ?? ''} onChange={e => change(e.target.value)}><option value="">Select…</option>{(field.choices || field.enum).map(c => <option key={c} value={c}>{c}</option>)}</select>;
    } else {
        input = <input {...props} type={field.secret ? 'password' : field.type === 'integer' ? 'number' : 'text'} autoComplete={field.secret ? 'new-password' : 'off'} value={values[field.name] ?? ''} onChange={e => change(field.type === 'integer' && e.target.value !== '' ? Number(e.target.value) : e.target.value)} />;
    }
    return <label className={field.type === 'multiline' ? 'full-width' : undefined}>{field.label || field.name}{input}{field.description && <small>{field.description}</small>}</label>;
}

function Management({ execute, onError, onDetail, refresh }) {
    const [catalogue, setCatalogue] = useState(null);
    const [jobs, setJobs] = useState(null);
    const [operation, setOperation] = useState('');
    const [values, setValues] = useState({});
    useEffect(() => { api('operations').then(setCatalogue).catch(onError); }, [refresh]);
    useEffect(() => { let stopped = false; let timer; async function poll() { try {
        const data = await api('jobs');
        if (!stopped)
            setJobs(data);
    }
    catch (e) {
        if (!stopped)
            onError(e);
    } if (!stopped)
        timer = setTimeout(poll, 2000); } poll(); return () => { stopped = true; clearTimeout(timer); }; }, []);
    const operations = array(catalogue, 'operations');
    const spec = operations.find(o => (o.id || o.operation || o.name) === operation);
    const fields = spec?.fields || spec?.parameters || [];
    function submit(event) {
        event.preventDefault();
        const submitted = Object.fromEntries(Object.entries(values).filter(([name, value]) => value !== '' || fields.find(field => field.name === name)?.allow_empty));
        execute(operation, submitted);
    }
    return <><Panel title="Server management" detail="Operations use the same validated commands as the CLI. Started jobs continue when this page closes."><form className="management-form" onSubmit={submit}><label>Operation<select className="form-select" value={operation} onChange={e => { setOperation(e.target.value); const item = operations.find(o => (o.id || o.operation || o.name) === e.target.value); setValues(Object.fromEntries((item?.fields || []).filter(f => f.default !== undefined).map(f => [f.name, f.default]))); }}><option value="">Select an operation</option>{operations.map(item => <option key={item.id || item.operation || item.name} value={item.id || item.operation || item.name}>{item.title || item.label || item.name || item.id}</option>)}</select></label>{spec?.description && <p className="text-secondary">{spec.description}</p>}<div className="filter-grid">{(Array.isArray(fields) ? fields : Object.entries(fields).map(([name, f]) => ({ name, ...f }))).map(field => <OperationField key={field.name} field={field} values={values} setValues={setValues} onError={onError}/>)}</div><button className="btn btn-primary" disabled={!spec}>Review operation</button></form>{catalogue && !operations.length && <Empty>No management operations were returned by the broker.</Empty>}</Panel><Panel title="Operation history" detail="Select a job to view progress and output">{jobs ? <DataTable rows={array(jobs, 'jobs')} onSelect={async (row) => { try {
        onDetail('Operation details', await api(`jobs/${encodeURIComponent(row.id)}`));
    }
    catch (e) {
        onError(e);
    } }} columns={[{ key: 'id', label: 'Job' }, { key: 'operation', label: 'Operation' }, { key: 'status', label: 'State', render: r => <Badge tone={r.status === 'failed' ? 'warning' : r.status === 'succeeded' ? 'success' : 'info'}>{r.status}</Badge> }, { key: 'created_at', label: 'Started', render: r => date(r.created_at ?? r.created) }, { key: 'summary', label: 'Result' }]}/> : <Busy />}</Panel></>;
}
function JobViewer({ initial, onError, onComplete }) {
    const [job, setJob] = useState(initial);
    const [secret, setSecret] = useState(null);
    const [copied, setCopied] = useState(false);
    const reportedDone = useRef(false);
    const id = initial.job_id || initial.id;
    useEffect(() => {
        let stopped = false;
        let timer;
        async function poll() {
            try {
                const value = await api(`jobs/${encodeURIComponent(id)}`);
                if (!stopped) {
                    setJob(value);
                    if (!['queued', 'running'].includes(value.status) && !reportedDone.current) {reportedDone.current = true; onComplete?.();}
                    if (['queued', 'running'].includes(value.status))
                        timer = setTimeout(poll, 1000);
                }
            }
            catch (e) {
                if (!stopped)
                    onError(e);
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
    return <><div className="fact-list"><div><span>Operation</span><strong>{job.operation || 'Starting…'}</strong></div><div><span>Status</span><Badge tone={job.status === 'failed' ? 'warning' : 'info'}>{job.status}</Badge></div><div><span>Started</span><strong>{date(job.started || job.created)}</strong></div></div><pre className="record-detail">{job.output || 'Waiting for operation output…'}</pre>{job.secret_available && !secret && <button className="btn btn-warning" onClick={reveal}>Reveal issued credential once</button>}{secret && <div className="alert alert-warning"><p>Copy this credential now. It is shown only once and is not saved in the job history.</p><pre className="record-detail">{secret}</pre><button className="btn btn-outline-secondary" onClick={async () => { try {
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
    const [mode, setMode] = useState(() => localStorage.getItem('getbible-theme') || 'system');
    const [preset, setPreset] = useState('24 hours');
    const [custom, setCustom] = useState({ start: '', end: '' });
    const [filters, setFilters] = useState({});
    const [summary, setSummary] = useState(null);
    const [history, setHistory] = useState({});
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
        setSummary(null);
    }
    else
        setError(e); }, []);
    const range = useMemo(() => preset === 'Custom' && custom.start && custom.end ? { start: Math.floor(new Date(custom.start).getTime() / 1000), end: Math.floor(new Date(custom.end).getTime() / 1000) } : { start: now - (durations[preset] || 86400), end: now }, [preset, now, custom]);
    useEffect(() => { api('auth/status').then(setAuth).catch(onError); }, []);
    useEffect(() => {
        if (auth?.authenticated) return;
        setSummary(null); setHistory({}); setDetail(null); setPending(null);
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
                    return;
                }
                if (result.error)
                    setError(new Error(result.error));
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
    useEffect(() => {
        if (!auth?.authenticated || wake !== 'ready' || (preset === 'Custom' && (!custom.start || !custom.end)))
            return;
        let stopped = false;
        let timer;
        const controller = new AbortController();
        async function poll() {
            const end = preset === 'Live' ? Math.floor(Date.now() / 1000) : range.end;
            const start = preset === 'Custom' ? range.start : end - (durations[preset] || 86400);
            const bucket = preset === 'Live' ? 5 : Math.max(1, Math.ceil((end - start) / 400));
            try {
                const args = query({ start, end, bucket_seconds: bucket, ...filters });
                const [overview, chart] = await Promise.all([api(`overview?${args}`, { signal: controller.signal }), api(`history?${args}`, { signal: controller.signal })]);
                if (!stopped) {
                    setSummary(overview);
                    setHistory(chart);
                    setLastUpdate(new Date());
                    setWake('ready');
                }
            }
            catch (e) {
                if (!stopped && e.name !== 'AbortError')
                    onError(e);
            }
            if (!stopped)
                timer = setTimeout(poll, preset === 'Live' ? 2000 : 15000);
        }
        poll();
        return () => { stopped = true; clearTimeout(timer); controller.abort(); };
    }, [auth?.authenticated, wake, preset, custom, filters, refresh, range.start, range.end]);
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
    function filter(key, value) { setFilters({ ...filters, [key]: value }); setPage('Traffic'); }
    function refreshAll() { setNow(Math.floor(Date.now() / 1000)); setRefresh(r => r + 1); }
    async function executeConfirmed() {
        if (submittingRef.current) return;
        submittingRef.current = true; setSubmitting(true); setPendingError(null);
        try {
            const result = await post('actions', { ...pending, confirm: true });
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
    return <div className="console"><aside className={`sidebar ${navOpen ? 'expanded' : ''}`}><a className="brand" href="#overview" onClick={e => { e.preventDefault(); setPage('Overview'); }}><img src="/favicon.png" alt=""/><span>getBible<small>OPERATIONS</small></span></a><div className="workspace-label">SERVER CONSOLE</div><nav aria-label="Main navigation">{pages.map((label, i) => <button className={page === label ? 'active' : ''} aria-current={page === label ? 'page' : undefined} key={label} aria-label={label} onClick={() => { setPage(label); setNavOpen(false); }}><span className="nav-number">{String(i + 1).padStart(2, '0')}</span>{label}</button>)}</nav><div className="sidebar-bottom"><span className="eyebrow">CONSOLE STATE</span><strong>{wake === 'ready' ? 'Connected' : 'Initializing'}</strong><small>Traffic is recorded continuously.</small><button className="btn btn-sm btn-outline-secondary" onClick={async () => { try {
        await post('auth/logout');
        setAuth({ authenticated: false });
        setCsrf('');
    }
    catch (e) {
        onError(e);
    } }}>Sign out</button></div></aside><div className="main-area"><header className="topbar"><button className="btn btn-sm btn-outline-secondary mobile-menu" onClick={() => setNavOpen(!navOpen)} aria-label="Toggle navigation">Menu</button><span className="breadcrumb-text">getBible <span>/</span> {page}</span><div className="topbar-controls"><small className="last-updated">{lastUpdate ? `Updated ${lastUpdate.toLocaleTimeString()}` : 'Initializing…'}</small><button className="btn btn-sm btn-outline-secondary" onClick={refreshAll} title="Refresh all dashboard data and locally cached metadata">Refresh all</button><label className="visually-hidden" htmlFor="theme">Color theme</label><select id="theme" className="form-select form-select-sm theme-select" value={mode} onChange={e => setMode(e.target.value)}><option value="system">System theme</option><option value="dark">Dark</option><option value="light">Light</option></select></div></header><main className="content"><div className="page-heading"><div><span className="eyebrow">{page === 'Overview' ? 'YOUR API AT A GLANCE' : 'GETBIBLE OPERATIONS'}</span><h1>{page === 'Overview' ? 'Traffic & performance' : page}</h1></div><div className="range-picker"><label className="visually-hidden" htmlFor="period">Time range</label><select className="form-select" id="period" value={preset} onChange={e => { setPreset(e.target.value); setNow(Math.floor(Date.now() / 1000)); }}>{[...Object.keys(durations), 'Custom'].map(v => <option key={v}>{v}</option>)}</select>{preset === 'Live' && <Badge tone="success">LIVE</Badge>}</div></div>{preset === 'Custom' && <div className="custom-range"><label>From<input className="form-control" type="datetime-local" step="1" value={custom.start} onChange={e => setCustom({ ...custom, start: e.target.value })}/></label><label>Until<input className="form-control" type="datetime-local" step="1" value={custom.end} onChange={e => setCustom({ ...custom, end: e.target.value })}/></label><small>Times use your browser's local time zone.</small></div>}<ErrorNotice error={error} dismiss={() => setError(null)}/>{summary?.retention?.first_request > range.start && <div className="alert alert-info py-2">Available request history starts {date(summary.retention.first_request)}. Earlier time in this selection has no retained detail.</div>}{Object.entries(filters).filter(([, v]) => v).length > 0 && <div className="filter-chips">{Object.entries(filters).filter(([, v]) => v).map(([key, value]) => <button className="btn btn-sm btn-outline-info" key={key} onClick={() => { const next = { ...filters }; delete next[key]; setFilters(next); }}>{key}: {String(value)} <span aria-label="Remove filter">×</span></button>)}<button className="btn btn-sm btn-link" onClick={() => setFilters({})}>Clear all</button></div>}{wake !== 'ready' ? <Busy>Initializing dashboard…</Busy> : !summary && page === 'Overview' ? <Busy>Initializing dashboard history…</Busy> : page === 'Overview' ? <Overview summary={summary} history={history} onFilter={filter} onDetail={inspect} onZoom={zoomRange}/> : page === 'Traffic' ? <Traffic key={JSON.stringify([range, filters, preset])} live={preset === 'Live'} filters={filters} setFilters={setFilters} range={range} onError={onError} onDetail={inspect}/> : page === 'Translations' ? <Translations onError={onError} execute={(operation, args) => (setPendingError(null), setPending({ operation, arguments: args }))} onDetail={inspect} refresh={refresh}/> : page === 'Resources' ? <Resources summary={summary || {}} history={history} refresh={refresh} onError={onError} onDetail={inspect}/> : page === 'Events' ? <Events key={JSON.stringify([range, preset])} range={range} live={preset === 'Live'} onError={onError} onDetail={inspect}/> : page === 'Manage' ? <Management execute={(operation, args) => (setPendingError(null), setPending({ operation, arguments: args }))} onError={onError} onDetail={inspect} refresh={refresh}/> : <Sessions onError={onError} refresh={refresh} onRefresh={refreshAll}/>}<footer>Origin observations · CDN cache hits served before this server are outside this view.</footer></main></div>{detail && <Detail title={detail.title} value={detail.value} onClose={() => setDetail(null)}>{detail.title === 'Operation details' ? <JobViewer initial={detail.value} onError={onError} onComplete={refreshAll}/> : undefined}</Detail>}{pending && <Detail title="Review operation" onClose={() => setPending(null)}><ErrorNotice error={pendingError}/><p>The following operation will run on this server.</p><pre className="record-detail">{JSON.stringify({ ...pending, arguments: Object.fromEntries(Object.entries(pending.arguments).map(([key, value]) => [key, /password|token|secret|credential/i.test(key) ? '[hidden]' : key === 'content' ? '[content supplied]' : value])) }, null, 2)}</pre><div className="d-flex gap-2"><button className="btn btn-primary" disabled={submitting} onClick={executeConfirmed}>{submitting ? 'Submitting…' : 'Run operation'}</button><button className="btn btn-outline-secondary" data-bs-dismiss="modal">Cancel</button></div></Detail>}</div>;
}
createRoot(document.getElementById('root')).render(<App />);
