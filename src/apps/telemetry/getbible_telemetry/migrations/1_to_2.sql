ALTER TABLE requests ADD COLUMN endpoint_kind TEXT NOT NULL DEFAULT '';
ALTER TABLE requests ADD COLUMN referrer TEXT NOT NULL DEFAULT '';
ALTER TABLE requests ADD COLUMN book_names TEXT NOT NULL DEFAULT '{}';

-- Preserve every original column. Populate only facts captured with the request;
-- absent historical facts stay unknown and never depend on today's Bible data.
WITH captured AS (
    SELECT id, operation, edge_json IS NOT NULL AS has_edge,
           CASE WHEN json_valid(runtime_json) THEN runtime_json ELSE '{}' END AS runtime,
           CASE WHEN json_valid(edge_json) THEN edge_json ELSE '{}' END AS edge
    FROM requests
)
UPDATE requests SET
    endpoint_kind = COALESCE(
        CASE json_extract(captured.runtime, '$.endpoint_kind')
            WHEN 'query' THEN 'query' WHEN 'search' THEN 'search' WHEN 'static' THEN 'static' END,
        CASE json_extract(captured.edge, '$.resolved_endpoint_kind')
            WHEN 'query' THEN 'query' WHEN 'search' THEN 'search' WHEN 'static' THEN 'static' END,
        CASE json_extract(captured.edge, '$.endpoint_kind')
            WHEN 'query' THEN 'query' WHEN 'search' THEN 'search' WHEN 'static' THEN 'static' END,
        CASE captured.operation
            WHEN 'scripture' THEN 'query' WHEN 'search' THEN 'search'
            WHEN 'reference' THEN 'search' WHEN 'static' THEN 'static' END,
        CASE json_extract(captured.runtime, '$.logger')
            WHEN 'getbible.query' THEN 'query' WHEN 'getbible.search' THEN 'search' END,
        ''),
    referrer = COALESCE(NULLIF(CASE WHEN captured.has_edge THEN
        CASE WHEN json_type(captured.edge, '$.referrer') = 'text'
             THEN json_extract(captured.edge, '$.referrer')
             WHEN json_type(captured.edge, '$.referer') = 'text'
             THEN json_extract(captured.edge, '$.referer') ELSE '' END
        ELSE
        CASE WHEN json_type(captured.runtime, '$.referrer') = 'text'
             THEN json_extract(captured.runtime, '$.referrer')
             WHEN json_type(captured.runtime, '$.referer') = 'text'
             THEN json_extract(captured.runtime, '$.referer') ELSE '' END
        END, '-'), ''),
    book_names = CASE WHEN json_type(captured.runtime, '$.book_names') = 'object'
                          THEN json_extract(captured.runtime, '$.book_names')
                     WHEN json_type(captured.edge, '$.book_names') = 'object'
                          THEN json_extract(captured.edge, '$.book_names')
                     ELSE '{}' END
FROM captured WHERE requests.id = captured.id;
