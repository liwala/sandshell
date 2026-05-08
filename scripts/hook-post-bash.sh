#!/usr/bin/env bash
# sandshell: PostToolUse hook for Bash commands
# Logs every Bash invocation to the audit trail for complete observability.
# Install via: sandshell/scripts/setup-hooks.sh
set -euo pipefail

AUDIT_DIR="${SANDSHELL_AUDIT_DIR:-$HOME/.sandshell/audit}"

# Read JSON from stdin (consumed once)
input=$(cat)

# Parse fields — jq is required
if ! command -v jq >/dev/null 2>&1; then
  exit 0  # Silently skip if jq not available
fi

session_id=$(echo "$input" | jq -r '.session_id // empty')
command_str=$(echo "$input" | jq -r '.tool_input.command // empty')
# Claude uses tool_response.exitCode (camelCase); Codex's docs don't pin
# the inner key name. Read both so the audit trail records the exit code
# regardless of which agent fired the hook.
exit_code=$(echo "$input" | jq -r '.tool_response.exitCode // .tool_response.exit_code // empty')

# Skip if no session or command
[[ -z "$session_id" || -z "$command_str" ]] && exit 0

# Use first 8 chars of session ID to match sandshell convention
short_session="${session_id:0:8}"

# Skip self-logging for direct audit-trail writes.
if [[ "$command_str" == *"audit-trail.sh"* ]]; then
  exit 0  # Already logged by the scripts themselves
fi

# Classify the command
op="host_bash"
category="unknown"

# Known host command categories
if [[ "$command_str" =~ ^git\ (push|pull|fetch|status|log|diff|add|commit|checkout|branch|merge|rebase) ]]; then
  category="git"
elif [[ "$command_str" =~ ^gh\ (pr|issue|repo|release) ]]; then
  category="github_cli"
elif [[ "$command_str" == *"setup.sh"* ]] || [[ "$command_str" == *"setup-sandbox.sh"* ]] || \
     [[ "$command_str" == *"setup-hooks.sh"* ]] || [[ "$command_str" == *"uninstall.sh"* ]] || \
     [[ "$command_str" == *"detect.sh"* ]] || [[ "$command_str" == *"install-agent.sh"* ]]; then
  category="sandshell"
elif [[ "$command_str" =~ ^(ls|pwd|cat|head|tail|wc|find|grep|which|echo|printf|date|whoami|rg)($|[[:space:]]) ]]; then
  category="read_only"
else
  category="unclassified"
fi

# Truncate command for logging
truncated_cmd=$(echo "$command_str" | head -c 500)

# Log to audit trail
ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
mkdir -p "$AUDIT_DIR"
audit_file="$AUDIT_DIR/${short_session}.jsonl"

# Build JSON safely
json_cmd=$(printf '%s' "$truncated_cmd" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo "\"${truncated_cmd:0:200}\"")

# Render exit_code as JSON: integer if numeric, JSON-quoted string otherwise,
# null if unset. A non-numeric value would otherwise produce invalid JSON via
# string concat (e.g. exit_code=oops → "exit_code":oops).
json_exit_code=$(printf '%s' "${exit_code:-}" | python3 -c '
import sys, json
v = sys.stdin.read()
if v == "":
    print("null")
else:
    try:
        print(int(v))
    except ValueError:
        print(json.dumps(v))
' 2>/dev/null || echo "null")

echo "{\"ts\":\"${ts}\",\"op\":\"${op}\",\"category\":\"${category}\",\"cmd\":${json_cmd},\"exit_code\":${json_exit_code}}" >> "$audit_file"

exit 0
