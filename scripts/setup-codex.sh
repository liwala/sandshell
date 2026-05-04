#!/usr/bin/env bash
# sandshell: write safe defaults to ~/.codex/config.toml.
#
# Codex's macOS sandbox is real MAC — Seatbelt with a fail-closed base policy
# (`(deny default)`). With network_access = false, no `(allow network-outbound)`
# rule is emitted, so curl/wget from the agent's spawned subprocesses fail at
# the kernel level. Codex then surfaces an explicit "allow network access?"
# escalation prompt — meaningful security UX, not a generic per-command ask.
#
# Source: codex-rs/sandboxing/src/seatbelt.rs (lines 30, 308–319),
# seatbelt_base_policy.sbpl line 8 `(deny default)`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/diff-apply.sh
. "$SCRIPT_DIR/lib/diff-apply.sh"

CONFIG_DIR="$HOME/.codex"
CONFIG_FILE="$CONFIG_DIR/config.toml"
FORCE=false
SHOW_ONLY=false

usage() {
  cat <<EOF
Usage: setup-codex.sh [--force] [--show]

Applies sandshell's safety defaults to ~/.codex/config.toml:
  - sandbox_mode = "workspace-write" (cwd-only filesystem)
  - approval_policy = "on-request"
  - sandbox_workspace_write.network_access = false (kernel-level deny)
  - sandbox_workspace_write.writable_roots = []  (added if absent)

Behavior when ~/.codex/config.toml already exists:
  - sandshell-managed file (has 'Managed by sandshell' comment): refreshed
  - non-sandshell file: merged — sandshell keys override; your other keys
    preserved (comments are not preserved by the merge)
  - with --force: unconditionally overwritten with sandshell's defaults

Options:
  --force   Overwrite the existing file instead of merging
  --show    Print the fresh-install config (dry-run)
  -h, --help

Codex's macOS sandbox uses Seatbelt MAC — same primitive Chrome renderer uses.
Network deny is enforced at kernel level for spawned subprocesses.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    --show)  SHOW_ONLY=true; shift ;;
    -h|--help|help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

CONFIG_BODY='# Managed by sandshell — Codex CLI safety defaults.
# Sandshell manages: sandbox_mode, approval_policy, sandbox_workspace_write.network_access.
# All other keys (including [projects.*], [profiles.*], [tui.*], [mcp_servers.*]) are
# preserved on re-apply. Comments are NOT preserved across re-apply — only the
# managed keys round-trip. Re-run `sandshell apply codex` to refresh.

sandbox_mode = "workspace-write"
approval_policy = "on-request"

[sandbox_workspace_write]
network_access = false
writable_roots = []
'

if [[ "$SHOW_ONLY" = true ]]; then
  echo "Config that would be written to $CONFIG_FILE:"
  echo ""
  echo "$CONFIG_BODY"
  exit 0
fi

mkdir -p "$CONFIG_DIR"

# Action: either an idempotent merge (read existing or start empty, apply our
# managed keys, write back, preserving everything else); or --force, which
# wipes the file and writes only sandshell's defaults.
#
# The merge path applies even when the file is sandshell-managed already,
# because the "Managed by sandshell" marker only signals that we've written
# here before — it doesn't mean we own the whole file. Codex itself writes
# settings (e.g., [tui.*]) and users add [projects.*]/[profiles.*] over time;
# all of those need to survive re-apply.
ACTION="merge"
[[ "$FORCE" = true ]] && ACTION="overwrite"

PRE_EXISTED=false
PRE_MANAGED=false
if [[ -f "$CONFIG_FILE" ]]; then
  PRE_EXISTED=true
  grep -q "Managed by sandshell" "$CONFIG_FILE" 2>/dev/null && PRE_MANAGED=true
fi

sandshell_diff_snapshot "$CONFIG_FILE"

case "$ACTION" in
  overwrite)
    echo "$CONFIG_BODY" > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    ;;
  merge)
    # Read existing TOML (or start empty if no file), apply sandshell-managed
    # keys, write back. Preserves everything we don't manage, including
    # [projects.*], [profiles.*], [tui.*], [mcp_servers.*], and any custom
    # top-level keys. Comments cannot round-trip (Python's stdlib has tomllib
    # for reading but no writer; we serialize the parsed dict back manually).
    python3 - "$CONFIG_FILE" <<'PY'
import os, sys, json, re
import tomllib

config_path = sys.argv[1]

if os.path.exists(config_path):
    try:
        with open(config_path, 'rb') as f:
            cfg = tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError) as e:
        print(f"ERROR: cannot parse {config_path}: {e}", file=sys.stderr)
        print(f"       Back it up and re-run with --force to overwrite cleanly.", file=sys.stderr)
        sys.exit(1)
else:
    cfg = {}

# Apply sandshell-managed safety keys. We always override these — the
# point of `apply` is to enforce safe defaults regardless of prior values.
cfg['sandbox_mode'] = 'workspace-write'
cfg['approval_policy'] = 'on-request'
ws = cfg.get('sandbox_workspace_write')
if not isinstance(ws, dict):
    ws = {}
ws['network_access'] = False
if 'writable_roots' not in ws:
    ws['writable_roots'] = []
cfg['sandbox_workspace_write'] = ws

# Minimal TOML serializer for the schema we actually round-trip: top-level
# scalars + arrays, single-level [section]s and one level of nesting like
# [projects."/path"]. Triple nesting bails to --force.
def fmt_value(v):
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, str):
        return json.dumps(v)
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, list):
        return '[' + ', '.join(fmt_value(x) for x in v) + ']'
    raise ValueError(f"unsupported value type {type(v).__name__}: {v!r}")

def fmt_key(k):
    if re.match(r'^[A-Za-z0-9_-]+$', k):
        return k
    return json.dumps(k)

def bail(msg):
    print(f"ERROR: setup-codex cannot merge: {msg}", file=sys.stderr)
    print(f"       Back up {config_path} and re-run with --force to overwrite.", file=sys.stderr)
    sys.exit(1)

lines = [
    '# Managed by sandshell — Codex CLI safety defaults.',
    '# Sandshell manages: sandbox_mode, approval_policy, sandbox_workspace_write.network_access.',
    '# All other keys (including [projects.*], [profiles.*], [tui.*], [mcp_servers.*]) are',
    '# preserved on re-apply. Comments are NOT preserved across re-apply — only the',
    '# managed keys round-trip. Re-run `sandshell apply codex` to refresh.',
    '',
]

# Top-level scalars (must come before any [section] in TOML).
for k, v in cfg.items():
    if isinstance(v, dict):
        continue
    try:
        lines.append(f"{fmt_key(k)} = {fmt_value(v)}")
    except ValueError as e:
        bail(f"top-level key {k!r}: {e}")

# Top-level tables.
for k, v in cfg.items():
    if not isinstance(v, dict):
        continue
    flat = {kk: vv for kk, vv in v.items() if not isinstance(vv, dict)}
    nested = {kk: vv for kk, vv in v.items() if isinstance(vv, dict)}

    if flat:
        lines.append('')
        lines.append(f"[{fmt_key(k)}]")
        for kk, vv in flat.items():
            try:
                lines.append(f"{fmt_key(kk)} = {fmt_value(vv)}")
            except ValueError as e:
                bail(f"in [{k}], key {kk!r}: {e}")

    for kk, vv in nested.items():
        # Sub-table like [projects."/path"]; serialize one level deep only.
        for kkk, vvv in vv.items():
            if isinstance(vvv, dict):
                bail(f"triple-nested table [{k}.{kk}.{kkk}] is not supported")
        lines.append('')
        lines.append(f"[{fmt_key(k)}.{fmt_key(kk)}]")
        for kkk, vvv in vv.items():
            try:
                lines.append(f"{fmt_key(kkk)} = {fmt_value(vvv)}")
            except ValueError as e:
                bail(f"in [{k}.{kk}], key {kkk!r}: {e}")

with open(config_path, 'w') as f:
    f.write('\n'.join(lines) + '\n')
PY
    if [[ $? -ne 0 ]]; then
      exit 1
    fi
    chmod 600 "$CONFIG_FILE"
    ;;
esac

if [[ "$ACTION" = "overwrite" ]]; then
  summary="Overwrote $CONFIG_FILE with sandshell's safe defaults (--force)"
elif [[ "$PRE_EXISTED" = false ]]; then
  summary="Codex safe defaults written to $CONFIG_FILE"
elif [[ "$PRE_MANAGED" = true ]]; then
  summary="Refreshed sandshell-managed keys in $CONFIG_FILE (other keys preserved)"
else
  summary="Merged safety defaults into existing $CONFIG_FILE (user keys preserved)"
fi

echo "sandshell: $summary"
echo ""
sandshell_diff_show "$CONFIG_FILE"
echo ""

cat <<EOF

What this enforces:
  - Filesystem writes: restricted to current working directory
  - Outbound network: DENIED at kernel level (Seatbelt MAC on macOS,
    bubblewrap+seccomp+Landlock on Linux). Codex's sandbox is the strongest
    of the major coding agents on macOS for network isolation.
  - Approvals: 'on-request' (prompts before risky operations)
  - Auto-mode escape hatch: agent can ask 'allow network access?' per call

VERIFY enforcement — in any new Codex session, run:
  curl https://example.com

Expected: Codex shows 'Could not resolve host' (Seatbelt blocking DNS), then
prompts 'Do you want to allow network access so I can run curl ...?'.

If curl succeeds without that prompt, the sandbox is not enforcing. Check
codex --version, look for overriding [profiles.*] sections in $CONFIG_FILE,
or report an upstream issue.

To remove sandshell's config: edit $CONFIG_FILE or delete the file.
EOF

# Refresh the drift baseline so the next 'sandshell audit' compares against
# this post-apply state.
"$SCRIPT_DIR/audit-config.sh" --snapshot --no-drift --json >/dev/null 2>&1 || true
