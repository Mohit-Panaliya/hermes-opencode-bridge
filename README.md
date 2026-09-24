# hermes-opencode-bridge

Bridge Hermes Agent to **opencode** and **kilocode** (a KiloCode fork/variant of
opencode) so the model runs inside the opencode/kilo process while keeping
Hermes' real tool surface reachable — in both directions.

This repo documents the connector, ships the **Rust MCP transport** (a fast
stdio front-end) plus the shared warm Python worker it talks to, keeps the
original Python MCP server verbatim as reference/fallback, and carries
sanitized configuration examples.

---

## The problem

Hermes runs agents across CLI, TUI, gateway, desktop... and, with this bridge,
with the **model executing inside an opencode or kiloCode process** via the
Agent Client Protocol (ACP).

ACP has **no native `tools` / `tool_calls` channel**. When Hermes outsources the
LLM turn to opencode/kilo over ACP, the opencode/kilo agent sees Hermes' tools
only if their *schemas are embedded in the prompt text* and the responses are
parsed back out. That works for the turn itself, but the opencode/kilo agent
advertises its **own** toolset (bash, file edit, ...) — not Hermes' web search,
vision, skills, browser automation, or kanban tools.

So the bridge has two cooperative layers:

| Layer | Direction | What it does | How |
|---|---|---|---|
| **ACP (out)** | Hermes → opencode/kilo | Hermes spawns opencode/kilo as an ACP backend; the model runs inside it | `provider: opencode-acp`, `base_url: acp://opencode` (same for kilocode) |
| **MCP (back)** | opencode/kilo → Hermes | The opencode/kilo agent calls Hermes' real, working tools | `hermes-tools` stdio MCP server registered in each client's MCP config |

The two layers compose: ACP carries the LLM turn **out**; MCP brings Hermes
capability **back in**.

```
                    ACP (LLM turn, prompt text)
    Hermes  ──────────────────────────────────────▶  opencode / kilocode
       ▲                                                  │
       │  MCP "hermes-tools" (stdio, JSON-RPC 2.0)        │
       └──────────────────────────────────────────────────┘
              web_search · web_extract · vision_analyze · skills
              text_to_speech · browser_* · image_generate · kanban_*
```

## The pieces

### 1. Hermes side — ACP out (config.yaml)

```yaml
model:
  default: opencode/mimo-v2.5-free
  provider: opencode-acp
  base_url: acp://opencode
```

Hermes' OpenAI-shaped bridge (`agent/acp_openai_bridge.py`) renders its tool
schemas into the prompt (`render_tool_bridge_sections`) and extracts tool calls
back out of the response text with a `<tool_call>{...}</tool_call>` parse
(`extract_tool_calls_from_text`). A client with its own tools receives only the
Hermes tools that overlap-free region needs; a bare CLI receives everything.

A fallback pool (`fallback_providers`) rotates free models across both
backends — see `config/config.yaml.acp-mcp`.

### 2. Hermes side — the MCP transport (`rust/hermes-tools-mcp` + `worker/hermes_tools_worker.py`)

A **Rust stdio MCP server** (newline-delimited JSON-RPC 2.0) that exposes
Hermes' tools to **any** MCP client, backed by a long-lived warm Python worker:

```
                  tools/list · tools/call
  opencode / kilo ─────────────────────────▶ rust/hermes-tools-mcp  (stdio)
                                              │  JSON-RPC over Unix socket
                                              ▼
                                    worker/hermes_tools_worker.py
                                      (imports model_tools once)
```

The Rust binary is the client-facing process that opencode/kilocode spawns; it
shares **one** warm Python worker (`agent.transports.hermes_tools_worker`)
across all sessions so the ~1.5 s `model_tools` import and ~115 MB resident
worker happen once, not per client process. Behavior is identical to the
Python server:

- builds the authoritative tool schemas from
  `model_tools.get_tool_definitions(quiet_mode=True)`,
- registers the curated `EXPOSED_TOOLS` set,
- dispatches each call through `model_tools.handle_function_call(...)`,
- runs the worker with `HERMES_QUIET=1` / `HERMES_REDACT_SECRETS=true`; the
  worker logs to `<socket>.log` (never stdout) so the stdio wire stays clean.

Build:

```bash
cd rust/hermes-tools-mcp          # or this repo's rust/
cargo build --release
cp target/release/hermes-tools-mcp "$HERMES_AGENT_DIR/venv/bin/"
```

The worker is invoked by the binary via `python -m agent.transports.hermes_tools_worker`
from a hermes-agent checkout (socket `--socket`, idle exit `--idle-seconds`
default 300, socket `chmod 0600`).

### 3. Hermes side — the original Python MCP server (`connector/hermes_tools_mcp_server.py`)

Kept verbatim as the reference implementation and fallback. Standalone use:

```bash
python -m agent.transports.hermes_tools_mcp_server
```

### 4. Client side — MCP registration

Register the server as a local stdio MCP server in each client's global config:

- **opencode** → `~/.config/opencode/opencode.jsonc`
- **kilocode** → `~/.config/kilo/kilo.jsonc`

Minimal entry (paths → `$HERMES_AGENT_DIR` placeholder; see
`config/opencode.mcp.jsonc` / `config/kilo.mcp.jsonc`):

```jsonc
{
  "mcp": {
    "hermes-tools": {
      "type": "local",
      "command": [
        "$HERMES_AGENT_DIR/venv/bin/hermes-tools-mcp",
        "--socket",
        "$HERMES_RUN_DIR/hermes-tools.sock",
        "--worker-python",
        "$HERMES_AGENT_DIR/venv/bin/python",
        "--cwd",
        "$HERMES_AGENT_DIR",
        "--idle-seconds",
        "600"
      ],
      "cwd": "$HERMES_AGENT_DIR",
      "enabled": true
    }
  }
}
```

The Python-server variant (fallback) replaces the command with
`["$HERMES_AGENT_DIR/venv/bin/python", "-m", "agent.transports.hermes_tools_mcp_server"]`.

Verify with `opencode mcp list` / `kilo mcp list` → `hermes-tools ✓ connected`.

## Exposed tools

The curated `EXPOSED_TOOLS` surface (see the module constant):

- `web_search`, `web_extract`
- browser automation: `browser_navigate`, `browser_click`, `browser_type`,
  `browser_press`, `browser_snapshot`, `browser_scroll`, `browser_back`,
  `browser_get_images`, `browser_console`, `browser_vision`
- `vision_analyze`, `image_generate`, `skill_view`, `skills_list`,
  `text_to_speech`
- kanban handoff: `kanban_complete/block/request_review/request_changes/comment/
  heartbeat/show/list`
- orchestrator (gated on `HERMES_KANBAN_TASK` unset): `kanban_create`,
  `kanban_unblock`, `kanban_link`

Some tools only register when their environment is present (browser backend +
Chromium, image FAL key or image provider, kanban toolset) — the server skips a
tool that is not registered in the Hermes process rather than advertising a
dead one.

## Wiring it up end-to-end

1. Have a `hermes-agent` checkout with its venv and the `mcp` package
   (`pip install "mcp>=2"`).
2. Set Hermes' model to an ACP backend (see `config.yaml.acp-mcp`).
3. Register `hermes-tools` in opencode and/or kilocode configs.
4. Confirm registration: `opencode mcp list`, `kilo mcp list`.
5. Run a turn. The opencode/kilo agent now has `hermes-tools_*` tools backed by
   Hermes' real implementations.

### Verified smoke tests (free models)

- `opencode run -m opencode/big-pickle "<prompt>"` → invokes
  `hermes-tools_web_search`, returns real results.
- `kilo run -m kilo/kilo-auto/free "<prompt>"` → same for kilocode.
- `hermes -m opencode/mimo-v2.6-flash-free --provider opencode-acp -z "<prompt>"` →
  the Hermes agent drives opencode over ACP and the opencode agent calls back
  into Hermes via MCP.
- `hermes -m kilo/kilo-auto/free --provider kilocode-acp -z "<prompt>"` → same
  for kilocode.

All four paths resolve through the same Rust `hermes-tools-mcp` binary and one
shared warm worker.

## Notes and roadmap

- The MCP wire is newline-delimited JSON-RPC 2.0 on stdio (UTF-8), matching the
  `mcp` 2.x server (`mcp.server.MCPServer`).
- The Rust front-end (`rust/`) spawns the worker if the socket is unreachable,
  retries on a dropped connection, and handles `initialize`, `ping`,
  `tools/list`, `tools/call`, and `method-not-found` (-32601) exactly like the
  Python server.
- `connector/hermes_tools_mcp_server.py` and
  `worker/hermes_tools_worker.py` originate from
  [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)
  (Apache-2.0); the server is mirrored verbatim for standalone reference, the
  worker ships as the shared backend for the Rust front-end.
- **Roadmap:** publish the compiled Rust binary as a released asset; port the
  worker itself to Rust for fully dependency-free operation.

## License

Apache-2.0 (matching the source project). See `LICENSE`.