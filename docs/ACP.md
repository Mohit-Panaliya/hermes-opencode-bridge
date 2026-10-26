# The ACP layer (Hermes → opencode / kilocode)

The **outbound** half of the bridge: Hermes hands the LLM turn to a local
`opencode acp` / `kilo acp` subprocess over the Agent Client Protocol, and the
model executes *inside* that client.

```
Hermes turn ──▶ ACP client (stdio) ──▶ `opencode acp` / `kilo acp` subprocess
                                         └─ the model + the client's own tools
```

## Why an ACP provider plugin is required

`provider: opencode-acp` and `provider: kilocode-acp` are **not** built into
Hermes. They are `kind: model-provider` plugins. On a fresh machine, without
them, Hermes reports an unknown provider and the ACP turn never starts.

They ship in this repo under:

```
providers/opencode-acp/   __init__.py + plugin.yaml
providers/kilocode-acp/   __init__.py + plugin.yaml
```

Install them into the Hermes home (the installer script does this for you):

```bash
cp -r providers/opencode-acp providers/kilocode-acp \
  "$HOME/.hermes/plugins/model-providers/"
```

Hermes discovers user model-provider plugins from
`$HERMES_HOME/plugins/model-providers/` at runtime (lazy, on first provider
lookup) — no separate enable step.

## What each plugin does

Both profiles subclass `ProviderProfile` and override `create_client()` to build
an **ACP stdio shim** (`agent.copilot_acp_client.CopilotACPClient`) instead of an
HTTP client. Key attributes:

| | `opencode-acp` | `kilocode-acp` |
|---|---|---|
| aliases | `opencode-acp-agent`, `oc-acp` | `kilo-acp`, `kilo-acp-agent` |
| `base_url` | `acp://opencode` | `acp://kilocode` |
| subprocess | `opencode acp` | `kilo acp` |
| command override env | `HERMES_OPENCODE_ACP_COMMAND` | `HERMES_KILOCODE_ACP_COMMAND` |
| args override env | `HERMES_OPENCODE_ACP_ARGS` | `HERMES_KILOCODE_ACP_ARGS` |
| auth | managed by the `opencode` CLI | managed by the `kilo` CLI |
| default aux model | `opencode/mimo-v2.5-free` | `kilo/~z-ai/glm-flash-latest` |

`env_vars=()` on purpose: the subprocess owns credentials. Put keys in
`~/.hermes/.env` only for **native** providers you mix into the fallback pool.

Override the binary/args when it is not on the service `PATH`:

```bash
export HERMES_OPENCODE_ACP_COMMAND=/home/YOU/.nvm/versions/node/vXX/bin/opencode
export HERMES_KILOCODE_ACP_COMMAND=/home/YOU/.nvm/versions/node/vXX/bin/kilo
```

(For a systemd service, put these in the unit's `Environment=`, not your shell.)

## Config

`~/.hermes/config.yaml`:

```yaml
model:
  default: opencode/mimo-v2.5-free
  provider: opencode-acp
  base_url: acp://opencode
```

or kilocode:

```yaml
model:
  default: kilo/kilo-auto/free
  provider: kilocode-acp
  base_url: acp://kilocode
```

`base_url` must use the `acp://` scheme — that scheme is what routes the turn to
the external-process client rather than an OpenAI HTTP endpoint.

## How tools flow (and why MCP is still needed)

ACP has **no `tools` / `tool_calls` channel**. `agent/acp_openai_bridge.py`:

- `render_tool_bridge_sections()` renders Hermes' tool schemas **into the prompt
  text** for the turn;
- `extract_tool_calls_from_text()` parses `<tool_call>{...}</tool_call>` back out
  of the model's reply.

Clients differ in *which* tools Hermes forwards (`allowlist`): a bare CLI with no
tools of its own forwards everything; an autonomous agent that already has
read/edit/execute tools forwards only Hermes' non-overlapping agent-level tools,
because re-offering overlapping ones makes Hermes redo finished work.

That prompt-level channel is enough to *drive the turn*, but the client still
executes only **its own** tools. To let the spawned agent reach Hermes' real
web/vision/browser/skill/kanban tools, expose them as an MCP server — that is the
*inbound* layer, documented in [MCP.md](MCP.md).

## Free-model fallback pool

`fallback_providers` rotates across both ACP backends and any native provider.
Copy `config/config.yaml.model-fallback.yaml`; the shape is:

```yaml
model:
  default: kilo/nvidia/nemotron-3-ultra-550b-a55b:free
  provider: kilocode-acp
  base_url: acp://kilocode

fallback_providers:
  - { provider: kilocode-acp, model: kilo/kilo-auto/free }
  - { provider: opencode-acp, model: opencode/mimo-v2.5-free }
  - { provider: nvidia, model: moonshotai/kimi-k3, key_env: NVIDIA_API_KEY }
```

Order least-paid → most-paid (or free → keyed). Model ids change often; verify a
free id still exists in the client (`opencode models`, `kilo models`) before
relying on it.

## Verifying the ACP path

```bash
# The provider must be known to Hermes:
hermes --provider opencode-acp -m opencode/mimo-v2.5-free -z "say hello"

# Full path, including MCP tools back in:
hermes --provider kilocode-acp -m kilo/kilo-auto/free \
  -z "Use your hermes-tools web_search tool and report one result."
```

If the provider is "unknown", the plugin is not installed (see the top of this
doc). If the subprocess fails to spawn, the CLI is not on `PATH` — set the
`*_ACP_COMMAND` env var.
