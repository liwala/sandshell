#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/testlib.sh"

TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/sandshell-test-hook-pre.XXXXXX")"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

mkdir -p "$TMPDIR_TEST/bin"
export PATH="$TMPDIR_TEST/bin:$PATH"

cat > "$TMPDIR_TEST/bin/jq" << 'EOF'
#!/usr/bin/env python3
import json
import sys

args = sys.argv[1:]
raw = False
if args and args[0] == "-r":
    raw = True
    args = args[1:]

expr = args[0]
payload = json.load(sys.stdin)

if expr == ".tool_input.command // empty":
    value = payload.get("tool_input", {}).get("command", "")
else:
    raise SystemExit(1)

if raw:
    sys.stdout.write(value)
else:
    print(json.dumps(value))
EOF
chmod +x "$TMPDIR_TEST/bin/jq"

allowed_payload='{"tool_input":{"command":"npm test"}}'
blocked_payload='{"tool_input":{"command":"claude --dangerouslyDisableSandbox"}}'

printf '%s' "$allowed_payload" | "$ROOT/scripts/hook-pre-bash.sh" > /dev/null

set +e
blocked_output=$(printf '%s' "$blocked_payload" | "$ROOT/scripts/hook-pre-bash.sh" 2>&1)
blocked_status=$?
set -e

[[ "$blocked_status" -eq 2 ]] || fail "Expected blocked command to exit 2, got $blocked_status"
[[ "$blocked_output" == *"attempts to weaken sandbox protections"* ]] || fail "Unexpected block output: $blocked_output"

# A commit message that mentions dangerouslyDisableSandbox in free text must
# NOT be blocked. The previous substring match would fire here (regression).
commit_msg_payload='{"tool_input":{"command":"git commit -m \"warn about dangerouslyDisableSandbox abuse\""}}'
set +e
printf '%s' "$commit_msg_payload" | "$ROOT/scripts/hook-pre-bash.sh" > /dev/null 2>&1
commit_msg_status=$?
set -e
[[ "$commit_msg_status" -eq 0 ]] \
  || fail "Free-text mention in commit message should not be blocked, got exit $commit_msg_status"

# A flag with =true value should still be blocked.
flag_value_payload='{"tool_input":{"command":"claude --dangerouslyDisableSandbox=true"}}'
set +e
printf '%s' "$flag_value_payload" | "$ROOT/scripts/hook-pre-bash.sh" > /dev/null 2>&1
flag_value_status=$?
set -e
[[ "$flag_value_status" -eq 2 ]] \
  || fail "Flag with =true should be blocked, got exit $flag_value_status"

# A JSON settings-key write should be blocked.
settings_payload='{"tool_input":{"command":"echo '\''{\"dangerouslyDisableSandbox\": true}'\'' > settings.json"}}'
set +e
printf '%s' "$settings_payload" | "$ROOT/scripts/hook-pre-bash.sh" > /dev/null 2>&1
settings_status=$?
set -e
[[ "$settings_status" -eq 2 ]] \
  || fail "Settings-key form should be blocked, got exit $settings_status"

echo "PASS: hook-pre-bash guard behavior (CLI flag block, commit-message false-positive avoided)"
