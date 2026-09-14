import assert from 'node:assert/strict';
import {test} from 'node:test';
import {rankingFilters, activeJob, editTrafficFilter, mcpFilters, mcpReportFilters, requestFailed} from '../src/analytics.js';

test('usage drilldowns preserve the returned successful origin and endpoint scope', () => {
    const row = {value: 'faith & hope', filters: {search: 'faith & hope', successful: 'true', endpoint_kind: 'search', origin_only: 'true', usage: 'search'}};
    assert.deepEqual(rankingFilters('search', row, {version: 'v2'}), {version: 'v2', ...row.filters});
});

test('book labels do not replace the numeric identifier in drilldown filters', () => {
    const row = {value: '73', label: 'Extra book', filters: {book: '73', usage: 'book', successful: 'true'}};
    assert.equal(rankingFilters('book', row).book, '73');
});

test('waiting management jobs continue polling instead of announcing completion', () => {
    for (const state of ['queued', 'waiting', 'running']) assert.equal(activeJob(state), true);
    for (const state of ['succeeded', 'failed']) assert.equal(activeJob(state), false);
});


test('explicit traffic controls remove conflicting ranking scope without losing the selected consumer', () => {
    const filters = {usage: 'search', successful: 'true', search: 'faith', endpoint_kind: 'search', origin_only: 'true'};
    const all = editTrafficFilter(filters, 'successful', '');
    assert.equal(all.usage, undefined);
    assert.equal(all.search, 'faith');
    assert.equal(all.origin_only, 'true');
    const error = editTrafficFilter(filters, 'status', '404');
    assert.equal(error.usage, undefined);
    assert.equal(error.successful, undefined);
    assert.equal(error.status, '404');
    assert.equal(editTrafficFilter(filters, 'endpoint_kind', 'query').usage, undefined);
});

test('MCP navigation removes hosted API version scope while retaining consumer and upstream version filters', () => {
    const filters = {endpoint_kind: 'search', endpoint: 'api.example/v2', version: 'v2', translation: 'kjv',
        search: 'faith', reference: 'John 3:16', book: '43', usage: 'search', operation: 'search',
        user_agent: 'ExampleRobot/1.0', status: '200', upstream_api_version: 'v3'};
    const scoped = mcpFilters(filters);
    assert.deepEqual(scoped, {endpoint_kind: 'mcp', origin_only: 'true', user_agent: 'ExampleRobot/1.0', status: '200', upstream_api_version: 'v3'});
    assert.equal(filters.version, 'v2');
    assert.deepEqual(editTrafficFilter(filters, 'endpoint_kind', 'mcp'), scoped);
});

test('MCP operation drilldowns preserve the dedicated domain, consumer and origin request scope', () => {
    const scoped = mcpFilters({endpoint_kind: 'mcp', endpoint: 'mcp.example', user_agent: 'ExampleRobot/1.0'});
    const row = {value: 'getChapter', filters: {...scoped, upstream_operation: 'getChapter', upstream_service: 'api', upstream_api_version: 'v3'}};
    const next = rankingFilters('upstream_operation', row, scoped);
    assert.equal(next.endpoint, 'mcp.example');
    assert.equal(next.endpoint_kind, 'mcp');
    assert.equal(next.user_agent, 'ExampleRobot/1.0');
    assert.equal(next.origin_only, 'true');
    assert.equal(next.upstream_operation, 'getChapter');
    assert.equal(next.upstream_api_version, 'v3');
    assert.equal(next.version, undefined);
});

test('HTTP 200 MCP errors are visible and unknown streamed outcomes are not invented failures', () => {
    for (const mcp_outcome of ['tool_error', 'protocol_error', 'transport_error']) {
        assert.equal(requestFailed({status: 200, endpoint_kind: 'mcp', mcp_outcome}), true);
    }
    assert.equal(requestFailed({status: 403, endpoint_kind: 'mcp'}), true);
    assert.equal(requestFailed({status: 200, mcp_error: true}), true);
    for (const mcp_outcome of ['success', 'unknown', '']) {
        assert.equal(requestFailed({status: 200, endpoint_kind: 'mcp', mcp_outcome}), false);
    }
    assert.equal(requestFailed({status: 500, endpoint_kind: 'search'}), true);
});

test('MCP outcome controls expose protocol failures without contradictory success or API filters', () => {
    const next = editTrafficFilter({endpoint_kind: 'mcp', status: '200', successful: 'true', user_agent: 'ExampleRobot/1.0'}, 'mcp_outcome', 'tool_error');
    assert.equal(next.successful, undefined);
    assert.equal(next.status, '200');
    assert.equal(next.user_agent, 'ExampleRobot/1.0');
    assert.equal(editTrafficFilter(next, 'successful', 'true').mcp_outcome, undefined);
    const query = editTrafficFilter({...next, endpoint: 'mcp.example', mcp_tool: 'call_api_operation', upstream_api_version: 'v3'}, 'endpoint_kind', 'query');
    assert.equal(query.endpoint, undefined);
    assert.equal(query.mcp_outcome, undefined);
    assert.equal(query.mcp_tool, undefined);
    assert.equal(query.upstream_api_version, undefined);
    assert.equal(query.user_agent, 'ExampleRobot/1.0');
});

test('selecting all endpoint kinds clears hidden MCP filters and the MCP-only domain', () => {
    const next = editTrafficFilter({endpoint_kind: 'mcp', endpoint: 'mcp.example', mcp_tool: 'call_api_operation',
        mcp_outcome: 'tool_error', upstream_api_version: 'v3', user_agent: 'ExampleRobot/1.0'}, 'endpoint_kind', '');
    assert.deepEqual(next, {endpoint_kind: '', user_agent: 'ExampleRobot/1.0'});
});

test('removing the service chip keeps the selected MCP domain consistent between report and drilldown', () => {
    const filters = {endpoint: 'mcp.example', user_agent: 'ExampleRobot/1.0'};
    const report = mcpReportFilters(filters);
    assert.equal(report.endpoint, 'mcp.example');
    const scope = rankingFilters('mcp_method', {value: 'tools/call'}, report);
    const explorer = {...filters, ...scope};
    assert.deepEqual(explorer, {...report, mcp_method: 'tools/call'});
    assert.equal(explorer.endpoint_kind, 'mcp');
});
