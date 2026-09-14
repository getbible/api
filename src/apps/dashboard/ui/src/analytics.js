export function rankingFilters(dimension, row, current = {}) {
    return {...current, ...(row.filters || {[dimension]: row.value})};
}
export const activeJob = status => ['queued', 'waiting', 'running'].includes(status);

export const mcpDimensions = [
    ['mcp_method', 'MCP method'], ['mcp_tool', 'MCP tool'],
    ['mcp_client_name', 'Declared MCP client'], ['mcp_client_version', 'MCP client version'],
    ['upstream_service', 'Upstream service'], ['upstream_api_version', 'Upstream API version'],
    ['upstream_operation', 'Upstream operation'],
];
export const mcpOutcomes = ['success', 'tool_error', 'protocol_error', 'transport_error', 'unknown'];
const mcpFailures = new Set(['tool_error', 'protocol_error', 'transport_error']);

export function mcpReportFilters(filters = {}) {
    return {...filters, endpoint_kind: 'mcp', origin_only: 'true'};
}

export function mcpFilters(filters = {}) {
    const next = mcpReportFilters(filters);
    // An MCP host has no Bible version endpoints or content usage dimensions.
    for (const key of ['version', 'translation', 'reference', 'search', 'book', 'usage', 'operation']) delete next[key];
    if (filters.endpoint_kind !== 'mcp') delete next.endpoint;
    return next;
}

export function requestFailed(request) {
    return Number(request.status) >= 400 || request.mcp_error === true || mcpFailures.has(request.mcp_outcome);
}

export function editTrafficFilter(filters, key, value) {
    if (key === 'endpoint_kind' && value === 'mcp') return mcpFilters(filters);
    const next = {...filters, [key]: value};
    if ((key === 'successful' && value !== 'true') || key === 'endpoint_kind') delete next.usage;
    if (key === 'endpoint_kind' && value !== 'mcp') {
        for (const [dimension] of mcpDimensions) delete next[dimension];
        delete next.mcp_outcome;
        if (filters.endpoint_kind === 'mcp') delete next.endpoint;
    }
    if (key === 'mcp_outcome' && mcpFailures.has(value)) {
        delete next.successful;
        delete next.usage;
    }
    if (key === 'successful' && value === 'true' && mcpFailures.has(next.mcp_outcome)) delete next.mcp_outcome;
    if (key === 'status' && /^\d{3}$/.test(String(value)) && !(Number(value) >= 200 && Number(value) < 300) && Number(value) !== 304) {
        delete next.usage;
        delete next.successful;
    }
    return next;
}
