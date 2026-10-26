#!/usr/bin/env bash
# End-to-end checks for the hermes-opencode-bridge.
#
# Read-only: inspects installed files, configs and runs a stdio handshake. It
# never modifies anything. Exit code 0 = all required checks passed.
#
# Usage: ./scripts/verify.sh
set -uo pipefail

HERMES_AGENT_DIR="${HERMES_AGENT_DIR:-$HOME/.hermes/hermes-agent}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
VENV_BIN="$HERMES_AGENT_DIR/venv/bin"
PY="$VENV_BIN/python"
LAUNCH="$VENV_BIN/hermes-tools-mcp-launch"
RUST_BIN="$VENV_BIN/hermes-tools-mcp"
SOCK="${HERMES_TOOLS_SOCKET:-${HERMES_RUN_DIR:-$HERMES_HOME/run}/hermes-tools.sock}"

pass=0; fail=0
ok()   { printf '\033[1;32m PASS\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '\033[1;31m FAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
skip() { printf '\033[1;33m SKIP\033[0m %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

head_ "1. Hermes checkout + venv"
[ -d "$HERMES_AGENT_DIR" ] && ok "checkout: $HERMES_AGENT_DIR" || bad "checkout missing: $HERMES_AGENT_DIR"
[ -x "$PY" ] && ok "venv python: $($PY --version 2>&1)" || bad "venv python missing: $PY"

head_ "2. mcp package (importable by the venv python)"
if "$PY" -c 'import mcp' 2>/dev/null; then
  ok "mcp importable ($("$PY" -c 'import importlib.metadata as m; print(m.version("mcp"))' 2>/dev/null || echo '?'))"
else
  bad "mcp NOT importable — run: $VENV_BIN/pip install 'mcp>=2'"
fi

head_ "3. launcher"
[ -x "$LAUNCH" ] && ok "launcher present: $LAUNCH" || bad "launcher missing: $LAUNCH"

head_ "4. ACP provider plugins"
for p in opencode-acp kilocode-acp; do
  if [ -f "$HERMES_HOME/plugins/model-providers/$p/__init__.py" ]; then
    ok "provider plugin: $p"
  else
    bad "provider plugin missing: $HERMES_HOME/plugins/model-providers/$p"
  fi
done

head_ "5. Rust transport (optional)"
if [ -x "$RUST_BIN" ]; then
  if "$RUST_BIN" --check --socket "$SOCK" \
       --worker-python "$PY" --worker-module agent.transports.hermes_tools_worker \
       --cwd "$HERMES_AGENT_DIR" >/dev/null 2>&1; then
    ok "rust transport healthy (--check 0)"
  else
    bad "rust binary present but --check failed (launcher will fall back to Python)"
  fi
else
  skip "no rust binary — Python fallback will be used"
fi

head_ "6. launcher stdio handshake"
if [ -x "$LAUNCH" ]; then
  out="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
        | "$LAUNCH" 2>/dev/null | head -c 800 || true)"
  case "$out" in
    *'"result"'*) ok "initialize answered" ;;
    *) bad "no initialize result (see: printf ... | $LAUNCH)" ;;
  esac
else
  bad "cannot test launcher (missing)"
fi

head_ "7. client registration"
check_client() {
  local name="$1" cfg="$2" bin="$3"
  if [ ! -f "$cfg" ]; then bad "$name config not found: $cfg"; return; fi
  if grep -q '"hermes-tools"' "$cfg" 2>/dev/null; then
    ok "$name config registers hermes-tools ($cfg)"
  else
    bad "$name config has no hermes-tools block ($cfg)"
  fi
  if command -v "$bin" >/dev/null 2>&1; then
    echo "       $bin mcp list:"
    "$bin" mcp list 2>&1 | sed 's/^/         /' | head -6
  else
    skip "$bin not on PATH"
  fi
}
check_client "opencode" "$HOME/.config/opencode/opencode.jsonc" opencode
check_client "kilocode" "$HOME/.config/kilo/kilo.jsonc" kilo

head_ "8. Hermes ACP routing (config.yaml)"
CFG="$HERMES_HOME/config.yaml"
if [ -f "$CFG" ]; then
  if grep -qE 'provider:[[:space:]]*(opencode|kilocode)-acp' "$CFG"; then
    ok "config.yaml selects an ACP provider"
    grep -nE 'provider:[[:space:]]*(opencode|kilocode)-acp|base_url:[[:space:]]*acp://' "$CFG" \
      | sed 's/^/       /' | head -6
  else
    skip "config.yaml does not select *-acp (still valid if you only want MCP)"
  fi
else
  bad "config.yaml not found: $CFG"
fi

printf '\n\033[1mResult:\033[0m %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
