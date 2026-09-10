#!/usr/bin/env bash
# An accepted POST body can remain buffered in nginx across a failed runtime
# activation. Exercise the real rollback hooks and retirement helper with nginx;
# only systemd dispatch is replaced, so this also runs without a systemd host.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
command -v nginx >/dev/null || { echo 'nginx is required' >&2; exit 1; }
python3 - "$ROOT" <<'PY'
import http.client
import http.server
import multiprocessing
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])


def backend(server_socket, name):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = name.encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            assert body == b'{"q":"beginning"}', body
            self.do_GET()

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler, bind_and_activate=False)
    server.socket.close()
    server.socket = server_socket
    server.serve_forever()


def wait_until(check, description, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.05)
    raise AssertionError(description)


with tempfile.TemporaryDirectory(prefix="getbible-rollback-") as temporary:
    base = Path(temporary)
    base.chmod(0o755)
    processes = []
    nginx = None
    unrelated_nginx = None
    harness = None
    slow = None
    try:
        ports = []
        for name in ("old", "candidate"):
            listener = socket.socket()
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            ports.append(listener.getsockname()[1])
            # This stdin-run Linux fixture inherits its socket and handler;
            # Python 3.14 otherwise defaults to an import-based forkserver.
            process = multiprocessing.get_context("fork").Process(target=backend, args=(listener, name))
            process.start()
            processes.append(process)
            listener.close()

        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
        listener.close()
        nginx_conf = base / "nginx.conf"
        for name, upstream in zip(("old", "candidate"), ports):
            (base / f"{name}.conf").write_text(f"""
daemon off;
user root;
pid {base}/nginx.pid;
error_log {base}/nginx.log notice;
worker_processes 1;
events {{ worker_connections 128; }}
http {{
    access_log off;
    client_body_temp_path {base}/body;
    server {{
        listen 127.0.0.1:{port};
        location / {{
            proxy_request_buffering on;
            proxy_pass http://127.0.0.1:{upstream};
        }}
    }}
}}
""")
        shutil.copyfile(base / "old.conf", nginx_conf)
        nginx = subprocess.Popen(["nginx", "-c", str(nginx_conf)], stdout=subprocess.DEVNULL)

        def responds(expected, listener_port=port):
            conn = http.client.HTTPConnection("127.0.0.1", listener_port, timeout=1)
            try:
                conn.request("GET", "/")
                response = conn.getresponse()
                return response.status == 200 and response.read() == expected
            except OSError:
                return False
            finally:
                conn.close()

        wait_until(lambda: responds(b"old"), "initial backend unavailable")
        # A separate nginx master remains active during every managed reload.
        # It must neither hold up confirmation nor defer candidate retirement.
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        unrelated_port = listener.getsockname()[1]
        listener.close()
        unrelated_conf = base / "unrelated.conf"
        unrelated_conf.write_text((base / "old.conf").read_text()
                                  .replace(f"127.0.0.1:{port};", f"127.0.0.1:{unrelated_port};")
                                  .replace("/nginx.pid", "/unrelated.pid")
                                  .replace("/nginx.log", "/unrelated.log")
                                  .replace("/body;", "/unrelated-body;"))
        unrelated_nginx = subprocess.Popen(["nginx", "-c", str(unrelated_conf)], stdout=subprocess.DEVNULL)
        wait_until(lambda: responds(b"old", unrelated_port), "unrelated nginx unavailable")

        def visible_master_pid(config):
            # Some development sandboxes expose host /proc PIDs while child
            # process handles use a nested namespace. Simulated systemd must
            # return the PID as seen by the worker-inspection code.
            for entry in Path("/proc").glob("[0-9]*/cmdline"):
                try:
                    title = entry.read_bytes().split(b"\0", 1)[0]
                except OSError:
                    continue
                if title.startswith(b"nginx: master process") and str(config).encode() in title:
                    return entry.parent.name
            raise AssertionError(f"nginx master missing for {config}")

        managed_master = visible_master_pid(nginx_conf)
        unrelated_master = visible_master_pid(unrelated_conf)
        (base / "nginx-visible.pid").write_text(managed_master + "\n")
        fake_ctl = base / "systemctl"
        fake_ctl.write_text(f"#!/bin/sh\nkill -TERM {processes[1].pid}\ntouch '{base}/retired'\n")
        fake_ctl.chmod(0o755)
        nginx_ctl = base / "nginx-systemctl"
        nginx_ctl.write_text(f'''#!/bin/sh
case "$1" in
    is-active) exit 0 ;;
    show) cat '{base}/nginx-visible.pid' ;;
    reload) exec nginx -s reload -c '{nginx_conf}' ;;
    *) exit 2 ;;
esac
''')
        nginx_ctl.chmod(0o755)
        script = base / "abort.sh"
        script.write_text(r'''
set -Eeuo pipefail
export GB_PREFIX="$CASE" GB_REPO_DIR="$ROOT" GB_UI=none GB_YES=true
export GB_SYSTEMCTL="$CASE/nginx-systemctl"
for lib in core config registry systemd python endpoint nginx; do source "$ROOT/src/lib/$lib.sh"; done
source "$ROOT/src/types/runtime/type.sh"
mkdir -p "$GB_LOG" "$CASE/generation" "$CASE/root" "$CASE/backup"
ep_get() { printf 'search\n'; }
ep_state_set() { :; }
tg_notify() { :; }
rt_root() { printf '%s/root\n' "$CASE"; }
rt_env_file() { printf '%s/runtime.env\n' "$CASE"; }
rt_generation_unit() { printf 'getbible-search-v2-candidate\n'; }
sd_available() { return 1; }
sd_daemon_reload() { :; }
sd_remove_unit() { "$CASE/systemctl" stop "$1"; }
nginx_detect() { NG_AVAILABLE=true; }
reload_nginx() {
    local GB_PREFIX="" GB_SYSTEMCTL="$CASE/nginx-systemctl"
    nginx -t -c "$CASE/nginx.conf" && nginx_reload
}
sd_retire_after() {
    cp "$2" "$CASE/drain-workers"
    "$ROOT/src/bin/getbible-runtime-retire" "$CASE/systemctl" "$1" "$CASE/drain-workers" > "$CASE/retirement.log" 2>&1 &
    printf '%s\n' "$!" > "$CASE/retirement.pid"
}
nginx_transaction_rollback() {
    cp "$CASE/old.conf" "$CASE/nginx.conf"
    reload_nginx
}
EP_TYPE=runtime; RT_DOMAIN=search.example.test
RT_LABELS=(v2); RT_CANDIDATES[v2]="$CASE/generation"
RT_STATE_BACKUP="$CASE/backup"; RT_COMMITTED=true
RT_SWITCH_PREPARED=true; RT_ABORT_NGINX_SNAPSHOT=""
printf 'old\n' > "$CASE/runtime.env"
ln -s "$CASE/old" "$CASE/root/active"
for target in "$CASE/root/active" "$CASE/root/previous" "$(py_current_link "$CASE/root")" "$CASE/runtime.env"; do
    gb_backup_file "$target" "$RT_STATE_BACKUP/v2"
done
ln -sfn "$CASE/generation" "$CASE/root/active"
printf 'candidate\n' > "$CASE/runtime.env"
RT_NGINX_SNAPSHOT="$CASE/forward-workers"
sd_snapshot_nginx_workers "$RT_NGINX_SNAPSHOT" "$(nginx_master_pid)"
[[ -s "$RT_NGINX_SNAPSHOT" ]] || { echo 'nginx workers must be visible in /proc' >&2; exit 2; }
touch "$CASE/snapshot-ready"
while [[ ! -f "$CASE/reload-candidate" ]]; do sleep 0.05; done
reload_nginx
touch "$CASE/first-live"
while [[ ! -f "$CASE/reload-again" ]]; do sleep 0.05; done
reload_nginx
touch "$CASE/second-live"
while [[ ! -f "$CASE/fail-activation" ]]; do sleep 0.05; done
endpoint_apply_abort "$RT_DOMAIN" 'Injected late runtime activation failure'
''')
        harness = subprocess.Popen(
            ["bash", str(script)],
            env={**os.environ, "CASE": str(base), "ROOT": str(root)},
        )
        wait_until(lambda: (base / "snapshot-ready").exists() or harness.poll() is not None,
                   "forward worker snapshot was not taken")
        assert harness.poll() is None, "rollback harness failed before the traffic switch"
        shutil.copyfile(base / "candidate.conf", nginx_conf)
        (base / "reload-candidate").touch()
        wait_until(lambda: (base / "first-live").exists(), "first nginx reload did not complete")
        wait_until(lambda: responds(b"candidate"), "candidate routing did not activate")

        # Receiving 100 Continue proves a candidate-serving worker accepted
        # this POST. Hold back the final byte until after the rollback.
        body = b'{"q":"beginning"}'
        slow = socket.create_connection(("127.0.0.1", port), timeout=10)
        slow.sendall((f"POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: {len(body)}\r\n"
                      "Expect: 100-continue\r\nConnection: close\r\n\r\n").encode())
        interim = slow.recv(4096)
        assert b"100 Continue" in interim, interim
        slow.sendall(body[:-1])
        # A second configuration stage must complete without waiting for the
        # first cohort's POST body. Its own replacement workers must also be
        # included in the later rollback snapshot.
        (base / "reload-again").touch()
        wait_until(lambda: (base / "second-live").exists(), "second nginx reload waited for request drain")
        assert responds(b"candidate"), "second nginx stage lost candidate routing"
        (base / "fail-activation").touch()
        assert harness.wait(timeout=20) == 1, "failed activation must report failure"
        candidate_retained = (base / "generation").is_dir() and processes[1].is_alive()
        assert (base / "runtime.env").read_text() == "old\n", "old environment was not restored"
        assert os.readlink(base / "root/active") == str(base / "old"), "old pointer was not restored"
        retirement_scheduled = (base / "drain-workers").is_file()
        wait_until(lambda: responds(b"old"), "new requests did not return to old backend")

        slow.sendall(body[-1:])
        response = b""
        while chunk := slow.recv(4096):
            response += chunk
        assert b"200 OK" in response and response.endswith(b"candidate"), response
        assert candidate_retained, "candidate was removed before the buffered POST completed"
        assert retirement_scheduled, "rollback did not schedule retirement"
        slow.close()
        slow = None
        wait_until(lambda: (base / "retired").exists(), "candidate was not retired after draining")
        processes[1].join(timeout=3)
        assert not processes[1].is_alive(), "candidate stayed running after retirement"
        assert responds(b"old"), "old backend failed after retirement"
        assert responds(b"old", unrelated_port), "unrelated nginx was affected by managed reloads"
        assert visible_master_pid(unrelated_conf) == unrelated_master, "unrelated master was replaced"
        print("Runtime rollback: buffered POST succeeded, candidate retired, unrelated nginx remained active")
    except BaseException:
        if (base / "nginx.log").exists():
            print((base / "nginx.log").read_text(), file=sys.stderr)
        raise
    finally:
        if slow is not None:
            slow.close()
        if harness is not None and harness.poll() is None:
            harness.terminate()
            harness.wait(timeout=5)
        if (base / "retirement.pid").exists() and not (base / "retired").exists():
            try:
                os.kill(int((base / "retirement.pid").read_text()), signal.SIGTERM)
            except ProcessLookupError:
                pass
        if nginx is not None and nginx.poll() is None:
            nginx.terminate()
            nginx.wait(timeout=5)
        if unrelated_nginx is not None and unrelated_nginx.poll() is None:
            unrelated_nginx.terminate()
            unrelated_nginx.wait(timeout=5)
        for process in processes:
            if process.is_alive():
                process.terminate()
            process.join(timeout=5)
PY
