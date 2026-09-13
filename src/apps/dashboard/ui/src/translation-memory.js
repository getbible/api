// Cache quantities are per worker. Shared objects must never be added together
// and presented as a measurement of unique translation memory.
export function workerTranslation(worker, code, kind, now = Date.now() / 1000) {
    const cache = worker.cache || {};
    const query = cache.query_translations?.[code];
    const search = cache.search_corpora?.translations?.[code];
    const snapshot = cache.translation_cache?.translations?.[code];
    const stale = query?.expired_chapters > 0 || [search, snapshot].some(item => item && (item.stale || (item.checked_at != null && cache.ttl_seconds != null && item.checked_at + cache.ttl_seconds <= now)));
    const reported = worker.translation_status?.[code];
    const resident = Boolean(query || search || snapshot);
    // A chapter cached by a normal query does not establish a fully warmed Bible.
    const ready = !stale && (reported?.ready ?? (kind === 'search' ? Boolean(search?.verses > 0 && search.indexes?.some(index => index.case_sensitive === false && index.fold_diacritics === true)) : query?.complete === true));
    return {code, pid: worker.pid, resident, ready: Boolean(ready), stale, reason: reported?.reason || '', retention_limited: reported?.retention_limited === true,
        query_chapters: query?.chapters, query_bytes: query?.estimated_bytes,
        search_verses: search?.verses, search_bytes: search?.estimated_bytes,
        snapshot_bytes: snapshot?.estimated_bytes, snapshot_present: Boolean(snapshot),
        ttl: cache.ttl_seconds, rss_bytes: worker.rss_bytes, private_bytes: worker.private_bytes,
        details: {query, search, snapshot, readiness: reported, activity: worker.activity}, worker};
}

export function translationMemory(endpoint, now = Date.now() / 1000) {
    const workers = endpoint.workers || [];
    const codes = new Set();
    for (const worker of workers) {
        for (const code of [...Object.keys(worker.cache?.query_translations || {}), ...Object.keys(worker.cache?.search_corpora?.translations || {}), ...Object.keys(worker.cache?.translation_cache?.translations || {})]) codes.add(code);
    }
    return [...codes].sort().map(code => translationState(endpoint, code, now));
}

export function translationState(endpoint, code, now = Date.now() / 1000) {
    const workers = (endpoint.workers || []).map(worker => workerTranslation(worker, code, endpoint.kind, now));
    const expected = endpoint.expected_workers ?? workers.length;
    const completeReport = endpoint.complete === true && workers.length > 0 && workers.length === expected;
    const resident = workers.filter(worker => worker.resident);
    const readyCount = workers.filter(worker => worker.ready).length;
    const stale = resident.some(worker => worker.stale);
    const ready = completeReport && readyCount === expected;
    const status = ready ? 'Warm' : stale ? 'Recheck on use' : resident.length ? 'Partly resident' : completeReport ? 'Not in memory' : 'Not reported';
    const configured = (endpoint.configured_warm_translations || []).includes(code);
    const reasons = [...new Set(workers.filter(worker => worker.resident && !worker.ready).map(worker => worker.reason).filter(Boolean))];
    return {code, workers, resident, expected, completeReport, readyCount, ready, stale, status, configured, reasons};
}

export function valueRange(workers, key) {
    const values = workers.map(worker => worker[key]).filter(value => Number.isFinite(value));
    if (!values.length) return null;
    return {min: Math.min(...values), max: Math.max(...values)};
}
