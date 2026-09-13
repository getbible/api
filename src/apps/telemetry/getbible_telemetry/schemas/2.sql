CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS sources (
    identity TEXT PRIMARY KEY, path TEXT NOT NULL, offset INTEGER NOT NULL DEFAULT 0,
    fingerprint TEXT NOT NULL DEFAULT '', fingerprint_bytes INTEGER NOT NULL DEFAULT 0,
    generation INTEGER NOT NULL DEFAULT 0, updated REAL NOT NULL, closed INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS requests (
    id INTEGER PRIMARY KEY, endpoint TEXT NOT NULL, request_id TEXT NOT NULL, stamp REAL NOT NULL,
    method TEXT NOT NULL, path TEXT NOT NULL, query TEXT NOT NULL, version TEXT NOT NULL,
    status INTEGER NOT NULL, duration_ms REAL NOT NULL, bytes INTEGER NOT NULL,
    remote_addr TEXT NOT NULL, token_id TEXT NOT NULL, auth TEXT NOT NULL,
    cache TEXT NOT NULL, translation TEXT NOT NULL, book TEXT NOT NULL,
    reference TEXT NOT NULL, search TEXT NOT NULL, operation TEXT NOT NULL, user_agent TEXT NOT NULL,
    endpoint_kind TEXT NOT NULL DEFAULT '', referrer TEXT NOT NULL DEFAULT '', book_names TEXT NOT NULL DEFAULT '{}',
    edge_json TEXT, runtime_json TEXT, UNIQUE(endpoint, request_id)
);
CREATE INDEX IF NOT EXISTS requests_time ON requests(stamp, id);
CREATE INDEX IF NOT EXISTS requests_endpoint_time ON requests(endpoint, stamp);
CREATE INDEX IF NOT EXISTS requests_translation_time ON requests(translation, stamp);
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY, stamp REAL NOT NULL, endpoint TEXT NOT NULL,
    source TEXT NOT NULL, level TEXT NOT NULL, event TEXT NOT NULL, payload TEXT NOT NULL,
    record_key TEXT NOT NULL UNIQUE
);
CREATE INDEX IF NOT EXISTS events_time ON events(stamp, id);
CREATE TABLE IF NOT EXISTS metrics (
    id INTEGER PRIMARY KEY, stamp REAL NOT NULL, payload TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS metrics_time ON metrics(stamp, id);
CREATE TABLE IF NOT EXISTS retention (
    id INTEGER PRIMARY KEY, stamp REAL NOT NULL, reason TEXT NOT NULL,
    first_stamp REAL, last_stamp REAL, request_rows INTEGER NOT NULL,
    event_rows INTEGER NOT NULL, metric_rows INTEGER NOT NULL, detail TEXT NOT NULL
);
