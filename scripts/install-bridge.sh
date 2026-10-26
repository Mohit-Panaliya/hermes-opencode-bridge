#!/usr/bin/env bash
# Install AND wire the hermes-opencode-bridge into an existing Hermes checkout.
#
# One command on a fresh machine (after Hermes + opencode/kilo are installed):
#
#   ./scripts/install-bridge.sh --with-rust
#
# It installs the Python dependency, the launcher and the ACP provider plugins,
# optionally builds the Rust transport, then merges the `hermes-tools` MCP server
# into the opencode and kilocode configs and points Hermes' model at an ACP
# backend. Every file it edits is backed up first. Idempotent.
#
# Usage:
#   ./scripts/install-bridge.sh [options]
#
# Options:
#   --with-rust            build the Rust transport if cargo is available
#   --provider <name>      ACP backend for Hermes: opencode | kilocode | none
#                          (default: opencode; `none` leaves config.yaml alone)
#   --model <id>           default model id (default depends on --provider)
#   --no-config            install files only; do not touch any config
#   --dry-run              show config changes without writing
#   --no-backup            do not keep .bak files when editing configs
#   -h, --help
#
# Env:
#   HERMES_AGENT_DIR   Hermes checkout (default: $HOME/.hermes/hermes-agent)
#   HERMES_HOME        Hermes home      (default: $HOME/.hermes)
#   XDG_CONFIG_HOME    client config root (default: $HOME/.config)
#   SKIP_MCP=1         skip `pip install mcp>=2`
#   SKIP_RUST=1        skip the Rust build even with --with-rust
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERMES_AGENT_DIR="${HERMES_AGENT_DIR:-$HOME/.hermes/hermes-agent}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
VENV_BIN="$HERMES_AGENT_DIR/venv/bin"
PY="$VENV_BIN/python"
LAUNCH="$VENV_BIN/hermes-tools-mcp-launch"

WITH_RUST=0
PROVIDER="opencode"
MODEL=""
NO_CONFIG=0
DRY_RUN=0
NO_BACKUP=0

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY_RUN" = "1" ]; then printf '   [dry-run] %s\n' "$*"; else "$@"; fi; }

while [ $# -gt 0 ]; do
  case "$1" in
    --with-rust) WITH_RUST=1 ;;
    --provider)  PROVIDER="${2:-}"; shift ;;
    --model)     MODEL="${2:-}"; shift ;;
    --no-config) NO_CONFIG=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    --no-backup) NO_BACKUP=1 ;;
    -h|--help)   sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

case "$PROVIDER" in
  opencode) PROVIDER="opencode-acp"; BASE_URL="acp://opencode"; MODEL="${MODEL:-opencode/mimo-v2.5-free}" ;;
  kilocode|kilo) PROVIDER="kilocode-acp"; BASE_URL="acp://kilocode"; MODEL="${MODEL:-kilo/kilo-auto/free}" ;;
  none|"") PROVIDER="none" ;;
  *) die "--provider must be opencode|kilocode|none (got: $PROVIDER)" ;;
esac

echo
say "hermes-opencode-bridge installer"
echo "   ROOT             = $ROOT"
echo "   HERMES_AGENT_DIR = $HERMES_AGENT_DIR"
echo "   HERMES_HOME      = $HERMES_HOME"
echo "   provider         = ${PROVIDER}${BASE_URL:+ ($BASE_URL)}"
echo

[ -d "$HERMES_AGENT_DIR" ] || die "Hermes checkout not found: $HERMES_AGENT_DIR (set HERMES_AGENT_DIR)"
[ -x "$PY" ] || die "Hermes venv python not found: $PY"
for c in opencode kilo; do
  command -v "$c" >/dev/null 2>&1 || warn "$c not on PATH — its config will still be written; install it before use"
done

# 1. mcp python package ------------------------------------------------------
if [ "${SKIP_MCP:-0}" != "1" ]; then
  say "Installing the 'mcp' package into the Hermes venv"
  run "$VENV_BIN/pip" install -q "mcp>=2"
fi
"$PY" -c 'import mcp' 2>/dev/null || die "'mcp' not importable by $PY — rerun without SKIP_MCP=1"

# 2. launcher ----------------------------------------------------------------
say "Installing launcher -> $LAUNCH"
run install -m 0755 "$ROOT/scripts/hermes-tools-mcp-launch" "$LAUNCH"

# 3. ACP provider plugins ----------------------------------------------------
say "Installing ACP provider plugins -> $HERMES_HOME/plugins/model-providers/"
if [ "$DRY_RUN" != "1" ]; then
  mkdir -p "$HERMES_HOME/plugins/model-providers"
fi
for p in opencode-acp kilocode-acp; do
  run rm -rf "$HERMES_HOME/plugins/model-providers/$p"
  run cp -r "$ROOT/providers/$p" "$HERMES_HOME/plugins/model-providers/$p"
  if [ "$DRY_RUN" != "1" ]; then
    find "$HERMES_HOME/plugins/model-providers/$p" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true
  fi
  echo "   - $p"
done

# 4. Rust transport (optional) ----------------------------------------------
if [ "$WITH_RUST" = "1" ] && [ "${SKIP_RUST:-0}" != "1" ]; then
  if command -v cargo >/dev/null 2>&1; then
    say "Building the Rust MCP transport (this can take a minute)"
    run bash -c "cd '$ROOT/rust' && cargo build --release"
    run install -m 0755 "$ROOT/rust/target/release/hermes-tools-mcp" \
      "$VENV_BIN/hermes-tools-mcp"
    say "Rust transport installed -> $VENV_BIN/hermes-tools-mcp"
  else
    warn "cargo not found — skipping Rust; the Python fallback will be used"
  fi
fi

# 5. wire the two MCP clients ------------------------------------------------
if [ "$NO_CONFIG" = "1" ]; then
  warn "--no-config: skipping opencode/kilo/hermes config edits"
else
  say "Registering hermes-tools MCP server in opencode + kilocode configs"
  merge_args=(--launcher "$LAUNCH" --cwd "$HERMES_AGENT_DIR")
  [ "$DRY_RUN" = "1" ] && merge_args+=(--dry-run)
  [ "$NO_BACKUP" = "1" ] && merge_args+=(--no-backup)
  run "$PY" "$ROOT/scripts/merge_mcp_config.py" \
    --file "$XDG_CONFIG_HOME/opencode/opencode.jsonc" --client opencode "${merge_args[@]}"
  run "$PY" "$ROOT/scripts/merge_mcp_config.py" \
    --file "$XDG_CONFIG_HOME/kilo/kilo.jsonc" --client kilo "${merge_args[@]}"

  # 6. wire Hermes model routing (ACP out) -----------------------------------
  if [ "$PROVIDER" = "none" ]; then
    warn "--provider none: leaving Hermes model config unchanged (MCP-only setup)"
  else
    say "Pointing Hermes' model at $PROVIDER ($MODEL)"
    run "$VENV_BIN/hermes" config set model.provider "$PROVIDER"
    run "$VENV_BIN/hermes" config set model.base_url "$BASE_URL"
    run "$VENV_BIN/hermes" config set model.default "$MODEL"
  fi
fi

# 7. Prove the launcher answers a stdio handshake ---------------------------
if [ "$DRY_RUN" != "1" ]; then
  say "Smoke-testing the launcher (JSON-RPC initialize)"
  out="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    | "$LAUNCH" 2>/dev/null | head -c 400 || true)"
  case "$out" in
    *'"result"'*) echo "   ok: launcher responded" ;;
    *) warn "launcher did not return an initialize result; run it by hand to see the error"; echo "   got: ${out:-<empty>}" ;;
  esac
fi

cat <<EOF

$(printf '\033[1;32mInstalled and wired.\033[0m')

  Next (manual, one time): authenticate the CLI(s) you will route to —
      opencode auth login     # if using provider: opencode-acp
      kilo auth login         # if using provider: kilocode-acp

  Verify everything:
      $ROOT/scripts/verify.sh

  Revert config edits: restore the \`*.bak.<timestamp>\` files next to each config.
EOF
