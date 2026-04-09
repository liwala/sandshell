#!/usr/bin/env bash
# sandshell: PostToolUse hook for Bash commands
# Logs every Bash invocation to the audit trail for complete observability.
# Install via: sandshell/scripts/setup-hooks.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUDIT_DIR="${SANDSHELL_AUDIT_DIR:-$HOME/.sandshell/audit}"

# Read JSON from stdin (consumed once)
input=$(cat)

# Parse fields — jq is required
if ! command -v jq >/dev/null 2>&1; then
  exit 0  # Silently skip if jq not available
fi

session_id=$(echo "$input" | jq -r '.session_id // empty')
command_str=$(echo "$input" | jq -r '.tool_input.command // empty')
exit_code=$(echo "$input" | jq -r '.tool_response.exitCode // empty')

# Skip if no session or command
[[ -z "$session_id" || -z "$command_str" ]] && exit 0

# Use first 8 chars of session ID to match sandshell convention
short_session="${session_id:0:8}"

# Check if this command went through sandbox.sh (already logged) or was a direct host command
if [[ "$command_str" == *"sandbox.sh"* ]] || [[ "$command_str" == *"harden.sh"* ]] || [[ "$command_str" == *"audit.sh"* ]]; then
  exit 0  # Already logged by the scripts themselves
fi

# Classify the command
op="host_bash"
category="unknown"

# Known safe host commands
if [[ "$command_str" =~ ^git\ (push|pull|fetch|status|log|diff|add|commit|checkout|branch|merge|rebase) ]]; then
  category="git"
elif [[ "$command_str" =~ ^gh\ (pr|issue|repo|release) ]]; then
  category="github_cli"
elif [[ "$command_str" =~ ^(docker|podman|limactl)\ ]]; then
  category="container_mgmt"
elif [[ "$command_str" =~ ^(ls|pwd|cat|head|tail|wc|find|grep|which|echo|printf|date|whoami) ]]; then
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

echo "{\"ts\":\"${ts}\",\"op\":\"${op}\",\"category\":\"${category}\",\"cmd\":${json_cmd},\"exit_code\":${exit_code:-null}}" >> "$audit_file"

exit 0
