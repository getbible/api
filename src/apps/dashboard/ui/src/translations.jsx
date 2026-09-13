import React, {useEffect, useState} from 'react';
import {api, bytes, number} from './api.js';
import {Badge, Busy, DataTable, Empty, Panel} from './components.jsx';
import {translationMemory, translationState, valueRange} from './translation-memory.js';

function span(values, key, format = number) {
    const range = valueRange(values, key);
    if (!range) return '—';
    return range.min === range.max ? format(range.min) : `${format(range.min)}–${format(range.max)}`;
}
function countSpan(values, key, unit) {
    const range = valueRange(values, key);
    return `${span(values, key)} ${unit}${range?.min === 1 && range?.max === 1 ? '' : 's'}`;
}
function MemoryStatus({row}) {
    return <Badge tone={row.ready ? 'success' : row.resident.length ? 'warning' : 'muted'}>{row.status}</Badge>;
}
function WorkerLayer({row, onBack, onDetail}) {
    return <div className="worker-layer"><div className="worker-heading"><button className="btn btn-sm btn-outline-secondary" onClick={onBack}>Back to translations</button><strong>{row.code.toUpperCase()} · workers</strong><MemoryStatus row={row}/></div>
        <p className="panel-note">{number(row.resident.length)} of {number(row.expected)} workers currently retain this translation. Counts and estimates below describe each worker separately. A worker can retain query chapters alongside a complete search corpus.</p>
        <DataTable rows={row.workers} rowKey={worker => worker.pid} onSelect={worker => onDetail(`${row.code.toUpperCase()} · worker ${worker.pid}`, worker.details)} columns={[
            {key: 'pid', label: 'Worker PID'},
            {key: 'resident', label: 'Cache state', render: worker => <div><Badge tone={worker.ready ? 'success' : worker.resident ? 'warning' : 'muted'}>{worker.ready ? 'Warm' : worker.stale ? 'Recheck on use' : worker.resident ? 'Partly resident' : 'Not in memory'}</Badge>{worker.reason && <small className="cell-note">{worker.reason}</small>}</div>},
            {key: 'query_chapters', label: 'Query chapters', render: worker => <div>{number(worker.query_chapters)}<small className="cell-note">{bytes(worker.query_bytes)} estimated</small></div>},
            {key: 'search_verses', label: 'Search corpus / index', render: worker => <div>{worker.search_verses == null ? '—' : `${number(worker.search_verses)} verses`}<small className="cell-note">{bytes(worker.search_bytes)} estimated</small></div>},
            {key: 'snapshot_bytes', label: 'Translation snapshot', render: worker => worker.snapshot_present ? `${bytes(worker.snapshot_bytes)} estimated` : '—'},
            {key: 'ttl', label: 'Memory TTL', render: worker => worker.ttl == null ? '—' : `${number(worker.ttl / 86400, 1)} days`},
            {key: 'rss_bytes', label: 'Worker RSS', render: worker => bytes(worker.rss_bytes)},
            {key: 'private_bytes', label: 'Worker private memory', render: worker => bytes(worker.private_bytes)},
        ]}/><p className="panel-note">RSS includes shared pages and the whole worker. Private memory also covers the whole worker. Neither is a per-translation measurement; cache estimates may overlap.</p>
    </div>;
}

export default function Translations({onError, execute, onDetail, refresh}) {
    const [data, setData] = useState(null);
    const [selected, setSelected] = useState('');
    const [code, setCode] = useState('kjv');
    const [expanded, setExpanded] = useState({});
    useEffect(() => {
        let stopped = false; let timer;
        async function poll() {
            try {const result = await api('translations'); if (!stopped) setData(result);}
            catch (error) {if (!stopped) onError(error);}
            if (!stopped) timer = setTimeout(poll, 5000);
        }
        poll(); return () => {stopped = true; clearTimeout(timer);};
    }, [refresh]);
    const endpoints = data?.endpoints || [];
    const selectedEndpoint = endpoints.find(endpoint => `${endpoint.domain}/${endpoint.label}` === selected);
    const available = selectedEndpoint?.available_translations || [];
    const normalized = code.trim().toLowerCase();
    const selectedState = selectedEndpoint ? translationState(selectedEndpoint, normalized) : null;
    const validCode = /^[a-z0-9][a-z0-9_-]{0,29}$/.test(normalized);
    function action(endpoint, translation, name) {
        execute('runtime.cache', {domain: endpoint.domain, endpoint: endpoint.label, action: name, translation});
    }
    return <>
        <Panel title="Translation memory" detail="See what is in memory, then select a translation to inspect its workers. Current residency is refreshed every five seconds.">
            <div className="filter-grid">
                <label>Runtime endpoint<select aria-label="Runtime endpoint" className="form-select" value={selected} onChange={event => setSelected(event.target.value)}><option value="">Select endpoint</option>{endpoints.map(endpoint => <option key={`${endpoint.domain}/${endpoint.label}`} value={`${endpoint.domain}/${endpoint.label}`}>{endpoint.domain} / {endpoint.label} · {endpoint.kind}</option>)}</select></label>
                <label>Translation<input list="available-translations" className="form-control" value={code} onChange={event => setCode(event.target.value)} placeholder="kjv"/><datalist id="available-translations">{available.map(item => <option key={item.translation} value={item.translation}>{translationState(selectedEndpoint, item.translation).status}</option>)}</datalist></label>
                <div className="d-flex gap-2 align-items-end"><button className="btn btn-primary" disabled={!selectedEndpoint || !validCode || selectedState?.ready} onClick={() => action(selectedEndpoint, normalized, 'warm')}>{selectedState?.ready ? 'Already warm' : 'Warm translation'}</button></div>
            </div>
            {selectedState && validCode && <div className="warm-selection" aria-live="polite"><MemoryStatus row={selectedState}/><span>{normalized.toUpperCase()} · {number(selectedState.resident.length)} / {number(selectedState.expected)} workers retain data · {number(selectedState.readyCount)} ready{selectedState.configured ? ' · configured for startup warming' : ''}</span>{selectedState.reasons.map(reason => <small key={reason}>{reason}</small>)}{!selectedState.completeReport && <small>Some workers have not reported; their memory state is unknown.</small>}</div>}
        </Panel>
        {!data ? <Busy/> : !endpoints.length ? <Empty>No runtime endpoints are configured.</Empty> : endpoints.map(endpoint => {
            const key = `${endpoint.domain}/${endpoint.label}`;
            const rows = translationMemory(endpoint);
            const opened = expanded[key] ? translationState(endpoint, expanded[key]) : null;
            return <Panel key={key} title={`${endpoint.domain} / ${endpoint.label}`} detail={`${endpoint.kind} · ${rows.length} translation${rows.length === 1 ? '' : 's'} currently resident · ${endpoint.workers?.length || 0} worker${endpoint.workers?.length === 1 ? '' : 's'} reported`} actions={<Badge tone={endpoint.complete ? 'success' : 'warning'}>{endpoint.complete ? 'All workers reported' : 'Partial report'}</Badge>}>
                {opened ? <WorkerLayer endpoint={endpoint} row={opened} onDetail={onDetail} onBack={() => setExpanded({...expanded, [key]: ''})}/> : <>
                    {rows.length ? <DataTable rows={rows} rowKey={row => row.code} onSelect={row => setExpanded({...expanded, [key]: row.code})} columns={[
                        {key: 'code', label: 'Translation', render: row => <span>{row.code.toUpperCase()}<small className="cell-note">{row.configured ? 'Startup warming configured' : 'Currently in memory'}</small></span>},
                        {key: 'status', label: 'Readiness', render: row => <div><MemoryStatus row={row}/>{row.reasons.map(reason => <small className="cell-note" key={reason}>{reason}</small>)}</div>},
                        {key: 'workers', label: 'Worker coverage', render: row => <div>{number(row.resident.length)} / {number(row.expected)} resident<small className="cell-note">{number(row.readyCount)} / {number(row.expected)} ready</small></div>},
                        {key: 'query_chapters', label: 'Query data per worker', render: row => {const holders = row.resident.filter(worker => worker.query_chapters != null); return holders.length ? <div>{countSpan(holders, 'query_chapters', 'chapter')}<small className="cell-note">{span(holders, 'query_bytes', bytes)} estimated · {holders.length} worker{holders.length === 1 ? '' : 's'}</small></div> : '—';}},
                        {key: 'search_verses', label: 'Search data per worker', render: row => {const holders = row.resident.filter(worker => worker.search_verses != null); return holders.length ? <div>{span(holders, 'search_verses')} verses<small className="cell-note">{span(holders, 'search_bytes', bytes)} corpus / index estimate · {holders.length} worker{holders.length === 1 ? '' : 's'}</small></div> : '—';}},
                        {key: 'snapshot_bytes', label: 'Snapshot per worker', render: row => {const holders = row.resident.filter(worker => worker.snapshot_present); return holders.length ? <div>{span(holders, 'snapshot_bytes', bytes)} estimated<small className="cell-note">{holders.length} worker{holders.length === 1 ? '' : 's'}</small></div> : '—';}},
                        {key: 'actions', label: 'All workers', render: row => <div className="btn-group">{!row.ready && <button className="btn btn-sm btn-outline-primary" onClick={() => action(endpoint, row.code, 'warm')}>Warm</button>}<button className="btn btn-sm btn-outline-primary" onClick={() => action(endpoint, row.code, 'reload')}>Reload</button><button className="btn btn-sm btn-outline-danger" onClick={() => action(endpoint, row.code, 'drop')}>Drop</button></div>},
                    ]}/> : <Empty>{endpoint.complete ? 'No translations are currently retained in worker memory.' : 'No resident translations have been reported yet.'}</Empty>}
                    <p className="panel-note">Ranges show differences between workers, not a combined memory total. Select a translation for individual worker contents and measured memory.</p>
                </>}
                <details className="worker-details"><summary>{number(endpoint.available_translations?.length || 0)} translations available on disk</summary><DataTable rows={endpoint.available_translations || []} onSelect={row => onDetail(`${row.translation.toUpperCase()} on disk`, row)} columns={[
                    {key: 'translation', label: 'Translation', render: row => row.translation.toUpperCase()},
                    {key: 'memory', label: 'Current memory', render: row => <MemoryStatus row={translationState(endpoint, row.translation)}/>},
                    {key: 'allocated_bytes', label: 'Allocated disk', render: row => bytes(row.allocated_bytes)},
                    {key: 'logical_bytes', label: 'File contents', render: row => bytes(row.logical_bytes)},
                    {key: 'files', label: 'Files', render: row => number(row.files)},
                    {key: 'warm', label: 'All workers', render: row => {const state = translationState(endpoint, row.translation); return <button className="btn btn-sm btn-outline-primary" disabled={state.ready} onClick={() => action(endpoint, row.translation, 'warm')}>{state.ready ? 'Already warm' : 'Warm translation'}</button>;}},
                ]}/></details>
                {!!endpoint.configured_warm_translations?.length && <p className="panel-note">Configured startup warm-ups: {endpoint.configured_warm_translations.map(item => item.toUpperCase()).join(', ')}. Configuration describes startup intent; the table shows current memory.</p>}
                {endpoint.inventory_error && <div className="alert alert-warning m-3">{endpoint.inventory_error}</div>}
                {!!endpoint.errors?.length && <div className="alert alert-warning m-3">{endpoint.errors.map((error, index) => <div key={index}>{typeof error === 'string' ? error : error.error || 'Worker did not report.'}</div>)}</div>}
            </Panel>;
        })}
    </>;
}
