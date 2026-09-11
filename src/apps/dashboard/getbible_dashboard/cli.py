"""Local recovery controls and the private dashboard service entry point."""

import argparse
import json
import os
from pathlib import Path
import signal
import socket
import sys
import threading

from .auth import AuthError, AuthStore
from .config import Config
from .server import Dashboard, DashboardHTTPServer


def audit_event(event, **fields):
    try:
        from getbible_telemetry.producer import emit_event
        payload = {key: value for key, value in fields.items() if key not in {"ip", "session_id"}}
        if "ip" in fields:
            payload["remote_addr"] = fields["ip"]
        if "session_id" in fields:
            payload["session_ref"] = fields["session_id"]
        emit_event(event, payload, path=os.environ.get(
            "GETBIBLE_DASHBOARD_AUDIT_SPOOL", "/var/log/getbible/dashboard/app/dashboard.log"))
    except Exception:
        # The dashboard must never substitute secret-bearing exception messages
        # when a telemetry sink is unavailable.
        print(json.dumps({"event": "dashboard.audit_delivery_failed", "source_event": event}), file=sys.stderr)


def serve(config, reloader=None):
    if not config.enabled:
        raise ValueError("The dashboard is disabled")
    path = Path(config.socket_path)
    path.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
    if path.exists():
        # Do not steal a live socket from an existing service instance.
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
            try:
                probe.settimeout(1)
                probe.connect(str(path))
            except ConnectionRefusedError:
                path.unlink()
            else:
                raise ValueError("The dashboard socket is already in use")
    app = Dashboard(config, audit=audit_event)
    server = DashboardHTTPServer(str(path), app)
    os.chmod(path, 0o660)
    stop_requested = threading.Event()

    def stop(signum, frame):
        if not stop_requested.is_set():
            stop_requested.set()
            threading.Thread(target=server.shutdown, daemon=True).start()

    def reload_config(signum, frame):
        if reloader is None:
            return
        try:
            app.reconfigure(reloader())
        except (OSError, ValueError):
            audit_event("dashboard.configuration_reload_failed")

    previous = {number: signal.signal(number, stop) for number in (signal.SIGTERM, signal.SIGINT)}
    previous[signal.SIGHUP] = signal.signal(signal.SIGHUP, reload_config)
    try:
        app.start()
        server.serve_forever(poll_interval=0.25)
    finally:
        server.server_close()
        app.close()
        path.unlink(missing_ok=True)
        for number, handler in previous.items():
            signal.signal(number, handler)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Private getBible dashboard and local recovery")
    parser.add_argument("--config", default="/etc/getbible/dashboard.conf")
    parser.add_argument("--state-dir")
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("serve")
    run.add_argument("--socket", dest="socket_path")
    run.add_argument("--static-dir")
    commands.add_parser("password-set", help="Read a new password from stdin; revoke all existing sessions")
    commands.add_parser("sessions")
    revoke = commands.add_parser("revoke-session")
    revoke.add_argument("session_id", help="Public session identifier or all")
    commands.add_parser("blocks")
    unblock = commands.add_parser("unblock")
    unblock.add_argument("ip")
    commands.add_parser("status")
    args = parser.parse_args(argv)
    try:
        def load_config():
            return Config.load(args.config, state_dir=args.state_dir,
                               socket_path=getattr(args, "socket_path", None),
                               static_dir=getattr(args, "static_dir", None))

        config = load_config()
        if args.command == "serve":
            serve(config, load_config)
            return 0
        auth = AuthStore(config.state_dir, session_seconds=config.session_seconds,
                         token_seconds=config.token_seconds, audit=audit_event)
        if args.command == "password-set":
            if sys.stdin.isatty():
                import getpass
                password = getpass.getpass("New dashboard password: ")
                if password != getpass.getpass("Confirm password: "):
                    raise ValueError("The passwords do not match")
            else:
                password = sys.stdin.read(1026).removesuffix("\n")
            auth.set_password(password)
            result = {"password_changed": True, "sessions_revoked": True}
        elif args.command == "sessions":
            result = {"sessions": auth.sessions()}
        elif args.command == "revoke-session":
            result = {"revoked": auth.revoke(args.session_id)}
        elif args.command == "blocks":
            result = {"blocks": auth.blocks()}
        elif args.command == "unblock":
            result = {"unblocked": auth.unblock(args.ip)}
        else:
            result = {"enabled": config.enabled, "domain": config.domain, **auth.status()}
        print(json.dumps(result, indent=2))
        return 0
    except (ValueError, AuthError) as exc:
        print(f"getbible-dashboard: {exc}", file=sys.stderr)
        return 1
    except OSError:
        print("getbible-dashboard: a required local file or socket is unavailable", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
