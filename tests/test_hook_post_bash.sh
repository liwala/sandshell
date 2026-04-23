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

cat > "$TMPDIR_TEST/bin/jq" <<'EOF'
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

mapping = {
    ".session_id // empty": payload.get("session_id", ""),
    ".tool_input.command // empty": payload.get("tool_input", {}).get("command", ""),
    ".tool_response.exitCode // empty": payload.get("tool_response", {}).get("exitCode", ""),
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

payload='{"session_id":"1234567890abcdef","tool_input":{"command":"git status"},"tool_response":{"exitCode":0}}'
printf '%s' "$payload" | "$ROOT/scripts/hook-post-bash.sh" >/dev/null

AUDIT_FILE="$SANDSHELL_AUDIT_DIR/12345678.jsonl"
assert_file_contains "$AUDIT_FILE" "\"op\":\"host_bash\""
assert_file_contains "$AUDIT_FILE" "\"category\":\"git\""
assert_file_contains "$AUDIT_FILE" "\"cmd\":\"git status\""

echo "PASS: hook-post-bash logging"
