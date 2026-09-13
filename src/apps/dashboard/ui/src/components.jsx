import React from 'react';
export function ErrorNotice({ error, dismiss }) {
    return error ? <div className="alert alert-danger d-flex align-items-start gap-3" role="alert"><span className="flex-grow-1">{error.message || String(error)}</span>{dismiss && <button className="btn-close" aria-label="Dismiss error" onClick={dismiss}/>}</div> : null;
}
export function Empty({ children = 'No records in this time range.' }) { return <div className="empty-state">{children}</div>; }
export function Busy({ children = 'Loading…' }) { return <div className="empty-state"><span className="spinner-border spinner-border-sm me-2" aria-hidden="true"/>{children}</div>; }
export function Panel({ title, detail, children, className = '', actions }) {
    return <section className={`panel ${className}`}><div className="panel-title"><div><h2>{title}</h2>{detail && <small>{detail}</small>}</div>{actions}</div>{children}</section>;
}
export function Badge({ children, tone = 'muted' }) { return <span className={`status-badge ${tone}`}>{children}</span>; }
export function Meter({ value, max, label }) { return <div className="progress" role="progressbar" aria-label={label} aria-valuenow={value || 0} aria-valuemin="0" aria-valuemax={max || 100}><div className="progress-bar" style={{ width: `${Math.min(100, (value || 0) * 100 / (max || 100))}%` }}/></div>; }
export function DataTable({ columns, rows, onSelect, rowKey }) {
    return rows.length ? <div className="table-responsive"><table className="table align-middle table-hover mb-0"><thead><tr>{columns.map(c => <th key={c.key} scope="col">{c.label}</th>)}</tr></thead><tbody>{rows.map((row, index) => <tr key={rowKey?.(row) ?? index}>{columns.map((c, ci) => <td key={c.key}>{ci === 0 && onSelect ? <button className="table-link" onClick={() => onSelect(row)}>{c.render ? c.render(row) : row[c.key]}</button> : c.render ? c.render(row) : row[c.key] ?? '—'}</td>)}</tr>)}</tbody></table></div> : <Empty />;
}
