# Full setup from a clean machine

> Shortcut: after the prerequisites, `./scripts/install-bridge.sh --with-rust`
> performs steps 4–6b (mcp, launcher, provider plugins, optional Rust build) and
> prints the config blocks still to merge. The manual steps below explain each.

This is the complete, ordered build-up for a machine that has **neither** Hermes
nor opencode/kilocode yet. If you already have some of the pieces, skip to the
section you need — every step says how to check whether it is already done.

The goal state:

```
~/.hermes/hermes-agent/                 Hermes source + venv
  venv/bin/python                       Python 3.12 with the `mcp` package
  venv/bin/hermes-tools-mcp-launch      launcher (the MCP `command`)
  venv/bin/hermes-tools-mcp             Rust transport (optional, fast path)
~/.hermes/plugins/model-providers/      ACP provider plugins (opencode-acp, kilocode-acp)
~/.hermes/config.yaml                   model routing (ACP)
~/.hermes/.env                          API keys (secrets, never committed)
~/.config/opencode/opencode.jsonc       opencode: hermes-tools MCP registration
~/.config/kilo/kilo.jsonc               kilocode: hermes-tools MCP registration
```

Throughout, `HERMES_AGENT_DIR` means the Hermes checkout. The official installer
puts it at `$HOME/.hermes/hermes-agent`.

```bash
export HERMES_AGENT_DIR="${HERMES_AGENT_DIR:-$HOME/.hermes/hermes-agent}"
```

---

## 1. Prerequisites

| Need | Why | Check | Install |
|---|---|---|---|
| Linux or macOS (WSL2 ok) | runtime | `uname -s` | — |
| Python 3.12 | Hermes runtime | `python3 --version` | distro package / `uv` (installer brings it) |
| Node.js 20+ | opencode + kilocode are npm CLIs | `node --version` | https://nodejs.org or nvm |
| git | clone + updates | `git --version` | distro package |
| curl | installer | `curl --version` | distro package |
| Rust toolchain (**optional**) | build the fast MCP transport | `cargo --version` | https://rustup.rs |

You do **not** need Rust. Without `cargo`, the launcher transparently uses the
Python MCP server (identical tool surface, slightly higher per-call latency).

Optional, for the `browser_*` tools to do anything: a Chromium/Chrome install
(the Playwright backend downloads one on first use).

---

## 2. Install Hermes Agent

**Check:** `test -d "$HERMES_AGENT_DIR" && echo already-installed`

**Install (Linux / macOS / WSL2):**

```bash
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
```

Windows native uses `install.ps1` — see the upstream README.

Then confirm:

```bash
"$HERMES_AGENT_DIR/venv/bin/hermes" --version
# e.g. Hermes Agent v0.22.1+104 ... · stable
```

If your checkout lives somewhere else, set and export `HERMES_AGENT_DIR` to it
for the rest of this guide.

---

## 3. Install opencode and kilocode

Both are npm CLIs. Install globally so they land on `PATH`:

```bash
npm install -g opencode-ai @kilocode/cli
opencode --version      # e.g. 1.18.35
kilo --version          # e.g. 7.7.9
```

If `opencode`/`kilo` are not found afterwards, your npm global bin directory is
not on `PATH`. `npm bin -g` prints it; add it to your shell profile.

---

## 4. Install the `mcp` Python package into the Hermes venv

The bridge imports `mcp`. It must be importable by **the Hermes venv Python**,
not the system Python:

```bash
"$HERMES_AGENT_DIR/venv/bin/pip" install "mcp>=2"
"$HERMES_AGENT_DIR/venv/bin/python" -c "import mcp; print('mcp ok')"
```

> Version note: `mcp` 2.x renamed `mcp.server.fastmcp` to `mcp.server.MCPServer`.
> The bundled server handles both; use `mcp>=2`.

---

## 5. Install the launcher

The launcher is the single `command` both clients point at. It prefers the Rust
transport and falls back to Python. Install it **into the venv's `bin`** so the
path in the configs is stable:

```bash
install -m 0755 scripts/hermes-tools-mcp-launch \
  "$HERMES_AGENT_DIR/venv/bin/hermes-tools-mcp-launch"
```

It reads these env vars (all optional, sensible defaults):

| Var | Default | Meaning |
|---|---|---|
| `HERMES_AGENT_DIR` | `$HOME/.hermes/hermes-agent` | Hermes checkout |
| `PYTHON_BIN` | `$HERMES_AGENT_DIR/venv/bin/python` | worker interpreter |
| `RUST_BIN` | `$HERMES_AGENT_DIR/venv/bin/hermes-tools-mcp` | Rust transport |
| `HERMES_RUN_DIR` | `$HOME/.hermes/run` | socket directory |
| `HERMES_TOOLS_SOCKET` | `$HERMES_RUN_DIR/hermes-tools.sock` | warm worker socket |
| `HERMES_TOOLS_WORKER_MODULE` | `agent.transports.hermes_tools_worker` | worker module |
| `HERMES_TOOLS_IDLE_SECONDS` | `600` | worker idle exit |

Smoke-test the launcher directly (it should start and wait on stdio, then exit
when stdin closes):

```bash
printf '%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
 | "$HERMES_AGENT_DIR/venv/bin/hermes-tools-mcp-launch" | head -c 300; echo
```

You should see a JSON-RPC `initialize` result. If you see a Python traceback
instead, fix step 4 before continuing.

---

## 5b. Install the ACP provider plugins (required for `*-acp`)

`provider: opencode-acp` and `provider: kilocode-acp` are **not built into
Hermes** — they are `model-provider` plugins. Install both into the Hermes home:

```bash
mkdir -p "$HOME/.hermes/plugins/model-providers"
cp -r providers/opencode-acp providers/kilocode-acp \
  "$HOME/.hermes/plugins/model-providers/"
```

Confirm:

```bash
ls "$HOME/.hermes/plugins/model-providers/opencode-acp/__init__.py" \
   "$HOME/.hermes/plugins/model-providers/kilocode-acp/__init__.py"
```

Hermes discovers them lazily on first provider lookup; no enable step. Skipping
this is the most common fresh-install failure — the model turn then reports an
unknown provider. See [ACP.md](ACP.md) for what each plugin defines.

---

## 6. Build the Rust transport (optional, recommended)

The Rust front-end is what makes many concurrent clients cheap: it keeps **one**
warm Python worker (the ~1.5 s `model_tools` import happens once) and multiplexes
all sessions over a Unix socket.

```bash
cd rust
cargo build --release
install -m 0755 target/release/hermes-tools-mcp \
  "$HERMES_AGENT_DIR/venv/bin/hermes-tools-mcp"
cd ..
```

Verify the fast path is healthy:

```bash
"$HERMES_AGENT_DIR/venv/bin/hermes-tools-mcp" --check \
  --socket "$HOME/.hermes/run/hermes-tools.sock" \
  --worker-python "$HERMES_AGENT_DIR/venv/bin/python" \
  --worker-module agent.transports.hermes_tools_worker \
  --cwd "$HERMES_AGENT_DIR"
echo "exit=$?  (0 = rust path ready)"
```

If `--check` fails or `cargo` is missing, **skip this step** — the launcher will
use the Python server. Do not copy a broken binary into `venv/bin`.

Rust flags (all optional except `--socket`):

```
--socket <path>          Unix socket for the warm worker (required)
--worker-python <path>   interpreter for the worker
--worker-module <name>   default agent.transports.hermes_tools_worker
--cwd <path>             working dir (must contain Hermes' model_tools)
--idle-seconds <n>       worker idle exit (default 300; launcher passes 600)
--max-wait-ms <n>        per-call wait ceiling (default 10000)
--verbose | -v
--check                  verify worker python+module and exit
```

---

## 7. Register the MCP server in opencode

Config path: **`~/.config/opencode/opencode.jsonc`** (create it if missing).
Merge this into the existing object — do not replace other keys:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "hermes-tools": {
      "type": "local",
      "command": [
        "/home/YOU/.hermes/hermes-agent/venv/bin/hermes-tools-mcp-launch"
      ],
      "cwd": "/home/YOU/.hermes/hermes-agent",
      "enabled": true
    }
  }
}
```

Use **absolute paths** here. opencode does not expand `$HERMES_AGENT_DIR` in the
`command` array, so substitute your real home/checkout (the `config/` snippets
use the variable only as documentation).

Check:

```bash
opencode mcp list
# hermes-tools  ✓ connected
```

If it says failed, run the launcher path by hand (step 5) and read the error.

---

## 8. Register the MCP server in kilocode

Config path: **`~/.config/kilo/kilo.jsonc`**, same block, same launcher, but the
schema URL differs:

```jsonc
{
  "$schema": "https://app.kilo.ai/config.json",
  "mcp": {
    "hermes-tools": {
      "type": "local",
      "command": [
        "/home/YOU/.hermes/hermes-agent/venv/bin/hermes-tools-mcp-launch"
      ],
      "cwd": "/home/YOU/.hermes/hermes-agent",
      "enabled": true
    }
  }
}
```

Check:

```bash
kilo mcp list
# hermes-tools  ✓ connected
```

> Some kilo versions expose the list under the console UI instead. Either way,
> the underlying check is the same stdio handshake exercised in step 5.

---

## 9. Authenticate the clients

ACP launches opencode/kilo as a subprocess. They must already be able to reach a
model without an interactive login, or the ACP turn will fail.

```bash
opencode auth login     # follow prompts for the provider you will route to
kilo auth login         # same for kilocode
```

Free tiers still require an account/token in most cases. Do this once per
machine while you have a browser available.

---

## 10. Point Hermes at an ACP backend

Edit `~/.hermes/config.yaml`. Minimal opencode routing:

```yaml
model:
  default: opencode/mimo-v2.5-free
  provider: opencode-acp
  base_url: acp://opencode
```

Or an ordered free-model pool that spans both backends (copy from
`config/config.yaml.model-fallback.yaml`):

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

Notes:

- The `provider: *-acp` names and `base_url: acp://opencode|kilocode` are what
  select the ACP path. The model id is passed through to the client.
- Native providers can be mixed in; keep API keys in `~/.hermes/.env` and
  reference them by name (`key_env:`), never inline in `config.yaml`.
- Model ids churn. Confirm the free id still exists in the target client before
  trusting an example.

---

## 11. Verify end to end

```bash
./scripts/verify.sh
```

Then the four smoke tests (each exercises a different path of the bridge):

```bash
# MCP only, opencode client
opencode run -m opencode/big-pickle \
  "Use the hermes-tools web_search tool to search for 'hermes agent' and summarise."

# MCP only, kilocode client
kilo run -m kilo/kilo-auto/free \
  "Use the hermes-tools web_search tool to search for 'hermes agent' and summarise."

# ACP out + MCP back in, through Hermes -> opencode
hermes -m opencode/mimo-v2.6-flash-free --provider opencode-acp \
  -z "Search the web with your hermes-tools tools and tell me what you found."

# ACP out + MCP back in, through Hermes -> kilocode
hermes -m kilo/kilo-auto/free --provider kilocode-acp \
  -z "Search the web with your hermes-tools tools and tell me what you found."
```

Pass criteria: the tool call appears (`hermes-tools_web_search`) and real results
come back. A model that answers without calling the tool is a model-choice issue,
not a bridge failure — retry with a stronger model or a more direct prompt.

---

## 12. Running on a server (systemd / headless)

The bridge itself is per-invocation; there is nothing to daemonize. If a client
runs under systemd, two things bite:

1. **PATH** — `opencode`/`kilo` are invoked by ACP. Service units have a minimal
   `PATH`. Set `Environment=PATH=/home/YOU/.nvm/versions/node/vX/bin:/usr/bin:/bin`
   (or the nvm equivalent) in the unit.
2. **HOME** — the launcher and clients read config under `$HOME`. Set
   `Environment=HOME=/home/YOU` explicitly; system units otherwise run with a
   different home.

For a web-facing opencode/kilo, put an authenticating reverse proxy in front;
the CLI's own password is HTTP Basic, which pops a native browser dialog. That is
outside this repo's scope.

---

## 13. Upgrade / uninstall

- **Update Hermes:** re-run the installer; then re-run step 4 (`pip install "mcp>=2"`)
  and step 5 (launcher) — an update can replace `venv/`.
- **Update opencode/kilo:** `npm update -g opencode-ai @kilocode/cli`; re-check
  step 7/8 config paths (rarely move).
- **Uninstall the bridge:** delete the `hermes-tools` block from both client
  configs, then `rm "$HERMES_AGENT_DIR/venv/bin/hermes-tools-mcp"{,-launch}` and
  the Rust build dir. No files outside those locations are touched.

---

## Appendix — path conventions

| Thing | Default | Override |
|---|---|---|
| Hermes checkout | `~/.hermes/hermes-agent` | `HERMES_AGENT_DIR` |
| Hermes venv python | `<checkout>/venv/bin/python` | `PYTHON_BIN` |
| Launcher | `<checkout>/venv/bin/hermes-tools-mcp-launch` | — |
| Rust binary | `<checkout>/venv/bin/hermes-tools-mcp` | `RUST_BIN` |
| Worker socket dir | `~/.hermes/run` | `HERMES_RUN_DIR` |
| Worker socket | `~/.hermes/run/hermes-tools.sock` | `HERMES_TOOLS_SOCKET` |
| Worker module | `agent.transports.hermes_tools_worker` | `HERMES_TOOLS_WORKER_MODULE` |
| ACP provider plugins | `~/.hermes/plugins/model-providers/{opencode,kilocode}-acp` | `HERMES_HOME` |
| opencode config | `~/.config/opencode/opencode.jsonc` | `XDG_CONFIG_HOME` |
| kilo config | `~/.config/kilo/kilo.jsonc` | `XDG_CONFIG_HOME` |
