#!/usr/bin/env bash
# sandshell: audit trail for all sandbox operations
set -euo pipefail

AUDIT_DIR="${SANDSHELL_AUDIT_DIR:-$HOME/.sandshell/audit}"
MAX_SESSIONS="${SANDSHELL_MAX_SESSIONS:-50}"

ensure_dir() {
  mkdir -p "$AUDIT_DIR"
}

cmd_init() {
  local session_id="$1"
  ensure_dir
  local file="$AUDIT_DIR/${session_id}.jsonl"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  echo "{\"ts\":\"${ts}\",\"op\":\"session_start\",\"session\":\"${session_id}\",\"cwd\":\"$(pwd)\",\"user\":\"$(whoami)\"}" > "$file"

  # Prune old sessions
  local count
  count=$(ls -1 "$AUDIT_DIR"/*.jsonl 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$count" -gt "$MAX_SESSIONS" ]]; then
    ls -1t "$AUDIT_DIR"/*.jsonl | tail -n +"$((MAX_SESSIONS + 1))" | xargs rm -f
  fi
}

cmd_log() {
  local session_id="$1"
  local json_data="$2"
  ensure_dir
  local file="$AUDIT_DIR/${session_id}.jsonl"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Inject timestamp into the JSON
  echo "{\"ts\":\"${ts}\",${json_data#\{}" >> "$file"
}

cmd_show() {
  local session_id="$1"
  local file="$AUDIT_DIR/${session_id}.jsonl"

  if [[ ! -f "$file" ]]; then
    echo "No audit trail found for session '$session_id'" >&2
    exit 1
  fi

  echo "=== Audit Trail: ${session_id} ==="
  echo ""

  while IFS= read -r line; do
    local ts op cmd exit_code
    ts=$(echo "$line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('ts',''))" 2>/dev/null || echo "?")
    op=$(echo "$line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('op',''))" 2>/dev/null || echo "?")
    cmd=$(echo "$line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('cmd',''))" 2>/dev/null || echo "")
    exit_code=$(echo "$line" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('exit_code',''))" 2>/dev/null || echo "")

    local status_icon="  "
    if [[ "$exit_code" = "0" ]]; then
      status_icon="ok"
    elif [[ -n "$exit_code" && "$exit_code" != "0" ]]; then
      status_icon="!!"
    fi

    printf "[%s] %-15s %s %s\n" "$ts" "$op" "$status_icon" "$cmd"
  done < "$file"
}

cmd_summary() {
  local session_id="$1"
  local file="$AUDIT_DIR/${session_id}.jsonl"

  if [[ ! -f "$file" ]]; then
    echo "No audit trail found for session '$session_id'" >&2
    exit 1
  fi

  python3 -c "
import json, sys

entries = [json.loads(l) for l in open('$file') if l.strip()]
total = len(entries)
ops = {}
host_cmds = 0
sandbox_cmds = 0
failures = 0
host_categories = {}
unclassified = []

for e in entries:
    op = e.get('op', 'unknown')
    ops[op] = ops.get(op, 0) + 1
    if op in ('host_cmd', 'host_bash'):
        host_cmds += 1
        cat = e.get('category', 'unknown')
        host_categories[cat] = host_categories.get(cat, 0) + 1
        if cat == 'unclassified':
            unclassified.append(e.get('cmd', '?')[:80])
    elif op == 'exec':
        sandbox_cmds += 1
    if e.get('exit_code', 0) != 0 and 'exit_code' in e:
        failures += 1

print(f'Session: $session_id')
print(f'Total operations: {total}')
print(f'Sandbox commands: {sandbox_cmds}')
print(f'Host commands: {host_cmds}')
if host_categories:
    print(f'Host breakdown: {host_categories}')
print(f'Failures: {failures}')
print(f'Operations: {ops}')

if host_cmds + sandbox_cmds > 0:
    ratio = sandbox_cmds / (host_cmds + sandbox_cmds) * 100
    print(f'Sandbox ratio: {ratio:.0f}%')

if unclassified:
    print(f'')
    print(f'Unclassified host commands ({len(unclassified)}):')
    for cmd in unclassified[:10]:
        print(f'  - {cmd}')
"
}

# ─── Dispatch ────────────────────────────────────────────────────────

case "${1:-help}" in
  init)    shift; cmd_init "$@" ;;
  log)     shift; cmd_log "$@" ;;
  show)    shift; cmd_show "$@" ;;
  summary) shift; cmd_summary "$@" ;;
  *)
    echo "Usage: audit-trail.sh <init|log|show|summary> <session-id> [data]"
    exit 1
    ;;
esac
