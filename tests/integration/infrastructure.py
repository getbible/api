#!/usr/bin/env python3
"""Acceptance of installed services on a disposable native host or container.

Uses the production accounts, systemd units, sockets and SQLite permissions.
The temporary dashboard has no public route and Telegram remains disabled.
"""

import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import pwd
import secrets
import socket
import sqlite3
import stat
import subprocess
import time


RUN = Path("/run/getbible")
VAR = Path("/var/lib/getbible")
DB = VAR / "telemetry/traffic.sqlite3"
SNAPSHOTS = ("dashboard.conf", "telemetry.env", "adaptive.env", "storage.env", "telegram.conf")
AUXILIARY = ("getbible-telemetry.service", "getbible-admin.service", "getbible-dashboard.service",
             "getbible-adapt.service", "getbible-storage.service")
DOMAIN = "dashboard.ci.example.test"


def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, timeout=kwargs.pop("timeout", 180), **kwargs).strip()


def check(condition, message):
    if not condition:
        raise AssertionError(message)
    print("ok: " + message, flush=True)


def wait_for(callback, message, seconds=45):
    deadline = time.monotonic() + seconds
    last_error = None
    while time.monotonic() < deadline:
        try:
            result = callback()
            if result:
                print("ok: " + message, flush=True)
                return result
        except (OSError, ValueError, sqlite3.Error, http.client.HTTPException,
                subprocess.CalledProcessError) as exc:
            last_error = type(exc).__name__
        time.sleep(0.25)
    raise AssertionError(f"Timed out: {message} ({last_error or 'condition remained false'})")


def property_of(unit, key):
    return run("systemctl", "show", "--property=" + key, "--value", unit)


def pid(unit):
    return int(property_of(unit, "MainPID"))


def environment(process):
    return dict(entry.split("=", 1) for entry in
                Path(f"/proc/{process}/environ").read_text().split("\0") if "=" in entry)


def settings(path):
    return dict(line.split("=", 1) for line in Path(path).read_text().splitlines()
                if line and not line.startswith("#") and "=" in line)


def sql_rows(query, values=()):
    with sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5) as db:
        return db.execute(query, values).fetchall()


def account(*args):
    return run("runuser", "-u", "getbible-dashboard", "--", *args)


def broker_probe():
    # This child really runs as the production dashboard UID. The broker checks
    # SO_PEERCRED; root making an equivalent call would not cover that boundary.
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(10)
        connection.connect("/run/getbible-admin/broker.sock")
        connection.sendall(b'{"id":"ci-peer","method":"state","params":{}}\n')
        with connection.makefile("rb") as stream:
            response = json.loads(stream.readline(65536))
    check("error" not in response, "dashboard UID is authorized by the actual broker")
    check("refresh" in response["result"], "broker returns its persisted refresh state")


class UnixHTTP(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(5)
        self.sock.connect("/run/getbible-dashboard/http.sock")


def dashboard_request(path, *, client=True, method="GET", body=None):
    headers = {"Host": DOMAIN, "Origin": "https://" + DOMAIN,
               "Content-Type": "application/json"}
    if client:
        headers["X-GetBible-Client-IP"] = "192.0.2.19"
    connection = UnixHTTP(DOMAIN)
    try:
        connection.request(method, path, body=json.dumps(body) if body is not None else None, headers=headers)
        response = connection.getresponse()
        content = response.read()
        return response.status, json.loads(content) if content else {}
    finally:
        connection.close()


def unit_checks():
    check(property_of("getbible-prepare.service", "ActiveState") == "active",
          "volatile preparation completes before installed infrastructure starts")
    for unit in AUXILIARY:
        for relation in ("After", "Requires"):
            check("getbible-prepare.service" in property_of(unit, relation).split(),
                  f"{unit} declares preparation {relation.lower()}")
    for unit in ("getbible-storage.service", "getbible-prepare.service", "getbible-telemetry.service"):
        check(property_of(unit, "ProtectSystem") == "strict", f"{unit} uses its filesystem sandbox")
        check(property_of(unit, "MemoryMax").isdigit(), f"{unit} has a finite memory bound")
    for unit in ("getbible-adapt.service", "getbible-storage.service"):
        run("systemctl", "start", unit, timeout=900)
        check(property_of(unit, "Result") == "success", f"{unit} executes under systemd")
    # The native runtime-only fixture legitimately has no static sync units;
    # systemctl list-unit-files exits nonzero for an unmatched pattern.
    for installed in sorted(Path("/etc/systemd/system").glob("getbible-sync-*.service")):
        unit = installed.name
        check("getbible-prepare.service" in property_of(unit, "Requires").split(),
              f"{unit} requires effective snapshot preparation")
        check(str(RUN / "storage.env") in property_of(unit, "EnvironmentFiles"),
              f"{unit} reads the current storage cap")


def collector_checks(mode):
    check(property_of("getbible-telemetry.service", "ActiveState") == "active", "installed collector is active")
    values = settings(RUN / "telemetry.env")
    actual = environment(pid("getbible-telemetry.service"))
    for key in ("GETBIBLE_TELEMETRY_RETENTION_DAYS", "GETBIBLE_TELEMETRY_BATCH_SIZE",
                "GETBIBLE_TELEMETRY_FLUSH_SECONDS", "GETBIBLE_TELEMETRY_MAX_GIB"):
        check(actual.get(key) == values[key], f"collector process receives effective {key}")
    started = time.time()
    nonce = secrets.token_hex(12)
    for kind, request in (("query", "Ge1:1"), ("search", "beginning")):
        domain = kind + (".ci.example.test" if mode == "native" else ".example.test")
        # Both APIs reject unknown parameters. A unique validation error reaches
        # the runtime even when successful scripture responses are already in
        # nginx's cache, and proves fresh error/query-string capture after boot.
        path = f"/v2/test/{request}?ci_nonce={nonce}"
        if mode == "native":
            response = run("curl", "--silent", "--show-error", "--noproxy", "*",
                           "--max-time", "15", "--cacert", os.environ["CURL_CA_BUNDLE"],
                           "--write-out", "\n%{http_code}", "--resolve", domain + ":443:127.0.0.1",
                           "https://" + domain + path)
        else:
            auth = []
            if kind == "query" and os.environ.get("GB_TEST_QUERY_TOKEN"):
                auth = ["-H", "Authorization: Bearer " + os.environ["GB_TEST_QUERY_TOKEN"]]
            response = run("curl", "--silent", "--show-error", "--max-time", "15",
                           "--write-out", "\n%{http_code}", "-H", "Host: " + domain, *auth,
                           "http://127.0.0.1" + path)
        check(response.rsplit("\n", 1)[-1] == "400", f"{kind} validation request reaches the runtime")
        wait_for(lambda: sql_rows("SELECT request_id FROM requests WHERE endpoint=? AND query LIKE ? "
                                  "AND edge_json IS NOT NULL AND runtime_json IS NOT NULL AND status=400",
                                  (domain, "%" + nonce + "%")),
                 f"actual collector joins {kind} nginx and runtime records")
        wait_for(lambda: sql_rows("SELECT request_id FROM requests WHERE endpoint=? AND status=200 "
                                  "AND edge_json IS NOT NULL AND runtime_json IS NOT NULL AND translation='test'",
                                  (domain,)), f"collector retains successful {kind} translation semantics")
    metric = wait_for(lambda: sql_rows("SELECT payload FROM metrics WHERE stamp>? ORDER BY stamp DESC LIMIT 1",
                                      (started,)), "actual collector persists fresh resource metrics")
    sample = json.loads(metric[0][0])
    check(sample["scope"] == ("host" if mode == "native" else "cgroup"), "metrics identify their actual scope")
    check(sample["memory"]["current_bytes"] > 0, "metrics report measured memory consumption")
    check(sample["cpu"]["available"], "metrics report an available CPU counter")
    account("/usr/bin/python3", "-c", "import sqlite3; "
            "db=sqlite3.connect('file:/var/lib/getbible/telemetry/traffic.sqlite3?mode=ro',uri=True); "
            "assert db.execute('SELECT count(*) FROM requests').fetchone()[0] > 0")
    check(not (stat.S_IMODE(DB.stat().st_mode) & 0o007), "telemetry database is not world-readable")


def dashboard_checks():
    original = (RUN / "dashboard.conf").read_bytes()
    probe = RUN / "ci-infrastructure-probe.py"
    probe.write_bytes(Path(__file__).read_bytes())
    probe.chmod(0o644)
    check(settings(RUN / "telegram.conf").get("TELEGRAM_ENABLED") != "true",
          "disposable dashboard cannot send Telegram messages")
    values = settings(RUN / "dashboard.conf")
    values.update(DASHBOARD_ENABLED="true", DASHBOARD_DOMAIN=DOMAIN)
    try:
        # The fixture enables only the local socket; no nginx route, DNS, TLS or
        # persisted enable setting is created by acceptance.
        (RUN / "dashboard.conf").write_text("".join(f"{key}={value}\n" for key, value in values.items()))
        run("systemctl", "start", "getbible-admin.service", "getbible-dashboard.service")
        wait_for(lambda: dashboard_request("/api/auth/status") == (200, {"authenticated": False, "telegram_configured": False}),
                 "real dashboard starts with Telegram disabled")
        check(pid("getbible-dashboard.service") > 0, "dashboard has a live systemd process")
        status = Path(f"/proc/{pid('getbible-dashboard.service')}/status").read_text()
        uid = next(line.split()[1] for line in status.splitlines() if line.startswith("Uid:"))
        check(int(uid) == pwd.getpwnam("getbible-dashboard").pw_uid, "dashboard runs as its dedicated account")
        for path in (Path("/run/getbible-admin/broker.sock"), Path("/run/getbible-dashboard/http.sock")):
            check(stat.S_IMODE(path.stat().st_mode) == 0o660, f"{path.name} enforces its production socket mode")
        check(dashboard_request("/api/auth/status", client=False)[0] == 400, "dashboard requires the trusted client header")
        for path in ("/api/overview", "/api/management/state"):
            code, body = dashboard_request(path)
            check(code == 503 and body["code"] == "telegram_unavailable", "protected route fails closed: " + path)
        code, body = dashboard_request("/api/auth/password", method="POST", body={"password": "disposable-unused-password"})
        check(code == 503 and body["code"] == "telegram_unavailable", "password submission cannot bypass disabled Telegram")
        account("/usr/bin/python3", str(probe), "--broker-probe")
        old_pid = pid("getbible-admin.service")
        run("systemctl", "kill", "--kill-whom=main", "--signal=USR1", "getbible-admin.service")
        wait_for(lambda: pid("getbible-admin.service") not in (0, old_pid), "broker installs its deferred service refresh")
        wait_for(lambda: dashboard_request("/api/auth/status")[0] == 200, "dashboard HTTP recovers after broker replacement")
        account("/usr/bin/python3", str(probe), "--broker-probe")
    finally:
        run("systemctl", "stop", "getbible-dashboard.service", "getbible-admin.service")
        (RUN / "dashboard.conf").write_bytes(original)
        probe.unlink(missing_ok=True)


def recreated_resources(manager):
    plan = json.loads(run(manager, "resources", "--json"))
    check(plan["cgroup_limit_bytes"] == 3 * 1024**3, "recreation applies the new aggregate memory cap")
    check(plan["cpu_capacity"] == 1.5, "recreation applies the new aggregate CPU cap")
    check(len(plan["endpoints"]) == 2, "recreation restores both runtime endpoint allocations")
    for item in plan["endpoints"]:
        kind = item["kind"]
        active = Path(f"/opt/getbible/{kind}/v2/active").resolve()
        unit = f"getbible-{kind}-v2-{active.name}.service"
        values = environment(pid(unit))
        expected = item["settings"]
        check(values["GETBIBLE_CACHE_TTL_SECONDS"] == "604800", f"{kind} process receives changed resident TTL")
        cache = sum(int(values[name]) for name in ("GETBIBLE_SHARED_CORPUS_BYTES", "GETBIBLE_CHAPTER_CACHE_BYTES",
                                                   "GETBIBLE_TRANSLATION_CACHE_BYTES"))
        check(cache == expected["MEMORY_MAX"] // expected["WORKERS"] * 35 // 100,
              f"{kind} process receives changed cache-memory percentage")
        cgroup = Path("/sys/fs/cgroup" + property_of(unit, "ControlGroup"))
        check(int((cgroup / "memory.max").read_text()) == expected["MEMORY_MAX"],
              f"{kind} child cgroup enforces the refreshed allocation")
        quota, period = map(int, (cgroup / "cpu.max").read_text().split())
        desired = 0.75 if kind == "query" else 1.25
        check(abs(quota / period - desired) < 0.001, f"{kind} child cgroup enforces its changed CPU quota")


def deployment_state():
    return {kind: (str(Path(f"/opt/getbible/{kind}/v2/active").resolve()),
                   str(Path(f"/opt/getbible/{kind}/v2/current").resolve())) for kind in ("query", "search")}


def persistent_state():
    paths = (Path("/etc/getbible/getbible.conf"), Path("/etc/getbible/telegram.conf"),
             VAR / "identities.json", VAR / "dashboard/auth.sqlite3")
    return {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}


def native_recovery(manager):
    generations = deployment_state()
    saved = persistent_state()
    run("systemctl", "stop", "getbible-adapt.timer", "getbible-storage.timer", *AUXILIARY,
        "getbible-prepare.service")
    for name in SNAPSHOTS:
        (RUN / name).unlink(missing_ok=True)
    run("systemctl", "start", "getbible-telemetry.service")
    check(all((RUN / name).is_file() for name in SNAPSHOTS), "native boot reconstructs all volatile settings")
    check(deployment_state() == generations, "volatile recovery preserves runtime and code generations")
    check(persistent_state() == saved, "volatile recovery preserves configuration, authentication and identities")
    collector_checks("native")
    helper = Path("/usr/local/lib/getbible/getbible-telemetry")
    source = Path(manager).resolve().parent / "src/bin/getbible-telemetry"
    with helper.open("a") as handle:
        handle.write("\n# Disposable installed-source refresh acceptance marker.\n")
    old_pid = pid("getbible-telemetry.service")
    run(manager, "update", "query.ci.example.test", "--yes", timeout=900)
    check(helper.read_bytes() == source.read_bytes(), "explicit update replaces existing installed infrastructure sources")
    check(pid("getbible-telemetry.service") not in (0, old_pid), "explicit update restarts the collector with new sources")
    check(persistent_state() == saved, "explicit update preserves saved configuration, authentication and identities")
    collector_checks("native")
    run("systemctl", "start", "getbible-adapt.timer", "getbible-storage.timer")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("native", "docker"))
    parser.add_argument("--manager")
    parser.add_argument("--broker-probe", action="store_true")
    parser.add_argument("--collector-only", action="store_true")
    parser.add_argument("--recreated-resources", action="store_true")
    args = parser.parse_args()
    if args.broker_probe:
        broker_probe()
        return
    check(os.geteuid() == 0 and Path("/run/systemd/system").is_dir()
          and os.environ.get("GB_CI_DISPOSABLE_HOST") == "1",
          "acceptance requires root, systemd and explicit disposable-host authorization")
    if not args.mode or (args.mode == "native" and not args.manager):
        parser.error("--mode and native --manager are required")
    if args.recreated_resources:
        recreated_resources(args.manager or "/usr/local/bin/getbible")
    if args.collector_only:
        collector_checks(args.mode)
        return
    unit_checks()
    collector_checks(args.mode)
    dashboard_checks()
    if args.mode == "native":
        native_recovery(args.manager)
    print("Installed infrastructure acceptance passed.", flush=True)


if __name__ == "__main__":
    main()
