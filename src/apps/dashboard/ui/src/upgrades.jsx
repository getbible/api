import React, {useEffect, useState} from 'react';
import {api, date} from './api.js';
import {Busy, Empty, Badge, DataTable, ErrorNotice} from './components.jsx';
import {defaultTargets, selectableTarget, selectedTargets, upgradeSubmission} from './upgrades.js';

export default function Upgrades({execute, refresh, paused = false}) {
    const [plan, setPlan] = useState(null);
    const [error, setError] = useState(null);
    const [revision, setRevision] = useState(0);
    const [loading, setLoading] = useState(true);
    const [selection, setSelection] = useState([]);
    const [force, setForce] = useState(false);
    const [retry, setRetry] = useState(false);
    useEffect(() => {
        let stopped = false;
        const controller = new AbortController();
        setLoading(true); setError(null);
        api('upgrades', {signal: controller.signal}).then(value => {
            if (!stopped) {setPlan(value); setSelection(defaultTargets(value)); setForce(false); setRetry(false);}
        }).catch(problem => {if (!stopped && problem.name !== 'AbortError') setError(problem);})
            .finally(() => {if (!stopped) setLoading(false);});
        return () => {stopped = true; controller.abort();};
    }, [refresh, revision]);
    const chosen = selectedTargets(plan, selection, {force, retry});
    const ready = plan && !loading && !error && !paused;
    const toggle = id => setSelection(previous => previous.includes(id) ? previous.filter(value => value !== id) : [...previous, id]);
    return <div className="upgrade-plan">
        <p>Only selected targets will be upgraded. Static targets update their software and configuration—not Bible files. Skipped changes remain pending.</p>
        <ErrorNotice error={error}/>
        <div className="d-flex gap-2 flex-wrap mb-3">
            <button type="button" className="btn btn-outline-secondary" disabled={loading} onClick={() => setRevision(value => value + 1)}>Refresh upgrade plan</button>
            <button type="button" className="btn btn-outline-secondary" disabled={!ready} onClick={() => {setSelection(defaultTargets(plan)); setRetry(false);}}>Select changed targets</button>
            <button type="button" className="btn btn-outline-secondary" disabled={!ready} onClick={() => setSelection([])}>Clear selection</button>
            <label className="form-check"><input type="checkbox" className="form-check-input" checked={force} disabled={!ready} onChange={event => setForce(event.target.checked)}/>Allow forced redeployment of unchanged targets</label>
            <label className="form-check"><input type="checkbox" className="form-check-input" checked={retry} disabled={!ready} onChange={event => {
                setRetry(event.target.checked);
                if (event.target.checked) setSelection((plan?.targets || []).filter(row => ['failed', 'interrupted'].includes(row.outcome)).map(row => row.id));
            }}/>Retry failed or interrupted targets only</label>
        </div>
        {loading ? <Busy>Inspecting installed releases and target readiness…</Busy> : plan ? <>
            <div className="alert alert-info" role="status">Release {plan.version}: {plan.pending} target(s) pending. {chosen.length} selected. Serving health is separate from upgrade completion.</div>
            <DataTable rowKey={row => row.id} rows={plan.targets || []} columns={[
                {key: 'selected', label: 'Upgrade', render: row => <input type="checkbox" aria-label={`Upgrade ${row.id}`} checked={chosen.includes(row.id)} disabled={!ready || !selectableTarget(row, force) || (retry && !['failed', 'interrupted'].includes(row.outcome))} onChange={() => toggle(row.id)}/>},
                {key: 'id', label: 'Target', render: row => <><strong>{row.id}</strong><small className="d-block">{row.reason}</small>{row.last_error && <small className="d-block text-warning">{row.last_error}</small>}</>},
                {key: 'status', label: 'Upgrade state', render: row => <Badge tone={row.status === 'current' ? 'success' : row.status === 'blocked' ? 'warning' : 'info'}>{row.status}</Badge>},
                {key: 'serving', label: 'Serving', render: row => <Badge tone={row.serving === 'ready' ? 'success' : 'warning'}>{row.serving}</Badge>},
                {key: 'outcome', label: 'Last result', render: row => <>{row.outcome}<small className="d-block">{date(row.last_attempt)}</small></>},
                {key: 'fingerprints', label: 'Implementation', render: row => <details><summary>Fingerprints</summary><small className="d-block text-break">Desired: {row.desired_fingerprint || 'Unavailable'}</small><small className="d-block text-break">Applied: {row.applied_fingerprint || 'Not recorded'}</small></details>},
            ]}/>
            <p className="text-secondary mt-3">{plan.note}</p>
        </> : <Empty>The upgrade plan is unavailable. Refresh to retry.</Empty>}
        <button type="button" className="btn btn-primary" disabled={!ready || !chosen.length} onClick={() => {
            try {execute('system.update', upgradeSubmission(plan, selection, {force, retry}), {
                title: `Upgrade ${chosen.length} selected target(s)`,
                description: 'The manager rechecks this plan before changing anything. Unselected generations remain running; capacity checks may reject an unsafe overlap. Whole-container replacement is a separate restart.'});}
            catch (problem) {setError(problem);}
        }}>Review selected upgrades</button>
        {!chosen.length && !loading && <small className="d-block mt-2">Nothing selected. No upgrade will run.</small>}
    </div>;
}
