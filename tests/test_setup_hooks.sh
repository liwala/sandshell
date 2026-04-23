#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/testlib.sh"

TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/sandshell-test-hooks.XXXXXX")"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

mkdir -p "$TMPDIR_TEST/project/.claude"
export HOME="$TMPDIR_TEST/home"

cat > "$TMPDIR_TEST/project/.claude/settings.json" <<'EOF'
{
  "sandbox": {
    "network": {
      "allowedHosts": ["github.com"]
    }
  },
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write",
        "hooks": [
          {
            "type": "command",
            "command": "echo existing"
          }
        ]
      }
    ]
  }
}
EOF

(
  cd "$TMPDIR_TEST/project"
  "$ROOT/scripts/setup-hooks.sh" project >/dev/null
)

SETTINGS_FILE="$TMPDIR_TEST/project/.claude/settings.json"
assert_json_value "$SETTINGS_FILE" "sandbox.network.allowedHosts.0" "github.com"
assert_json_value "$SETTINGS_FILE" "hooks.PostToolUse.0.matcher" "Write"
assert_json_value "$SETTINGS_FILE" "hooks.PreToolUse.0.matcher" "Bash"
assert_json_value "$SETTINGS_FILE" "hooks.PreToolUse.0.hooks.0.command" "$ROOT/scripts/hook-pre-bash.sh"
assert_json_value "$SETTINGS_FILE" "hooks.PostToolUse.1.matcher" "Bash"
assert_json_value "$SETTINGS_FILE" "hooks.PostToolUse.1.hooks.0.command" "$ROOT/scripts/hook-post-bash.sh"

before_hash=$(python3 - "$SETTINGS_FILE" <<'PY'
import hashlib
import sys
print(hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest())
PY
)
(
  cd "$TMPDIR_TEST/project"
  "$ROOT/scripts/setup-hooks.sh" project >/dev/null
)
after_hash=$(python3 - "$SETTINGS_FILE" <<'PY'
import hashlib
import sys
print(hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest())
PY
)
[[ "$before_hash" == "$after_hash" ]] || fail "setup-hooks.sh should not duplicate the hooks"

echo "PASS: setup-hooks merge behavior"
