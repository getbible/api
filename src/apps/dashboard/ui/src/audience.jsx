import React, {useState} from 'react';
import {number, bytes} from './api.js';
import {DataTable, Panel} from './components.jsx';
import {useReports, ReportState} from './reporting.jsx';

function Consumers({dimension, title, label, filters, range, live, refresh, onFilter, onError}) {
    const [text, setText] = useState('');
    const [search, setSearch] = useState('');
    const {audience} = useReports({page: 'Audience', range, live, refresh, onError, interval: 5000,
        filters: {...filters, dimension, top: 1000, [`${dimension}_contains`]: search}});
    const rows = audience.data?.[dimension === 'referrer' ? 'referrers' : 'user_agents'] || [];
    return <Panel title={title} detail="Origin requests, including errors. Select a row to explore its traffic.">
        <form className="filter-grid" onSubmit={event => {event.preventDefault(); setSearch(text);}}><label>Find {label.toLowerCase()}<input className="form-control" value={text} onChange={event => setText(event.target.value)} placeholder={`Part of a ${label.toLowerCase()}`}/></label><div className="d-flex gap-2 align-items-end"><button className="btn btn-sm btn-primary">Search</button><button type="button" className="btn btn-sm btn-outline-secondary" onClick={() => {setText(''); setSearch('');}}>Clear</button></div></form>
        <ReportState report={audience} label={title}><DataTable rows={rows} rowKey={row => row.value} onSelect={row => onFilter(dimension, row.value, row.filters)} columns={[
            {key: 'value', label, render: row => <span className="consumer-value" title={row.value}>{row.value}</span>},
            {key: 'calls', label: 'Requests', render: row => number(row.calls)},
            {key: 'errors', label: 'Errors', render: row => number(row.errors)},
            {key: 'bytes', label: 'Transfer', render: row => bytes(row.bytes)},
        ]}/></ReportState>
        <div className="table-footer"><small>{rows?.length === 1000 ? 'Top 1,000 matching values. Search to narrow the results.' : `${number(rows?.length || 0)} matching values`} · requests without a recorded {label.toLowerCase()} are omitted.</small></div>
    </Panel>;
}
export default function Audience(props) {
    return <><p className="text-secondary">Referrers and user agents are recorded request fields. User agents may identify software, robots or browsers; these reported values do not establish a person's identity. Select a value to inspect matching requests in this time range.</p><Consumers {...props} dimension="referrer" title="Referrers" label="Referrer"/><Consumers {...props} dimension="user_agent" title="User agents and robots" label="User agent"/></>;
}
