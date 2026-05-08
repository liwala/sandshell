#!/usr/bin/env bash
# sandshell: PreToolUse guard for Bash commands
# Blocks obvious sandbox-disabling attempts before execution.
#
# Detection is deliberately narrow: only flag dangerouslyDisableSandbox when it
# appears as a CLI flag (long-form --dangerouslyDisableSandbox, with optional
# value) or as a settings key in JSON-shaped input (e.g. set with jq into a
# settings file). Free-text mentions — commit messages, docstrings, README
# edits — are intentionally NOT blocked: a substring match here false-positives
# on `git commit -m "fix: warn about dangerouslyDisableSandbox"`.
set -euo pipefail

input=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

command_str=$(echo "$input" | jq -r '.tool_input.command // empty')
[[ -z "$command_str" ]] && exit 0

# Match either:
#   --dangerouslyDisableSandbox            (bare flag)
#   --dangerouslyDisableSandbox=...        (flag with value)
#   --dangerouslyDisableSandbox <value>    (flag with separate value)
# Or a JSON-style key reference:
#   "dangerouslyDisableSandbox":           (settings file key — common via jq/cat heredoc)
#   .dangerouslyDisableSandbox             (jq path)
#
# We don't try to detect dangerouslyDisableSandbox=true as a bare env-var
# assignment; agents don't read it as one, and doing so would re-introduce
# false positives in commit messages that contain `=true` after an unrelated
# word ending in dangerouslyDisableSandbox.
if printf '%s' "$command_str" | grep -qE -- '--dangerouslyDisableSandbox(\b|=)'; then
  matched_form="cli-flag"
elif printf '%s' "$command_str" | grep -qE '"dangerouslyDisableSandbox"[[:space:]]*:'; then
  matched_form="settings-key"
elif printf '%s' "$command_str" | grep -qE '(^|[^A-Za-z0-9_])\.dangerouslyDisableSandbox(\b|=)'; then
  matched_form="jq-path"
else
  exit 0
fi

echo "sandshell: blocked Bash command that attempts to weaken sandbox protections (matched: $matched_form)." >&2
echo "Blocked command: $command_str" >&2
exit 2
