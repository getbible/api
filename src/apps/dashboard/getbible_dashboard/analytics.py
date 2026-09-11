"""Read the canonical traffic store only while authenticated viewers exist."""

from datetime import datetime
import time


FILTERS = frozenset({"endpoint", "version", "status", "auth", "ip", "path", "translation",
                     "book", "search", "reference", "cache", "method", "token", "user_agent", "operation"})


def timestamp(value, default):
    if value is None or value == "":
        return default
    try:
        return float(value)
    except (ValueError, TypeError):
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError("Date ranges must include a timezone")
        return parsed.timestamp()


def query_range(query):
    now = time.time()
    start = timestamp(query.get("start"), now - 86400)
    end = timestamp(query.get("end"), now)
    if not (0 <= start < end <= now + 300):
        raise ValueError("Choose a valid start and end time")
    return start, end


class Analytics:
    def __init__(self, database, store_factory=None):
        self.database = database
        self.store_factory = store_factory

    def store(self):
        factory = self.store_factory
        if factory is None:
            from getbible_telemetry import TelemetryStore
            factory = TelemetryStore
        return factory(self.database, readonly=True, query_timeout=10.0)

    def initialize(self):
        with self.store() as store:
            store.storage()

    def report(self, kind, query):
        start, end = query_range(query)
        filters = {key: value for key, value in query.items() if key in FILTERS and value != ""}
        with self.store() as store:
            if kind == "overview":
                result = store.summary(start, end, filters=filters)
                metrics = store.metrics(max(start, end - 300), end, bucket_seconds=5)
                result["latest_metrics"] = metrics[-1] if isinstance(metrics, list) and metrics else None
                result["start"], result["end"] = start, end
                return result
            if kind == "history":
                bucket = int(query.get("bucket_seconds", 60))
                if not 1 <= bucket <= 86400 * 31:
                    raise ValueError("bucket_seconds must be between 1 and 2678400")
                # Bound result size rather than silently truncating history.
                bucket = max(bucket, int((end - start) / 2000) + 1)
                return {"series": store.series(start, end, bucket_seconds=bucket, filters=filters),
                        "metrics": store.metrics(start, end, bucket_seconds=max(5, bucket)),
                        "start": start, "end": end, "bucket_seconds": bucket}
            if kind == "requests":
                limit = int(query.get("limit", 100))
                if not 1 <= limit <= 500:
                    raise ValueError("limit must be between 1 and 500")
                return store.requests(start, end, limit=limit, cursor=query.get("cursor"), filters=filters)
            if kind == "events":
                return store.events(start, end, endpoint=query.get("endpoint"),
                                    limit=min(500, max(1, int(query.get("limit", 100)))),
                                    cursor=query.get("cursor"))
            if kind == "storage":
                return store.storage()
            if kind == "endpoints":
                return store.endpoints()
            raise ValueError("Unknown report")
