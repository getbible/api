import React, {useEffect, useState} from 'react';
import {api, query, number, bytes} from './api.js';
import {Busy, DataTable, Panel} from './components.jsx';

function Consumers({dimension, title, label, filters, range, live, refresh, onFilter, onError}) {
    const [text, setText] = useState('');
    const [search, setSearch] = useState('');
    const [rows, setRows] = useState(null);
    useEffect(() => {
        let stopped = false; let timer;
        const controller = new AbortController();
        async function poll() {
            const end = live ? Math.floor(Date.now() / 1000) : range.end;
            try {
                const result = await api(`audience?${query({...filters, start: live ? end - 900 : range.start, end, top: 1000, [`${dimension}_contains`]: search})}`, {signal: controller.signal});
                if (!stopped) setRows(result[dimension === 'referrer' ? 'referrers' : 'user_agents'] || []);
            } catch (error) {if (!stopped && error.name !== 'AbortError') onError(error);}
            if (!stopped) timer = setTimeout(poll, live ? 5000 : 15000);
        }
        setRows(null); poll(); return () => {stopped = true; clearTimeout(timer); controller.abort();};
    }, [dimension, search, filters, range.start, range.end, live, refresh]);
    return <Panel title={title} detail="Origin requests, including errors. Select a row to explore its traffic.">
        <form className="filter-grid" onSubmit={event => {event.preventDefault(); setSearch(text);}}><label>Find {label.toLowerCase()}<input className="form-control" value={text} onChange={event => setText(event.target.value)} placeholder={`Part of a ${label.toLowerCase()}`}/></label><div className="d-flex gap-2 align-items-end"><button className="btn btn-sm btn-primary">Search</button><button type="button" className="btn btn-sm btn-outline-secondary" onClick={() => {setText(''); setSearch('');}}>Clear</button></div></form>
        {rows ? <DataTable rows={rows} rowKey={row => row.value} onSelect={row => onFilter(dimension, row.value, row.filters)} columns={[
            {key: 'value', label, render: row => <span className="consumer-value" title={row.value}>{row.value}</span>},
            {key: 'calls', label: 'Requests', render: row => number(row.calls)},
            {key: 'errors', label: 'Server errors', render: row => number(row.errors)},
            {key: 'bytes', label: 'Transfer', render: row => bytes(row.bytes)},
        ]}/> : <Busy/>}
        <div className="table-footer"><small>{rows?.length === 1000 ? 'Top 1,000 matching values. Search to narrow the results.' : `${number(rows?.length || 0)} matching values`} · requests without a recorded {label.toLowerCase()} are omitted.</small></div>
    </Panel>;
}
export default function Audience(props) {
    return <><p className="text-secondary">Referrers and user agents are separate request fields. Each link opens the matching requests with the selected time range and filters.</p><Consumers {...props} dimension="referrer" title="Referrers" label="Referrer"/><Consumers {...props} dimension="user_agent" title="User agents" label="User agent"/></>;
}
