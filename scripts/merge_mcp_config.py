#!/usr/bin/env python3
"""Merge a `hermes-tools` local MCP server into an opencode/kilo JSONC config.

opencode and kilocode have no non-interactive `mcp add` for local stdio servers,
so the installer uses this helper. It is intentionally conservative:

  * parses JSONC (// and /* */ comments, trailing commas),
  * preserves every existing key (only adds/replaces `mcp.hermes-tools`),
  * backs the original up to `<file>.bak.<UTC timestamp>` before writing,
  * refuses to write if the result would drop the file's other top-level keys.

Comments in the file are not preserved on rewrite (JSONC comments are not part
of the data model). All keys and values are.

Usage:
  merge_mcp_config.py --file PATH --client opencode|kilo \
      --launcher ABS_PATH --cwd ABS_PATH [--dry-run] [--no-backup]

Exit codes: 0 ok, 2 bad input/config, 3 write refused.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

SCHEMAS = {
    "opencode": "https://opencode.ai/config.json",
    "kilo": "https://app.kilo.ai/config.json",
}


def strip_jsonc(text: str) -> str:
    """Remove // and /* */ comments and trailing commas, respecting strings."""
    out: list[str] = []
    i, n = 0, len(text)
    in_str = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            i += 2
            while i < n and text[i] not in "\r\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            end = text.find("*/", i + 2)
            i = n if end == -1 else end + 2
            continue
        out.append(c)
        i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))


def load_jsonc(path: Path) -> dict:
    if not path.exists() or not path.read_text(encoding="utf-8").strip():
        return {}
    raw = path.read_text(encoding="utf-8")
    try:
        data = json.loads(strip_jsonc(raw))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"error: {path} is not valid JSONC: {exc}") from exc
    if not isinstance(data, dict):
        raise SystemExit(f"error: {path} top level is not an object")
    return data


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", required=True)
    ap.add_argument("--client", required=True, choices=sorted(SCHEMAS))
    ap.add_argument("--launcher", required=True)
    ap.add_argument("--cwd", required=True)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-backup", action="store_true")
    a = ap.parse_args()

    path = Path(a.file).expanduser()
    launcher, cwd = str(Path(a.launcher).expanduser()), str(Path(a.cwd).expanduser())
    if not Path(launcher).is_file():
        raise SystemExit(f"error: launcher not found: {launcher}")
    if not Path(cwd).is_dir():
        raise SystemExit(f"error: cwd not found: {cwd}")

    data = load_jsonc(path)
    before_keys = set(data)
    data.setdefault("$schema", SCHEMAS[a.client])
    mcp = data.get("mcp")
    if not isinstance(mcp, dict):
        mcp = {}
    mcp["hermes-tools"] = {
        "type": "local",
        "command": [launcher],
        "cwd": cwd,
        "enabled": True,
    }
    data["mcp"] = mcp

    if not before_keys.issubset(set(data)):
        raise SystemExit("error: refusing to write — merge would drop keys")

    rendered = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    if a.dry_run:
        print(rendered)
        return 0

    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and not a.no_backup:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        backup = path.with_name(f"{path.name}.bak.{stamp}")
        backup.write_text(path.read_text(encoding="utf-8"), encoding="utf-8")
        print(f"backup: {backup}")
    path.write_text(rendered, encoding="utf-8")
    print(f"wrote:  {path}  (mcp.hermes-tools -> {launcher})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
