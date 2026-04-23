#!/usr/bin/env bash
# sandshell: PreToolUse guard for Bash commands
# Blocks obvious sandbox-disabling attempts before execution.
set -euo pipefail

input=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

command_str=$(echo "$input" | jq -r '.tool_input.command // empty')
[[ -z "$command_str" ]] && exit 0

if [[ "$command_str" != *"dangerouslyDisableSandbox"* ]]; then
  exit 0
fi

echo "sandshell: blocked Bash command that attempts to weaken sandbox protections." >&2
echo "Blocked command: $command_str" >&2
exit 2
