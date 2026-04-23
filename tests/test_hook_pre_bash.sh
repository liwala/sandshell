#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/testlib.sh"

TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/sandshell-test-hook-pre.XXXXXX")"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

mkdir -p "$TMPDIR_TEST/bin"
export PATH="$TMPDIR_TEST/bin:$PATH"

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

printf '%s' "$allowed_payload" | "$ROOT/scripts/hook-pre-bash.sh" >/dev/null

set +e
blocked_output=$(printf '%s' "$blocked_payload" | "$ROOT/scripts/hook-pre-bash.sh" 2>&1)
blocked_status=$?
set -e

[[ "$blocked_status" -eq 2 ]] || fail "Expected blocked command to exit 2, got $blocked_status"
[[ "$blocked_output" == *"attempts to weaken sandbox protections"* ]] || fail "Unexpected block output: $blocked_output"

echo "PASS: hook-pre-bash guard behavior"
