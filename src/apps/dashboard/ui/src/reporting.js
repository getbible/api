import {api, query} from './api.js';

export function reportPaths(page, range, live, filters = {}, now = Math.floor(Date.now() / 1000)) {
    const end = live ? now : range.end;
    const start = live ? end - 900 : range.start;
    const bucket_seconds = live ? 5 : Math.max(1, Math.ceil((end - start) / 400));
    const args = query({...filters, start, end, bucket_seconds});
    if (page === 'Overview') return {
        overview: `overview?${args}&dimensions=auth,endpoint,status,translation,search,reference,book,ip,referrer,user_agent`,
        history: `history?${args}`,
    };
    if (page === 'Resources') return {metrics: `metrics?${query({start, end, bucket_seconds})}`};
    if (page === 'MCP traffic') return {mcp: `mcp?${args}`};
    if (page === 'Audience') return {audience: `audience?${args}`};
    return {};
}

export const emptyReport = () => ({data: null, error: null, loading: true, preparing: false, progress: null});

// Each panel has one in-flight request and its own completion-based timer.
// Cancelling a selection also guards against transports that ignore abort.
export function startReports({paths, live = false, interval = 2000, onChange, onError = () => {}, onUpdate = () => {},
    load = api, schedule = setTimeout, cancel = clearTimeout}) {
    const controller = new AbortController();
    const timers = new Map();
    let stopped = false;

    async function read(name, previous = emptyReport()) {
        if (stopped) return;
        const state = {...previous, loading: true};
        onChange(name, state);
        let next;
        let retry = live ? interval : null;
        try {
            const data = await load(paths()[name], {signal: controller.signal});
            if (stopped) return;
            if (data.state === 'preparing') {
                next = {...state, error: null, preparing: true, progress: data.progress || null};
                retry = Math.max(500, Math.min(30000, Number(data.retry_after) * 1000 || 2000));
            } else {
                next = {data, error: null, loading: false, preparing: false, progress: null};
                onUpdate();
            }
        } catch (error) {
            if (stopped || error.name === 'AbortError') return;
            next = {...state, error, loading: false, preparing: false, progress: null};
            if (error.status === 401) {
                retry = null;
                onError(error);
            }
        }
        if (stopped) return;
        onChange(name, next);
        if (retry !== null) timers.set(name, schedule(() => read(name, next), retry));
    }

    for (const name of Object.keys(paths())) read(name);
    return () => {
        stopped = true;
        controller.abort();
        for (const timer of timers.values()) cancel(timer);
        timers.clear();
    };
}
