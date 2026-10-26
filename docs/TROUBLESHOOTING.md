# Troubleshooting

Symptom → cause → fix. Start with `./scripts/verify.sh`.

---

## ACP layer

### `Unknown provider: opencode-acp` / `kilocode-acp`
**Cause:** the provider plugins are not installed. They are user plugins, not
bundled with Hermes.
**Fix:**
```bash
cp -r providers/opencode-acp providers/kilocode-acp \
  "$HOME/.hermes/plugins/model-providers/"
```
Restart Hermes. Confirm the files exist:
`~/.hermes/plugins/model-providers/opencode-acp/__init__.py`.

### ACP turn fails immediately / subprocess not found
**Cause:** `opencode` or `kilo` is not on the `PATH` of the process running
Hermes (very common under systemd, or when Node is installed via nvm).
**Fix:** point the provider at the absolute binary:
```bash
export HERMES_OPENCODE_ACP_COMMAND=/home/YOU/.nvm/versions/node/vXX/bin/opencode
export HERMES_KILOCODE_ACP_COMMAND=/home/YOU/.nvm/versions/node/vXX/bin/kilo
```
For a service, add those to the unit's `Environment=`.

### Free model returns "model not found"
**Cause:** free-tier model ids churn; an id in the examples no longer exists.
**Fix:** list what the client currently offers and update `config.yaml`:
```bash
opencode models | grep -i free
kilo models | grep -i free
```

### ACP works but the agent never uses Hermes tools
**Cause:** ACP only carries tool schemas in the prompt text; the client still
executes its own tools. Without the MCP server the agent cannot reach Hermes.
**Fix:** finish the MCP registration ([SETUP.md](SETUP.md) §7–8) and confirm
`opencode mcp list` / `kilo mcp list` show `connected`.

---

## MCP layer

### `mcp list` shows `hermes-tools failed`
Run the launcher by hand to see the real error:
```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
| "$HERMES_AGENT_DIR/venv/bin/hermes-tools-mcp-launch"
```
Common causes below.

### `ModuleNotFoundError: mcp`
**Cause:** `mcp` was installed into system Python, not the Hermes venv.
**Fix:** `"$HERMES_AGENT_DIR/venv/bin/pip" install "mcp>=2"`.

### `ModuleNotFoundError: model_tools` / `agent.transports...`
**Cause:** wrong `cwd`, or `HERMES_AGENT_DIR` points at the wrong checkout.
**Fix:** the MCP `cwd` and `PYTHON_BIN` must both be inside the Hermes checkout
that contains `model_tools.py`.

### Launcher path wrong / `No such file or directory`
**Cause:** client configs used a literal `$HERMES_AGENT_DIR` placeholder.
opencode/kilo do **not** expand env vars in the `command` array.
**Fix:** use absolute paths in `opencode.jsonc` / `kilo.jsonc`.

### First call is slow (~1.5 s), later calls fast
**Normal** on the Python fallback / cold worker: `model_tools` is imported once.
The Rust transport keeps one warm worker (launcher `--idle-seconds` 600). Not a
bug.

### Stale socket / worker wedged
```bash
ls -l "$HOME/.hermes/run/hermes-tools.sock"*
# the Rust front-end respawns a dead worker; to force it:
rm -f "$HOME/.hermes/run/hermes-tools.sock"
```
If the Rust `--check` fails, the launcher silently uses Python — that is
intended degradation, not an error.

### Tools appear but some are missing
**Normal.** The server registers only tools present in the running Hermes
process. `browser_*` needs a Chromium backend, `image_generate` needs an image
provider key, kanban tools need the kanban toolset. They are skipped, not
advertised dead.

---

## opencode / kilocode: auto-approve toggle greyed out

**Symptom:** the Settings / UI "Auto-accept permissions" / "Auto-approve
requests" toggle is greyed out ("not allowed" cursor) and will not turn on, even
though you set permissions in config.

**Cause:** this is a known upstream **UI bug** in opencode (and forks), reported
in several issues (e.g. #45159 "New Layout Forcibly Disables Auto-Accept
Permissions", #41069, #37617, #38077). The toggle's disabled state is not a
correct reflection of the running permission policy.

**Fixes (pick one):**

1. **Config (persistent).** Auto-approve *does* work even while the toggle is
   greyed. Set it in the client config:
   ```jsonc
   // ~/.config/opencode/opencode.jsonc  (and ~/.config/kilo/kilo.jsonc)
   { "permission": "allow" }
   ```
   Optionally scope it to the agent you use:
   ```jsonc
   { "agent": { "build": { "permission": "allow" } } }
   ```
   `"allow"` expands to `{"*": "allow"}`. Restart the client — config is read
   once at startup.

2. **`--auto` flag (per session).** Approves anything not explicitly denied:
   ```bash
   opencode --auto
   opencode run --auto "…"
   ```

3. **Command palette.** In the TUI, open the palette and choose
   *Enable auto-approve permissions* (and *Disable …* to revert). This flips the
   runtime mode independent of the greyed toggle.

**Notes:**
- `permission: "allow"` is the widest setting — bash, edit and external
  directories run with no confirmation. Revert by deleting the key (defaults to
  `ask`).
- The greyed toggle may remain greyed after a restart; that is cosmetic. Prove
  the behaviour by running a bash tool call and seeing it execute without a
  prompt.
- If you see prompts *despite* `allow`, confirm you edited the config in the
  XDG location the client actually reads (`~/.config/opencode/`,
  `~/.config/kilo/`) and fully restarted the process.

---

## Headless / server specifics

### Everything works in my shell but not in the service
Set both in the unit:
```
Environment=HOME=/home/YOU
Environment=PATH=/home/YOU/.nvm/versions/node/vXX/bin:/usr/local/bin:/usr/bin:/bin
```
`HOME` matters because the launcher, clients and Hermes home all hang off it;
`PATH` matters because ACP spawns `opencode`/`kilo` by name.

### `$XDG_CONFIG_HOME` differences
If you set `XDG_CONFIG_HOME`, the client configs live under
`$XDG_CONFIG_HOME/opencode/` and `$XDG_CONFIG_HOME/kilo/`, not `~/.config/`.
`verify.sh` checks `~/.config`; adjust if you relocated it.

---

## Version/behaviour drift

- `mcp` 2.x renamed `fastmcp` → `MCPServer`. The bundled server handles both;
  pin `mcp>=2`.
- Free model ids and providers change frequently. Treat every model id as a
  placeholder and re-check at setup time.
- After a Hermes update, re-run the installer (`pip install mcp>=2`, reinstall
  the launcher and plugins) — an update can replace `venv/`.
