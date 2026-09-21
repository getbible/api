-- Exact, rebuildable reporting projections. Existing history is backfilled by
-- the collector in bounded transactions, never by schema migration/readers.
CREATE TABLE IF NOT EXISTS reporting_scopes (
    id INTEGER PRIMARY KEY,
    endpoint TEXT NOT NULL,
    version TEXT NOT NULL,
    endpoint_kind TEXT NOT NULL,
    status INTEGER NOT NULL,
    auth TEXT NOT NULL,
    cache TEXT NOT NULL,
    method TEXT NOT NULL,
    operation TEXT NOT NULL,
    translation TEXT NOT NULL,
    mcp_outcome TEXT NOT NULL,
    UNIQUE(endpoint,version,endpoint_kind,status,auth,cache,method,operation,translation,mcp_outcome)
);
CREATE TABLE IF NOT EXISTS reporting_totals (
    hour INTEGER NOT NULL, scope_id INTEGER NOT NULL,
    calls INTEGER NOT NULL DEFAULT 0,
    bytes INTEGER NOT NULL DEFAULT 0,
    server_errors INTEGER NOT NULL DEFAULT 0,
    errors INTEGER NOT NULL DEFAULT 0,
    http_errors INTEGER NOT NULL DEFAULT 0,
    mcp_requests INTEGER NOT NULL DEFAULT 0,
    mcp_errors INTEGER NOT NULL DEFAULT 0,
    mcp_tool_calls INTEGER NOT NULL DEFAULT 0,
    rate_limited INTEGER NOT NULL DEFAULT 0,
    preflights INTEGER NOT NULL DEFAULT 0,
    cache_hits INTEGER NOT NULL DEFAULT 0,
    cache_requests INTEGER NOT NULL DEFAULT 0,
    duration_total REAL NOT NULL DEFAULT 0,
    runtime_without_edge INTEGER NOT NULL DEFAULT 0,
    h0 INTEGER NOT NULL DEFAULT 0,
    h1 INTEGER NOT NULL DEFAULT 0,
    h2 INTEGER NOT NULL DEFAULT 0,
    h3 INTEGER NOT NULL DEFAULT 0,
    h4 INTEGER NOT NULL DEFAULT 0,
    h5 INTEGER NOT NULL DEFAULT 0,
    h6 INTEGER NOT NULL DEFAULT 0,
    h7 INTEGER NOT NULL DEFAULT 0,
    h8 INTEGER NOT NULL DEFAULT 0,
    h9 INTEGER NOT NULL DEFAULT 0,
    h10 INTEGER NOT NULL DEFAULT 0,
    h11 INTEGER NOT NULL DEFAULT 0,
    h12 INTEGER NOT NULL DEFAULT 0,
    h13 INTEGER NOT NULL DEFAULT 0,
    h14 INTEGER NOT NULL DEFAULT 0,
    max_duration_ms REAL, first_seen REAL, last_seen REAL,
    PRIMARY KEY(hour,scope_id)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS reporting_values (
    hour INTEGER NOT NULL, scope_id INTEGER NOT NULL, dimension TEXT NOT NULL,
    value TEXT NOT NULL, calls INTEGER NOT NULL, bytes INTEGER NOT NULL,
    duration_total REAL NOT NULL, errors INTEGER NOT NULL, samples INTEGER NOT NULL,
    label TEXT,
    PRIMARY KEY(dimension,hour,scope_id,value)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS reporting_values_time ON reporting_values(hour);
CREATE TABLE IF NOT EXISTS reporting_hours (hour INTEGER PRIMARY KEY);
CREATE TABLE IF NOT EXISTS reporting_dirty (hour INTEGER PRIMARY KEY);
CREATE TABLE IF NOT EXISTS reporting_state (
    id INTEGER PRIMARY KEY CHECK(id=1), next_hour INTEGER NOT NULL,
    through_hour INTEGER NOT NULL, complete INTEGER NOT NULL
);
INSERT OR IGNORE INTO reporting_state(id,next_hour,through_hour,complete)
SELECT 1,COALESCE(CAST((SELECT min(stamp) FROM requests)/3600 AS INTEGER)*3600,0),
    COALESCE((CAST((SELECT max(stamp) FROM requests)/3600 AS INTEGER)+1)*3600,0),
    NOT EXISTS(SELECT 1 FROM requests LIMIT 1);
CREATE TRIGGER IF NOT EXISTS reporting_insert AFTER INSERT ON requests BEGIN
    INSERT INTO reporting_dirty(hour) VALUES(CAST(NEW.stamp/3600 AS INTEGER)*3600) ON CONFLICT(hour) DO NOTHING;
END;
CREATE TRIGGER IF NOT EXISTS reporting_update AFTER UPDATE ON requests BEGIN
    INSERT INTO reporting_dirty(hour) VALUES(CAST(OLD.stamp/3600 AS INTEGER)*3600) ON CONFLICT(hour) DO NOTHING;
    INSERT INTO reporting_dirty(hour) VALUES(CAST(NEW.stamp/3600 AS INTEGER)*3600) ON CONFLICT(hour) DO NOTHING;
END;
CREATE TRIGGER IF NOT EXISTS reporting_delete AFTER DELETE ON requests BEGIN
    INSERT INTO reporting_dirty(hour) VALUES(CAST(OLD.stamp/3600 AS INTEGER)*3600) ON CONFLICT(hour) DO NOTHING;
END;
