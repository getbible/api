import React, {useEffect, useMemo, useState} from 'react';
import {api, query, number} from './api.js';
import {Badge, Busy, DataTable, Panel} from './components.jsx';
import {Chart, lineOption} from './charts.jsx';
import Audience from './audience.jsx';
import {mcpReportFilters, rankingFilters} from './analytics.js';

const breakdowns = [
    ['endpoint', 'MCP domains', 'Origin requests to the protocol endpoint at /', 'Domain'],
    ['mcp_method', 'Protocol methods', 'Initialization, discovery, tool calls and notifications', 'Method'],
    ['mcp_tool', 'MCP tools', 'Recorded tool names, without tool arguments', 'Tool'],
    ['mcp_outcome', 'Protocol outcomes', 'Tool and protocol errors can have HTTP status 200', 'Outcome'],
    ['mcp_client_name', 'Declared clients', 'Client names supplied during initialization', 'Client'],
    ['mcp_client_version', 'Declared client versions', 'Client versions supplied during initialization', 'Client version'],
    ['upstream_service', 'Upstream API services', 'Service selected by a recorded API operation', 'Service'],
    ['upstream_api_version', 'Upstream API versions', 'API versions are tool inputs; the MCP host has no version paths', 'API version'],
    ['upstream_operation', 'Upstream API operations', 'Operation identifiers selected by recorded tool calls', 'Operation'],
    ['status', 'HTTP responses', 'Includes rejected and malformed origin requests', 'HTTP status'],
];

export default function McpTraffic({filters, range, live, refresh, onFilter, onError, onZoom}) {
    const [report, setReport] = useState(null);
    const scoped = useMemo(() => mcpReportFilters(filters), [filters]);
    useEffect(() => {
        let stopped = false;
        let timer;
        const controller = new AbortController();
        async function poll() {
            const end = live ? Math.floor(Date.now() / 1000) : range.end;
            try {
                const result = await api(`mcp?${query({...scoped, start: live ? end - 900 : range.start, end})}`, {signal: controller.signal});
                if (!stopped) setReport(result);
            } catch (error) {
                if (!stopped && error.name !== 'AbortError') onError(error);
            }
            if (!stopped) timer = setTimeout(poll, live ? 2000 : 15000);
        }
        setReport(null);
        poll();
        return () => {stopped = true; clearTimeout(timer); controller.abort();};
    }, [scoped, range.start, range.end, live, refresh]);

    function inspect(dimension, value, scope) {
        onFilter(dimension, value, rankingFilters(dimension, {value, filters: scope}, scoped));
    }
    if (!report) return <Busy>Loading MCP traffic…</Busy>;
    const cards = [
        ['MCP requests', number(report.mcp_requests ?? report.calls), `${number(report.unique_ips)} unique IPs`],
        ['Tool calls', number(report.mcp_tool_calls), 'Recorded tools/call requests'],
        ['Errors', number(report.mcp_errors ?? report.errors), `${number(report.http_errors)} HTTP errors; includes protocol failures`],
        ['Average duration', `${number(report.duration_ms, 1)} ms`, 'Observed origin request duration'],
        ['P95 duration', report.latency_ms?.p95 == null ? '—' : `${number(report.latency_ms.p95, 1)} ms`, 'Histogram estimate'],
    ];
    const durationChart = lineOption(report.series || [], [['duration_ms', 'Average duration (ms)']]);
    durationChart.xAxis.axisLabel = {hideOverlap: true};
    return <>
        <p className="text-secondary">MCP origin requests are counted once, including requests rejected before protocol handling. Protocol methods and outcomes appear when captured; user agents remain available independently of declared client metadata.</p>
        <div className="metric-grid">{cards.map(([name, value, detail]) => <div className="metric panel" key={name}><span>{name}</span><strong>{value}</strong><small>{detail}</small></div>)}</div>
        <div className="overview-grid">
            <Panel className="flow-panel" title="MCP requests and errors" detail="HTTP failures and captured MCP failures" actions={<button className="btn btn-sm btn-outline-secondary" onClick={() => inspect('endpoint_kind', 'mcp', scoped)}>Explore requests</button>}>
                <Chart label="MCP requests and errors over time" height={300} onZoom={onZoom} option={lineOption(report.series || [], [['calls', 'Requests'], ['errors', 'Errors']], {zoom: true})}/>
            </Panel>
            <Panel title="Request duration" detail="Includes the lifetime of streamed HTTP requests">
                <Chart label="Average MCP origin request duration in milliseconds" height={300} option={durationChart}/>
            </Panel>
        </div>
        <div className="resource-grid">
            {breakdowns.map(([dimension, title, detail, label]) => <Panel key={dimension} title={title} detail={detail}>
                <DataTable rows={report.breakdowns?.[dimension] || []} onSelect={row => inspect(dimension, row.value, row.filters)} columns={[
                    {key: 'value', label, render: row => <span className="consumer-value" title={String(row.value)}>{row.value || <Badge>Unrecorded</Badge>}</span>},
                    {key: 'calls', label: 'Requests', render: row => number(row.calls)},
                    {key: 'errors', label: 'Errors', render: row => number(row.errors)},
                    {key: 'duration_ms', label: 'Avg. ms', render: row => number(row.duration_ms, 1)},
                ]}/>
            </Panel>)}
        </div>
        <Audience filters={scoped} range={range} live={live} refresh={refresh} onFilter={inspect} onError={onError}/>
    </>;
}
