# Verify the bridge

Copy-paste checks, ordered from cheapest to fullest. `scripts/verify.sh` runs the
static ones for you.

## 1. Static environment

```bash
./scripts/verify.sh
```

Checks, in order: Hermes checkout + venv, `mcp` importable by the **venv**
python, launcher present, both ACP provider plugins installed, optional Rust
`--check`, launcher stdio handshake, client config registration + `mcp list`,
and ACP selection in `config.yaml`.

## 2. MCP server answers (no client involved)

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
| "$HERMES_AGENT_DIR/venv/bin/hermes-tools-mcp-launch" | head -c 1200; echo
```

Expect an `initialize` result, then a `tools/list` result containing
`hermes-tools_web_search` etc. A Python traceback here is a venv/`mcp` problem
(step 4 of [SETUP.md](SETUP.md)).

## 3. Client sees the server

```bash
opencode mcp list
kilo mcp list
```

Both should show `hermes-tools ... connected`. If "failed", run the launcher by
hand (check 2) and read stderr.

## 4. MCP tool call, per client

```bash
opencode run -m opencode/big-pickle \
  "Use the hermes-tools web_search tool to search 'hermes agent' and summarise one result."

kilo run -m kilo/kilo-auto/free \
  "Use the hermes-tools web_search tool to search 'hermes agent' and summarise one result."
```

Pass: the transcript shows a `hermes-tools_web_search` call and real results.
If the model answers from memory without calling the tool, retry with a stronger
model / a more explicit instruction — that is model behaviour, not the bridge.

## 5. Full loop: ACP out + MCP back in

```bash
hermes --provider opencode-acp -m opencode/mimo-v2.6-flash-free \
  -z "Use your hermes-tools web_search tool and report one result."

hermes --provider kilocode-acp -m kilo/kilo-auto/free \
  -z "Use your hermes-tools web_search tool and report one result."
```

This proves both directions at once: Hermes spawned the client over ACP, the
client's model executed the turn, and it reached back into Hermes over MCP.

## 6. Worker health (Rust path)

```bash
ls -l "$HOME/.hermes/run/hermes-tools.sock"
tail -n 20 "$HOME/.hermes/run/hermes-tools.sock.log"
```

A live socket with recent log lines means the warm worker is multiplexing
sessions. A missing socket right after a call is normal (worker idle-exited).

## Pass/fail quick reference

| Symptom | Layer | Section |
|---|---|---|
| `*-acp` provider unknown | ACP plugins not installed | SETUP §5b / ACP.md |
| `mcp list` shows failed | MCP launcher/venv | §2, SETUP §4–5 |
| tools listed but never called | model choice | §4 |
| ACP spawn error / CLI missing | `PATH` / `*_ACP_COMMAND` | ACP.md, TROUBLESHOOTING |
| first call slow, rest fast | warm worker cold start | MCP.md |
