#!/usr/bin/env bash
# Install the hermes-opencode-bridge pieces into an existing Hermes checkout.
#
# Idempotent. Does NOT edit your opencode/kilo/hermes config files — it installs
# files and prints the exact config blocks you still need to merge.
#
# Usage:
#   ./scripts/install-bridge.sh [--with-rust]
#
# Env:
#   HERMES_AGENT_DIR   Hermes checkout (default: $HOME/.hermes/hermes-agent)
#   HERMES_HOME        Hermes home      (default: $HOME/.hermes)
#   SKIP_MCP=1         skip `pip install mcp>=2`
#   SKIP_RUST=1        skip the Rust build even with --with-rust
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERMES_AGENT_DIR="${HERMES_AGENT_DIR:-$HOME/.hermes/hermes-agent}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
VENV_BIN="$HERMES_AGENT_DIR/venv/bin"
PY="$VENV_BIN/python"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

[ -d "$HERMES_AGENT_DIR" ] || die "Hermes checkout not found: $HERMES_AGENT_DIR (set HERMES_AGENT_DIR)"
[ -x "$PY" ] || die "Hermes venv python not found: $PY"

say "Hermes checkout: $HERMES_AGENT_DIR"

# 1. mcp python package ------------------------------------------------------
if [ "${SKIP_MCP:-0}" != "1" ]; then
  say "Installing the 'mcp' package into the Hermes venv"
  "$VENV_BIN/pip" install -q "mcp>=2"
fi
"$PY" -c 'import mcp' 2>/dev/null || die "'mcp' not importable by $PY — rerun without SKIP_MCP=1"

# 2. launcher ----------------------------------------------------------------
say "Installing launcher -> $VENV_BIN/hermes-tools-mcp-launch"
install -m 0755 "$ROOT/scripts/hermes-tools-mcp-launch" \
  "$VENV_BIN/hermes-tools-mcp-launch"

# 3. ACP provider plugins ----------------------------------------------------
say "Installing ACP provider plugins -> $HERMES_HOME/plugins/model-providers/"
mkdir -p "$HERMES_HOME/plugins/model-providers"
for p in opencode-acp kilocode-acp; do
  rm -rf "$HERMES_HOME/plugins/model-providers/$p"
  cp -r "$ROOT/providers/$p" "$HERMES_HOME/plugins/model-providers/$p"
  find "$HERMES_HOME/plugins/model-providers/$p" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true
  echo "   - $p"
done

# 4. Rust transport (optional) ----------------------------------------------
if [ "${1:-}" = "--with-rust" ] && [ "${SKIP_RUST:-0}" != "1" ]; then
  if command -v cargo >/dev/null 2>&1; then
    say "Building the Rust MCP transport (this can take a minute)"
    ( cd "$ROOT/rust" && cargo build --release )
    install -m 0755 "$ROOT/rust/target/release/hermes-tools-mcp" \
      "$VENV_BIN/hermes-tools-mcp"
    say "Rust transport installed -> $VENV_BIN/hermes-tools-mcp"
  else
    warn "cargo not found — skipping Rust; the Python fallback will be used"
  fi
fi

# 5. Prove the launcher answers a stdio handshake ---------------------------
say "Smoke-testing the launcher (JSON-RPC initialize)"
out="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  | "$VENV_BIN/hermes-tools-mcp-launch" 2>/dev/null | head -c 400 || true)"
case "$out" in
  *'"result"'*) echo "   ok: launcher responded" ;;
  *) warn "launcher did not return an initialize result; run it by hand to see the error"; echo "   got: ${out:-<empty>}" ;;
esac

cat <<EOF

$(printf '\033[1;32mInstalled.\033[0m') Remaining manual steps (edit configs — this script does not):

  1) opencode  -> ~/.config/opencode/opencode.jsonc   merge config/opencode.mcp.jsonc
     kilocode  -> ~/.config/kilo/kilo.jsonc           merge config/kilo.mcp.jsonc
     (replace the \$HERMES_AGENT_DIR placeholder with: $HERMES_AGENT_DIR)

  2) Hermes    -> $HERMES_HOME/config.yaml            point model.provider at
     opencode-acp / kilocode-acp (see config/config.yaml.acp-mcp)

  3) Authenticate the CLIs once:  opencode auth login  &&  kilo auth login

  4) Verify:  $ROOT/scripts/verify.sh
EOF
