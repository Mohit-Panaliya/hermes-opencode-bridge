# The MCP layer (opencode / kilocode → Hermes)

The **inbound** half of the bridge: an opencode or kilocode agent calls Hermes'
real tools through a local stdio MCP server named `hermes-tools`.

```
opencode / kilo agent
        │  tools/list · tools/call   (newline-delimited JSON-RPC 2.0 on stdio)
        ▼
venv/bin/hermes-tools-mcp-launch          ← the single `command` both clients use
        │
        ├─(rust present & --check ok)─▶ hermes-tools-mcp (Rust, stdio front-end)
        │                                      │ JSON-RPC over a Unix socket
        │                                      ▼
        │                              hermes_tools_worker.py  (warm, shared)
        │
        └─(otherwise)──────────────────▶ python -m agent.transports.hermes_tools_mcp_server
```

## Why a launcher, not the binary directly

Both clients' MCP configs accept only a single `command` array. The launcher
(`scripts/hermes-tools-mcp-launch`) encodes the precedence:

1. If `$RUST_BIN` exists **and** `--check` passes (worker python + worker module
   reachable), `exec` the Rust transport.
2. Otherwise `exec` the Python MCP server.

So an install that has no Rust toolchain still works, and a broken Rust build
degrades instead of producing a dead MCP session.

## Components

### Launcher (`scripts/hermes-tools-mcp-launch`)

Env knobs (all optional): `HERMES_AGENT_DIR`, `PYTHON_BIN`, `RUST_BIN`,
`HERMES_RUN_DIR`, `HERMES_TOOLS_SOCKET`, `HERMES_TOOLS_WORKER_MODULE`,
`HERMES_TOOLS_IDLE_SECONDS`. See [SETUP.md](SETUP.md#5-install-the-launcher).

### Rust transport (`rust/`)

A small stdio front-end that:

- speaks newline-delimited JSON-RPC 2.0 (UTF-8) matching `mcp` 2.x;
- handles `initialize`, `ping`, `tools/list`, `tools/call`, and returns
  `-32601 method-not-found` for anything else (same as the Python server);
- spawns the worker if the socket is unreachable, retries on a dropped
  connection, and multiplexes all sessions onto **one** warm worker.

Flags: `--socket` (required), `--worker-python`, `--worker-module`, `--cwd`,
`--idle-seconds`, `--max-wait-ms`, `--verbose`, `--check`.

Build: `cd rust && cargo build --release`; install the binary to
`venv/bin/hermes-tools-mcp`.

### Warm worker (`worker/hermes_tools_worker.py`)

Imports `model_tools` **once** (~1.5 s import, ~115 MB resident) and serves many
client processes over the Unix socket. Consequences worth knowing:

- The first `tools/list` after a cold start is slower than subsequent ones.
- The worker exits after `--idle-seconds` (launcher default 600) of inactivity.
- It logs to `<socket>.log`, **never stdout** (stdout is the MCP wire).
- Runs with `HERMES_QUIET=1` and `HERMES_REDACT_SECRETS=true`; the socket is
  chmod `0600`.

### Python server (`connector/hermes_tools_mcp_server.py`)

The original standalone implementation, kept verbatim as reference and fallback:

```bash
"$HERMES_AGENT_DIR/venv/bin/python" -m agent.transports.hermes_tools_mcp_server
```

## Exposed tools

```
web_search, web_extract
browser_navigate, browser_click, browser_type, browser_press, browser_snapshot,
browser_scroll, browser_back, browser_get_images, browser_console, browser_vision
vision_analyze, image_generate, skill_view, skills_list, text_to_speech
kanban_complete, kanban_block, kanban_request_review, kanban_request_changes,
kanban_comment, kanban_heartbeat, kanban_show, kanban_list
kanban_create, kanban_unblock, kanban_link      (orchestrator only)
```

The server builds schemas from
`model_tools.get_tool_definitions(quiet_mode=True)` and registers **only** tools
that are present in the running Hermes process. A tool whose backend is not
configured (no Chromium, no image key, kanban toolset off) is **skipped** rather
than advertised dead. The kanban orchestrator tools are gated on
`HERMES_KANBAN_TASK` being unset.

## Registration

Merge into the client config (absolute paths, no `$VAR` expansion):

```jsonc
{
  "mcp": {
    "hermes-tools": {
      "type": "local",
      "command": ["/home/YOU/.hermes/hermes-agent/venv/bin/hermes-tools-mcp-launch"],
      "cwd": "/home/YOU/.hermes/hermes-agent",
      "enabled": true
    }
  }
}
```

- opencode → `~/.config/opencode/opencode.jsonc`
- kilocode → `~/.config/kilo/kilo.jsonc`

Both examples are in `config/opencode.mcp.jsonc` and `config/kilo.mcp.jsonc`.

## Direct Rust wiring (no Python fallback)

If you are certain the Rust path is healthy and want to skip the launcher:

```jsonc
"command": [
  "/home/YOU/.hermes/hermes-agent/venv/bin/hermes-tools-mcp",
  "--socket", "/home/YOU/.hermes/run/hermes-tools.sock",
  "--worker-python", "/home/YOU/.hermes/hermes-agent/venv/bin/python",
  "--cwd", "/home/YOU/.hermes/hermes-agent",
  "--idle-seconds", "600"
]
```

## Protocol details

- Wire: newline-delimited JSON-RPC 2.0, UTF-8, on stdio.
- Lifecycle: `initialize` → (client may send `notifications/initialized`) →
  `tools/list` → `tools/call` × N.
- The server never writes anything but JSON-RPC frames to stdout. All logging
  goes to the worker log file.

## Verifying the MCP layer

```bash
opencode mcp list     # hermes-tools  ✓ connected
kilo mcp list         # hermes-tools  ✓ connected
```

Manual handshake (bypasses the client):

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
| "$HERMES_AGENT_DIR/venv/bin/hermes-tools-mcp-launch" | head -c 1000
```

You should get an `initialize` result followed by a `tools/list` result naming
the tools above.
