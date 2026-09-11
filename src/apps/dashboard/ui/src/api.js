let csrfToken = '';
export class ApiError extends Error {
    constructor(status, problem) {
        super(problem.detail || problem.message || problem.title || `Request failed (${status})`);
        this.status = status;
        this.problem = problem;
    }
}
export function setCsrf(token) { csrfToken = token || ''; }
export async function api(path, { method = 'GET', body, signal } = {}) {
    const response = await fetch(`/api/${path}`, {
        method, credentials: 'same-origin', cache: 'no-store', signal,
        headers: {
            Accept: 'application/json',
            ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}),
            ...(method !== 'GET' ? { 'X-CSRF-Token': csrfToken } : {}),
        },
        body: body === undefined ? undefined : JSON.stringify(body),
    });
    const value = await response.json().catch(() => ({ detail: 'The server returned an unreadable response.' }));
    if (!response.ok)
        throw new ApiError(response.status, value);
    if (value.csrf_token)
        setCsrf(value.csrf_token);
    return value;
}
export const post = (path, body = {}) => api(path, { method: 'POST', body });
export function query(values) {
    return new URLSearchParams(Object.entries(values).filter(([, v]) => v !== '' && v != null)).toString();
}
export const number = (n, digits = 0) => n == null ? '—' : Number(n).toLocaleString(undefined, { maximumFractionDigits: digits });
export function bytes(value) {
    if (value == null)
        return '—';
    if (value === 0)
        return '0 B';
    const order = Math.min(Math.floor(Math.log(Math.max(1, value)) / Math.log(1024)), 4);
    return `${number(value / (1024 ** order), order ? 1 : 0)} ${['B', 'KiB', 'MiB', 'GiB', 'TiB'][order]}`;
}
export const date = value => value ? new Date(typeof value === 'number' ? value * 1000 : value).toLocaleString() : '—';
