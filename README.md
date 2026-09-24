# hermes-opencode-bridge

Bridge Hermes Agent to **opencode** and **kilocode** (a KiloCode fork/variant of
opencode) so the model runs inside the opencode/kilo process while keeping
Hermes' real tool surface reachable — in both directions.

This repo documents the connector, ships the Python MCP server verbatim, and
carries sanitized configuration examples.

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

### 2. Hermes side — the MCP server (`connector/hermes_tools_mcp_server.py`)

A stdio MCP server (newline-delimited JSON-RPC 2.0) that exposes Hermes' tools
to **any** MCP client. It:

- builds the authoritative tool schemas from
  `model_tools.get_tool_definitions(quiet_mode=True)`,
- registers the curated `EXPOSED_TOOLS` set,
- dispatches each call through `model_tools.handle_function_call(...)`,
- runs with `HERMES_QUIET=1` / `HERMES_REDACT_SECRETS=true` and logs only to
  stderr so the stdio wire stays clean.

```bash
# from a hermes-agent checkout with the mcp package installed
python -m agent.transports.hermes_tools_mcp_server
```

### 3. Client side — MCP registration

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
        "$HERMES_AGENT_DIR/venv/bin/python",
        "-m",
        "agent.transports.hermes_tools_mcp_server"
      ],
      "cwd": "$HERMES_AGENT_DIR",
      "enabled": true
    }
  }
}
```

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

### Verified smoke tests

- `opencode run "<prompt>"` → invokes `hermes-tools_web_search`, returns real
  results.
- `kilo run "<prompt>"` → same.
- `hermes -z "<prompt>" --provider opencode-acp` → the Hermes agent drives
  opencode over ACP and the opencode agent calls back into Hermes via MCP.
- `hermes -z "<prompt>" --provider kilocode-acp` → same for kilocode.

## Notes and roadmap

- The MCP wire is newline-delimited JSON-RPC 2.0 on stdio (UTF-8), matching the
  `mcp` 2.x server (`mcp.server.MCPServer`).
- `connector/hermes_tools_mcp_server.py` originates from
  [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)
  (`agent/transports/hermes_tools_mcp_server.py`), Apache-2.0; mirrored here
  verbatim for standalone reference.
- **Roadmap:** a Rust MCP transport front-end over a shared warm Hermes tool
  worker — cuts per-session cold start (~1.7 s Python import) and duplicated
  ~85 MB resident memory per client process.

## License

Apache-2.0 (matching the source project). See `LICENSE`.