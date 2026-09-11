"""Collector service and canonical history command line interface."""

from __future__ import annotations

import argparse
import json
import os
import signal
import sys
import time

from .collector import Collector
from .store import TelemetryStore, timestamp
from .settings import numeric_setting


def _env(name: str, default: str) -> str:
    return os.environ.get("GETBIBLE_TELEMETRY_" + name, default)


def _number(name: str):
    return lambda value: numeric_setting("TELEMETRY_" + name, value)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("collect", "summary", "series", "requests", "events",
                                          "metrics", "storage", "endpoints", "export", "rotate"))
    parser.add_argument("--db", default=_env("DB", "/var/lib/getbible/telemetry/traffic.sqlite3"))
    parser.add_argument("--log-root", default=_env("LOG_ROOT", "/var/log/getbible"))
    parser.add_argument("--from", dest="start", default="")
    parser.add_argument("--to", dest="end", default="")
    parser.add_argument("--endpoint")
    parser.add_argument("--version")
    parser.add_argument("--top", type=int, default=20)
    parser.add_argument("--limit", type=int, default=100)
    parser.add_argument("--cursor", type=int)
    parser.add_argument("--bucket", type=int, default=60)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--max-gib", type=_number("MAX_GIB"), default=_env("MAX_GIB", "10"))
    parser.add_argument("--retention-days", type=_number("RETENTION_DAYS"), default=_env("RETENTION_DAYS", "180"))
    parser.add_argument("--spool-max-gib", type=_number("SPOOL_MAX_GIB"), default=_env("SPOOL_MAX_GIB", "1"))
    parser.add_argument("--batch-size", type=_number("BATCH_SIZE"), default=_env("BATCH_SIZE", "1000"))
    parser.add_argument("--flush-seconds", type=_number("FLUSH_SECONDS"), default=_env("FLUSH_SECONDS", "1"))
    parser.add_argument("--metrics-seconds", type=_number("METRICS_SECONDS"), default=_env("METRICS_SECONDS", "5"))
    parser.add_argument("--rotate-mib", type=_number("SPOOL_ROTATE_MIB"), default=_env("SPOOL_ROTATE_MIB", "16"))
    parser.add_argument("--nginx-pid", default="/run/nginx.pid")
    parser.add_argument("--notify", default="/usr/local/lib/getbible/getbible-notify")
    parser.add_argument("--cgroup-root", default="/sys/fs/cgroup")
    parser.add_argument("--settings", default="", help="Reload this root-managed effective environment every 30 seconds")
    parser.add_argument("--no-journal", action="store_true", help="Disable collection of getBible systemd service events")
    parser.add_argument("--systemctl", default="/usr/bin/systemctl")
    args = parser.parse_args(argv)
    end = timestamp(args.end) if args.end else time.time()
    start = timestamp(args.start) if args.start else end - 86400
    os.umask(0o027)
    with TelemetryStore(args.db, readonly=args.action not in {"collect", "rotate"}) as store:
        if args.action in {"collect", "rotate"}:
            collector = Collector(store, args.log_root, batch_size=args.batch_size,
                                  rotate_bytes=int(args.rotate_mib * 1024**2),
                                  spool_max_bytes=int(args.spool_max_gib * 1024**3),
                                  nginx_pid=args.nginx_pid, notify=args.notify)
            if args.action == "rotate":
                # Rotation itself is safe alongside the running collector;
                # ingestion remains protected by the collector's lifetime lock.
                print(json.dumps({"rotated": collector.rotate()}))
                return 0
            def stop(_signum: int, _frame: object) -> None:
                collector.running = False
            signal.signal(signal.SIGTERM, stop)
            signal.signal(signal.SIGINT, stop)
            collector.run(flush_seconds=args.flush_seconds, metrics_seconds=args.metrics_seconds,
                          max_bytes=int(args.max_gib * 1024**3), retention_days=args.retention_days,
                          once=args.once, cgroup_root=args.cgroup_root, settings=args.settings, journal=not args.no_journal,
                          systemctl=args.systemctl)
            return 0
        common = {"endpoint": args.endpoint, "version": args.version}
        if args.action == "summary":
            result = store.summary(start, end, top=args.top, **common)
        elif args.action == "series":
            result = store.series(start, end, args.bucket, **common)
        elif args.action == "requests":
            result = store.requests(start, end, limit=args.limit, cursor=args.cursor, **common)
        elif args.action == "events":
            result = store.events(start, end, limit=args.limit, cursor=args.cursor, endpoint=args.endpoint)
        elif args.action == "metrics":
            result = store.metrics(start, end, args.bucket)
        elif args.action == "storage":
            result = store.storage()
        elif args.action == "endpoints":
            result = store.endpoints()
        else:
            for entry in store.export(start, end, **common):
                print(json.dumps(entry, ensure_ascii=False, separators=(",", ":")))
            return 0
        print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
