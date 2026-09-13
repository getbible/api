export function rankingFilters(dimension, row, current = {}) {
    return {...current, ...(row.filters || {[dimension]: row.value})};
}
export const activeJob = status => ['queued', 'waiting', 'running'].includes(status);

export function editTrafficFilter(filters, key, value) {
    const next = {...filters, [key]: value};
    if ((key === 'successful' && value !== 'true') || key === 'endpoint_kind') delete next.usage;
    if (key === 'status' && /^\d{3}$/.test(String(value)) && !(Number(value) >= 200 && Number(value) < 300) && Number(value) !== 304) {
        delete next.usage;
        delete next.successful;
    }
    return next;
}
