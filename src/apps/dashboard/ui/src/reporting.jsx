import React, {useEffect, useState} from 'react';
import {Busy, ErrorNotice} from './components.jsx';
import {emptyReport, reportPaths, startReports} from './reporting.js';

export function useReports({page, range, live, filters, refresh, enabled = true, interval = 2000, onError, onUpdate}) {
    const key = JSON.stringify([page, range.start, range.end, live, filters, refresh, enabled, interval]);
    const [reports, setReports] = useState({key: null, values: {}});
    useEffect(() => {
        setReports({key, values: {}});
        if (!enabled) return;
        return startReports({
            paths: () => reportPaths(page, range, live, filters), live, interval, onError, onUpdate,
            onChange: (name, state) => setReports(previous => ({key,
                values: {...(previous.key === key ? previous.values : {}), [name]: state}})),
        });
    }, [key]);
    // A new selection must not display the previous range before its effect runs.
    const values = reports.key === key ? reports.values : {};
    return Object.fromEntries(Object.keys(reportPaths(page, range, live, filters))
        .map(name => [name, values[name] || emptyReport()]));
}

export function ReportState({report, label, children}) {
    return <>
        <ErrorNotice error={report.error && new Error(`${label}: ${report.error.message}`)}/>
        {report.preparing && <div className="alert alert-info py-2" role="status">Preparing {label.toLowerCase()} for this time range…</div>}
        {report.data ? children : report.loading && !report.preparing ? <Busy>Loading {label.toLowerCase()}…</Busy> : null}
    </>;
}
