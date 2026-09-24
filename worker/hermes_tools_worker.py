"""Warm tool worker for the Rust Hermes <-> opencode/kilocode MCP bridge.

The Rust stdio MCP front-end (``rust/hermes-tools-mcp``) is what opencode/
kilocode actually spawns; it holds no Python and starts in milliseconds. The
expensive Hermes machinery (``model_tools`` import + tool schema build) lives
in THIS long-lived worker, which the Rust front-end starts on demand and shares
across every session, so the ~1.7 s import and ~85 MB resident footprint are
paid once per host instead of once per spawned client process.

Wire: a UNIX-domain socket speaking newline-delimited JSON-RPC 2.0.

Methods:
- ``tools/list``  ``{"id": N, "method": "tools/list", "params": {}}``
      -> ``{"id": N, "result": {"tools": [{name, description, inputSchema}]}}``
- ``tools/call``  ``{"id": N, "method": "tools/call",
                        "params": {"name": str, "arguments": obj}}``
      -> ``{"id": N, "result": {"text": "<handle_function_call() output>"}}``
  (exceptions are converted to an error JSON string exactly like the Python
   MCP server's ``_dispatch`` so agent-visible output is byte-identical.)

Run: ``python -m agent.transports.hermes_tools_worker --socket <path> \
        [--idle-seconds N]``
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import socket
import sys
import threading
import time

logger = logging.getLogger(__name__)

# Serializes handle_function_call: the registry reads process-global state
# (_last_resolved_tool_names, middleware trace) and the worker is shared by
# every session, so calls contend on one dispatch lock. Per-call dispatch is
# ~1.5 ms warm; the tools exposed here are overwhelmingly network-bound anyway.
_DISPATCH_LOCK = threading.Lock()

_last_request_s: float = time.monotonic()
_idle_lock = threading.Lock()


def _touch() -> None:
    global _last_request_s
    with _idle_lock:
        _last_request_s = time.monotonic()


def _idle_seconds(now: float) -> float:
    with _idle_lock:
        return now - _last_request_s


def _build_catalog() -> list[dict]:
    """Same authoritative Hermes schemas + EXPOSED_TOOLS the Python server uses."""
    from agent.transports.hermes_tools_mcp_server import EXPOSED_TOOLS
    from model_tools import get_tool_definitions

    all_defs = {
        td["function"]["name"]: td["function"]
        for td in (get_tool_definitions(quiet_mode=True) or [])
        if isinstance(td, dict) and td.get("type") == "function"
    }
    tools: list[dict] = []
    for name in EXPOSED_TOOLS:
        spec = all_defs.get(name)
        if spec is None:
            logger.debug("skipping %s — not registered in this Hermes process", name)
            continue
        tools.append({
            "name": name,
            "description": spec.get("description") or f"Hermes {name} tool",
            "inputSchema": spec.get("parameters") or {"type": "object", "properties": {}},
        })
    return tools


def _handle_request(req: dict, catalog: list[dict]) -> dict:
    """Dispatch one JSON-RPC request; returns a response object (never raises)."""
    rid = req.get("id")
    method = req.get("method")
    params = req.get("params") or {}

    if method == "tools/list":
        return {"id": rid, "result": {"tools": catalog}}

    if method == "tools/call":
        name = (params.get("name") or "").strip()
        args = params.get("arguments") or {}
        if not name:
            return {"id": rid, "error": {"code": -32602, "message": "missing tool name"}}
        # Match the Python server: drop unset optionals so they aren't forwarded.
        clean = {k: v for k, v in args.items() if v is not None}
        try:
            from model_tools import handle_function_call

            with _DISPATCH_LOCK:
                text = handle_function_call(name, clean)
            return {"id": rid, "result": {"text": text}}
        except Exception as exc:  # noqa: BLE001 - parity with the Python server
            logger.exception("tool %s raised", name)
            return {"id": rid, "result": {"text": json.dumps({"error": str(exc), "tool": name})}}

    return {"id": rid, "error": {"code": -32601, "message": f"unknown method {method!r}"}}


def _serve(socket_path: str, idle_seconds: float) -> int:
    if os.path.exists(socket_path):
        try:
            os.unlink(socket_path)
        except OSError as exc:
            sys.stderr.write(f"hermes-tools worker: cannot remove stale {socket_path}: {exc}\n")
            return 2

    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        listener.bind(socket_path)
        os.chmod(socket_path, 0o600)
        listener.listen(16)
    except OSError as exc:
        sys.stderr.write(f"hermes-tools worker: cannot bind {socket_path}: {exc}\n")
        return 2
    listener.settimeout(1.0)  # wake periodically to check the idle deadline

    sys.stderr.write("hermes-tools worker ready\n")
    sys.stderr.flush()

    def handle_conn(conn: socket.socket) -> None:
        _touch()
        try:
            with conn, conn.makefile("r", encoding="utf-8", errors="replace") as f:
                line = f.readline()
                if not line:
                    return
                req = json.loads(line)
                resp = _handle_request(req, _CATALOG)
                conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))
        except (ValueError, json.JSONDecodeError):
            logger.exception("malformed request")
            try:
                conn.sendall(b'{"error":{"code":-32700,"message":"parse error"}}\n')
            except OSError:
                pass
        except OSError:
            pass

    try:
        while True:
            try:
                conn, _ = listener.accept()
            except socket.timeout:
                if idle_seconds > 0 and _idle_seconds(time.monotonic()) > idle_seconds:
                    sys.stderr.write("hermes-tools worker idle; exiting\n")
                    break
                continue
            except OSError:
                continue
            threading.Thread(target=handle_conn, args=(conn,), daemon=True).start()
    finally:
        listener.close()
        try:
            os.unlink(socket_path)
        except FileNotFoundError:
            pass
        except OSError:
            pass
    return 0


_CATALOG: list[dict] = []


def main(argv: list[str] | None = None) -> int:
    argv = list(argv if argv is not None else sys.argv[1:])
    ap = argparse.ArgumentParser(prog="hermes_tools_worker")
    ap.add_argument("--socket", required=True, help="UNIX socket path")
    ap.add_argument("--idle-seconds", type=float, default=300.0, help="exit after N idle seconds (0 = never)")
    args = ap.parse_args(argv)

    logging.basicConfig(level=logging.WARNING, stream=sys.stderr,
                        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
    os.environ.setdefault("HERMES_QUIET", "1")
    os.environ.setdefault("HERMES_REDACT_SECRETS", "true")

    global _CATALOG
    try:
        _CATALOG = _build_catalog()
    except Exception as exc:  # noqa: BLE001
        sys.stderr.write(f"hermes-tools worker cannot build tool catalog: {exc}\n")
        return 2
    if not _CATALOG:
        sys.stderr.write("hermes-tools worker: no tools registered\n")
        return 2
    _touch()
    return _serve(args.socket, args.idle_seconds)


if __name__ == "__main__":
    sys.exit(main())