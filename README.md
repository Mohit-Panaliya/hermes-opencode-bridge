# hermes-opencode-bridge

Run **Hermes Agent** with the language model executing inside **opencode** or
**kilocode** (the Kilo fork of opencode) over the Agent Client Protocol (ACP),
while Hermes' real tool surface stays reachable from inside those agents over
MCP.

Two layers, both directions:

| Layer | Direction | What it does |
|---|---|---|
| **ACP** | Hermes → opencode/kilo | Hermes spawns opencode/kilo as the LLM backend; the model runs *inside* that process |
| **MCP** | opencode/kilo → Hermes | The opencode/kilo agent calls back into Hermes' real tools (web search, vision, browser, skills, kanban, ...) through the `hermes-tools` stdio server |

```
                        ACP (LLM turn, tool schemas in prompt text)
      Hermes  ───────────────────────────────────────────────▶  opencode / kilocode
         ▲                                                          │
         │   MCP "hermes-tools" (stdio, JSON-RPC 2.0)               │
         └──────────────────────────────────────────────────────────┘
                web_search · web_extract · vision_analyze · skills
                text_to_speech · browser_* · image_generate · kanban_*
```

Why both? ACP has no native `tools`/`tool_calls` channel, and an ACP backend
advertises *its own* toolset (bash, file edit, ...), not Hermes'. So Hermes
renders its tool schemas into the prompt for the turn (ACP out), and exposes
real Hermes tools to the spawned agent as an MCP server (MCP back in).

---

## Documentation map

| Doc | Read it for |
|---|---|
| **[docs/SETUP.md](docs/SETUP.md)** | **Start here.** Full step-by-step from a clean machine: install Hermes, opencode, kilocode, the launcher, the Rust transport, and wire everything. |
| [docs/ACP.md](docs/ACP.md) | The outbound layer in depth: how Hermes spawns opencode/kilo, model routing, the free-model fallback pool. |
| [docs/MCP.md](docs/MCP.md) | The inbound layer in depth: launcher precedence, the Rust front-end, the warm Python worker, the exposed tools, the wire protocol. |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Symptom → cause → fix table, including MCP "failed" states and the known opencode auto-approve UI bug. |
| [docs/VERIFY.md](docs/VERIFY.md) | Copy-paste checks that prove each layer works. |
| [scripts/verify.sh](scripts/verify.sh) | Machine-runnable version of the checks above. |

Tested on Linux with:

- Hermes Agent `v0.22.1+104` (2026.9.24), Python `3.12`, `mcp` `2.0.0`
- `opencode-ai` `1.18.35` (npm)
- `@kilocode/cli` `7.7.9` (npm)

Model names and free tiers change frequently; treat every model id in the
examples as a placeholder you re-check at setup time.

---

## 60-second quickstart

For a machine that already has Hermes and opencode/kilo installed:

```bash
# 1. Hermes venv + MCP dependency
HERMES_AGENT_DIR="${HERMES_AGENT_DIR:-$HOME/.hermes/hermes-agent}"
"$HERMES_AGENT_DIR/venv/bin/pip" install "mcp>=2"

# 2. Install the launcher (rust-preferred, python-fallback)
install -m 0755 scripts/hermes-tools-mcp-launch \
  "$HERMES_AGENT_DIR/venv/bin/hermes-tools-mcp-launch"

# 3. Install the ACP provider plugins (REQUIRED for *-acp providers)
cp -r providers/opencode-acp providers/kilocode-acp \
  "$HOME/.hermes/plugins/model-providers/"

# 4. Optional: build the fast Rust transport
( cd rust && cargo build --release && \
  install -m 0755 target/release/hermes-tools-mcp \
    "$HERMES_AGENT_DIR/venv/bin/hermes-tools-mcp" ) || \
  echo "no cargo — Python fallback will be used"

# 5. Register the MCP server in both clients (merge, don't overwrite)
#    see config/opencode.mcp.jsonc and config/kilo.mcp.jsonc

# 6. Point Hermes at an ACP backend
#    see config/config.yaml.acp-mcp

# 7. Prove it
./scripts/verify.sh
```

The full, ordered version with explanations is in **[docs/SETUP.md](docs/SETUP.md)**.

---

## Repository layout

```
providers/opencode-acp/       ACP model-provider plugin (REQUIRED for provider: opencode-acp)
providers/kilocode-acp/       ACP model-provider plugin (REQUIRED for provider: kilocode-acp)
rust/                         Rust MCP transport (stdio JSON-RPC front-end)
  src/main.rs                 initialize/ping/tools/list/tools/call, worker supervisor
  Cargo.toml, Cargo.lock
worker/hermes_tools_worker.py Shared warm Python worker (imports model_tools once)
connector/hermes_tools_mcp_server.py
                              Original Python MCP server (reference + fallback)
scripts/hermes-tools-mcp-launch
                              Chooses Rust vs Python; this is the MCP `command`
scripts/install-bridge.sh     Installs mcp + launcher + provider plugins (+ optional Rust)
scripts/verify.sh             End-to-end environment checks
config/opencode.mcp.jsonc     opencode MCP registration snippet
config/kilo.mcp.jsonc         kilocode MCP registration snippet
config/config.yaml.acp-mcp    Hermes ACP model-routing snippet
config/config.yaml.model-fallback.yaml
                              Free-model fallback pool example
docs/                         Setup, ACP, MCP, verification, troubleshooting
```

---

## How the two halves fit together

### Out: ACP (Hermes → opencode/kilo)

`config.yaml` selects an ACP provider:

```yaml
model:
  default: opencode/mimo-v2.5-free
  provider: opencode-acp
  base_url: acp://opencode
```

or `provider: kilocode-acp`, `base_url: acp://kilocode`.

> **Required on a fresh machine:** those provider names come from the user
> plugins in `providers/` (`opencode-acp`, `kilocode-acp`) — they are not built
> into Hermes. Install them into `~/.hermes/plugins/model-providers/` first, or
> Hermes reports an unknown provider. See [docs/SETUP.md](docs/SETUP.md#5b-install-the-acp-provider-plugins).

Hermes'
`agent/acp_openai_bridge.py` renders tool schemas into the prompt and parses
`<tool_call>{...}</tool_call>` back out of the reply. A `fallback_providers`
pool rotates free models across both backends. Details: **[docs/ACP.md](docs/ACP.md)**.

### Back in: MCP (opencode/kilo → Hermes)

Both clients register one local stdio server named `hermes-tools` whose command
is the launcher:

```jsonc
{
  "mcp": {
    "hermes-tools": {
      "type": "local",
      "command": ["$HERMES_AGENT_DIR/venv/bin/hermes-tools-mcp-launch"],
      "cwd": "$HERMES_AGENT_DIR",
      "enabled": true
    }
  }
}
```

The launcher `exec`s the Rust `hermes-tools-mcp` when it exists and `--check`
passes, otherwise `exec`s `python -m agent.transports.hermes_tools_mcp_server`.
Either way the client sees the same tools. Details: **[docs/MCP.md](docs/MCP.md)**.

---

## Exposed tools

`web_search`, `web_extract`, browser automation (`browser_navigate`,
`browser_click`, `browser_type`, `browser_press`, `browser_snapshot`,
`browser_scroll`, `browser_back`, `browser_get_images`, `browser_console`,
`browser_vision`), `vision_analyze`, `image_generate`, `skill_view`,
`skills_list`, `text_to_speech`, and the kanban handoff/orchestrator tools.

A tool whose backend is not configured in the Hermes process is **skipped**, not
advertised dead — the server only registers what Hermes actually has.

---

## Security

- **Never commit credentials.** `.env`, `*pat*`, `*.bak*` are git-ignored. Model
  keys live in Hermes' `~/.hermes/.env` and are referenced by name (`key_env:`),
  never inlined.
- The worker runs with `HERMES_QUIET=1` and `HERMES_REDACT_SECRETS=true`, logs to
  `<socket>.log` (never stdout), and chmods the socket `0600`.
- `hermes-tools` is a **local stdio** server; it does not open a network port.
- Treat any pasted token as compromised: revoke and re-issue rather than reusing.

## License

Apache-2.0 (matching the upstream Hermes Agent project). See [LICENSE](LICENSE).

`connector/hermes_tools_mcp_server.py` and `worker/hermes_tools_worker.py`
originate from [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent).
