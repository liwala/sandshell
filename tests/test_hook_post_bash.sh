#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/testlib.sh"

TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/sandshell-test-hook-post.XXXXXX")"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

mkdir -p "$TMPDIR_TEST/bin" "$TMPDIR_TEST/home"
export PATH="$TMPDIR_TEST/bin:$PATH"
export HOME="$TMPDIR_TEST/home"
export SANDSHELL_AUDIT_DIR="$TMPDIR_TEST/audit"

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

tr = payload.get("tool_response", {}) or {}
exit_code = tr.get("exitCode", tr.get("exit_code", ""))
mapping = {
    ".session_id // empty": payload.get("session_id", ""),
    ".tool_input.command // empty": payload.get("tool_input", {}).get("command", ""),
    ".tool_response.exitCode // empty": payload.get("tool_response", {}).get("exitCode", ""),
    ".tool_response.exitCode // .tool_response.exit_code // empty": exit_code,
}

if expr not in mapping:
    raise SystemExit(1)

value = mapping[expr]
if raw:
    sys.stdout.write(str(value))
else:
    print(json.dumps(value))
EOF
chmod +x "$TMPDIR_TEST/bin/jq"

# Case 1: Claude-style payload with camelCase exitCode.
payload='{"session_id":"1234567890abcdef","tool_input":{"command":"git status"},"tool_response":{"exitCode":0}}'
printf '%s' "$payload" | "$ROOT/scripts/hook-post-bash.sh" > /dev/null

AUDIT_FILE="$SANDSHELL_AUDIT_DIR/12345678.jsonl"
assert_file_contains "$AUDIT_FILE" "\"op\":\"host_bash\""
assert_file_contains "$AUDIT_FILE" "\"category\":\"git\""
assert_file_contains "$AUDIT_FILE" "\"cmd\":\"git status\""
assert_file_contains "$AUDIT_FILE" "\"exit_code\":0"

# Case 2: Codex-style payload with snake_case exit_code — same hook script
# should record the exit code regardless of which key the agent uses.
payload2='{"session_id":"codexsess1234ab","tool_input":{"command":"npm test"},"tool_response":{"exit_code":1}}'
printf '%s' "$payload2" | "$ROOT/scripts/hook-post-bash.sh" > /dev/null
AUDIT_FILE2="$SANDSHELL_AUDIT_DIR/codexses.jsonl"
assert_file_contains "$AUDIT_FILE2" "\"cmd\":\"npm test\""
assert_file_contains "$AUDIT_FILE2" "\"exit_code\":1"

echo "PASS: hook-post-bash logging (Claude exitCode + Codex exit_code)"
