import React, {useEffect, useState} from 'react';
import {api, bytes, date, number} from './api.js';
import {Panel, Busy, Badge, DataTable, ErrorNotice} from './components.jsx';
import {capacitySetting} from './upgrades.js';

const words = value => String(value || 'unknown').replaceAll('_', ' ');
const rate = value => value == null ? 'Unknown' : `${value < 0 ? '−' : ''}${bytes(Math.abs(value))}/s`;
export default function Capacity({refresh, execute}) {
    const [report, setReport] = useState(null);
    const [error, setError] = useState(null);
    useEffect(() => {
        let stopped = false, timer;
        const controller = new AbortController();
        async function poll() {
            try {const value = await api('capacity', {signal: controller.signal}); if (!stopped) {setReport(value); setError(null);}}
            catch (problem) {if (!stopped && problem.name !== 'AbortError') setError(problem);}
            if (!stopped) timer = setTimeout(poll, 30000);
        }
        poll(); return () => {stopped = true; clearTimeout(timer); controller.abort();};
    }, [refresh]);
    const stale = Boolean(error || report?.stale || report?.state !== 'observed');
    const collection = report?.collection || {};
    return <Panel title="Capacity and sizing advice" detail="Measured limits and repeated saturation; suggestions require operator review and never change settings automatically.">
        <ErrorNotice error={error}/>
        {!report ? !error && <Busy>Reading capacity observations…</Busy> : <>
            <div className={`alert ${stale ? 'alert-warning' : 'alert-info'}`} role="status"><strong>{words(report.state)}</strong> · Last sample: {date(report.sampled_at)}<div>{report.note}</div></div>
            <div className="fact-list">
                <div><span>Collection</span><strong>{stale ? 'Unknown — observations are not current' : words(collection.state)}</strong></div>
                <div><span>Unread backlog</span><strong>{bytes(collection.unread_bytes)} · {number(collection.unread_files)} files</strong></div>
                <div><span>Transport / retained archives</span><strong>{bytes(collection.budgeted_spool_bytes)} / {bytes(collection.retained_archive_bytes)}</strong></div>
                <div><span>Producer / collector throughput</span><strong>{rate(collection.producer_bytes_per_second)} / {rate(collection.collector_bytes_per_second)}</strong></div>
                <div><span>Backlog growth / continuous backlog</span><strong>{rate(collection.backlog_growth_bytes_per_second)} / {number(collection.backlog_observed_seconds)} seconds</strong></div>
                <div><span>Rate window / peak window</span><strong>{number(collection.rate_window_seconds)} seconds / {number(report.window_seconds / 3600)} hours</strong></div>
            </div>
            <DataTable rowKey={row => row.id} rows={report.limits || []} columns={[
                {key: 'label', label: 'Limit', render: row => <><strong>{row.label}</strong><small className="d-block">{row.setting || 'Host capacity'} · {row.unit}</small></>},
                {key: 'used', label: 'Usage / effective limit', render: row => row.available ? `${number(row.used, 2)} / ${number(row.effective_limit, 2)} ${row.unit}` : 'Unavailable'},
                {key: 'high_water', label: 'Observed peak', render: row => row.available ? `${number(row.high_water, 2)} ${row.unit}` : 'Unknown'},
                {key: 'episodes', label: 'Saturation', render: row => row.available ? <>{number(row.episodes)} episodes<small className="d-block">{number(row.saturated_samples)} / {number(row.samples)} samples; {number(row.saturated_seconds)} / {number(row.observed_seconds)} observed seconds</small><small className="d-block">At or above {number(row.saturation_threshold * 100)}% of limit</small></> : 'Unknown'},
                {key: 'configuration', label: 'Configured value / owner', render: row => <>{row.configuration?.value ?? 'Not observable'}<small className="d-block">{words(row.configuration?.owner)}{row.configuration?.editable ? ' · editable' : ' · change at source'}</small><small className="d-block">{row.configuration?.note}</small></>},
                {key: 'recommendation', label: 'Recommendation', render: row => {
                    const change = capacitySetting(row, stale);
                    return <><Badge tone={row.recommendation?.status === 'adequate' ? 'success' : 'info'}>{words(row.recommendation?.status)}</Badge>{row.recommendation?.value != null && !stale && <strong className="d-block">{number(row.recommendation.value, 2)} {row.unit}</strong>}<small className="d-block">{row.recommendation?.reason}</small>{row.recommendation?.assumptions && <small className="d-block">{row.recommendation.assumptions}</small>}{change && <button className="btn btn-sm btn-outline-primary mt-2" type="button" onClick={() => execute('settings.set', change, {title: `Review ${change.key} = ${change.value}`, description: 'This is an observed-demand recommendation, not an automatic correction or a guarantee. Confirm free capacity and collection health before applying.'})}>Review suggested setting</button>}</>;
                }},
            ]}/>
            {!!report.incidents?.length && <><h3 className="h6 mt-3">Open capacity incidents</h3><DataTable rows={report.incidents} rowKey={row => row.id} columns={[{key: 'id', label: 'Condition'}, {key: 'since', label: 'Since', render: row => date(row.since)}, {key: 'last_sent', label: 'Last notification', render: row => date(row.last_sent)}, {key: 'last_event', label: 'Last transition', render: row => words(row.last_event)}]}/></>}
            {!!Object.keys(report.problems || {}).length && <details className="mt-3"><summary>Collection and reclamation diagnostics</summary><pre className="record-detail">{JSON.stringify(report.problems, null, 2)}</pre></details>}
        </>}
    </Panel>;
}
