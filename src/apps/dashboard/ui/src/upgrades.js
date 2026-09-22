// The server owns eligibility and verifies plan identity under its writer lock.
export function selectableTarget(row, force = false) {
    return !['blocked', 'updating'].includes(row.status) && (row.eligible || force);
}
export function selectedTargets(plan, selection, {force = false, retry = false} = {}) {
    const wanted = new Set(selection);
    return (plan?.targets || []).filter(row => wanted.has(row.id) && selectableTarget(row, force) &&
        (!retry || ['failed', 'interrupted'].includes(row.outcome))).map(row => row.id);
}
export function defaultTargets(plan) {
    return (plan?.targets || []).filter(row => selectableTarget(row)).map(row => row.id);
}
export function upgradeSubmission(plan, selection, options = {}) {
    if (!plan || !/^[a-f0-9]{64}$/.test(plan.plan_id)) throw new Error('Refresh the upgrade plan before applying.');
    return {targets: selectedTargets(plan, selection, options), plan_id: plan.plan_id,
        force: options.force === true, retry: options.retry === true};
}
export function capacitySetting(row, stale = false) {
    const value = row?.recommendation?.value;
    if (stale || row?.recommendation?.status !== 'suggested' || !Number.isFinite(value) || value < 0 ||
        !row?.configuration?.editable || row.configuration.owner !== 'saved' ||
        !['TELEMETRY_SPOOL_MAX_GIB', 'TELEMETRY_MAX_GIB'].includes(row.setting)) return null;
    return {key: row.setting, value: String(value)};
}
