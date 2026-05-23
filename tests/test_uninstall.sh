#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/testlib.sh"

TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/sandshell-test-uninstall.XXXXXX")"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

mkdir -p "$TMPDIR_TEST/project/.claude/skills/sandshell" "$TMPDIR_TEST/project/.codex/skills/sandshell"
export HOME="$TMPDIR_TEST/home"

cat > "$TMPDIR_TEST/project/.claude/settings.json" << 'EOF'
{
  "sandshell_managed": true,
  "sandbox": {
    "network": {
      "allowedHosts": ["github.com"]
    }
  },
  "permissions": {
    "deny": [
      "Bash(dangerouslyDisableSandbox:true)",
      "OtherRule"
    ]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/tmp/hook-pre-bash.sh"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/tmp/hook-post-bash.sh"
          }
        ]
      },
      {
        "matcher": "Write",
        "hooks": [
          {
            "type": "command",
            "command": "echo keep"
          }
        ]
      }
    ]
  }
}
EOF

cat > "$TMPDIR_TEST/project/GEMINI.md" << 'EOF'
before
<!-- sandshell: begin -->
remove me
<!-- sandshell: end -->
after
EOF

cat > "$TMPDIR_TEST/project/AGENTS.md" << 'EOF'
before
<!-- sandshell: begin -->
remove me
<!-- sandshell: end -->
after
EOF

cat > "$TMPDIR_TEST/project/SANDSHELL.md" << 'EOF'
generated
EOF

(
  cd "$TMPDIR_TEST/project"
  "$ROOT/scripts/uninstall.sh" project --remove-agent-installs > /dev/null
)

SETTINGS_FILE="$TMPDIR_TEST/project/.claude/settings.json"
assert_file_not_contains "$SETTINGS_FILE" "sandshell_managed"
assert_file_not_contains "$SETTINGS_FILE" "dangerouslyDisableSandbox"
assert_file_not_contains "$SETTINGS_FILE" "hook-pre-bash.sh"
assert_file_not_contains "$SETTINGS_FILE" "hook-post-bash.sh"
assert_json_value "$SETTINGS_FILE" "permissions.deny.0" "OtherRule"
assert_json_value "$SETTINGS_FILE" "hooks.PostToolUse.0.matcher" "Write"
assert_not_exists "$TMPDIR_TEST/project/.claude/skills/sandshell"
assert_not_exists "$TMPDIR_TEST/project/.codex/skills/sandshell"
assert_not_exists "$TMPDIR_TEST/project/SANDSHELL.md"
assert_file_not_contains "$TMPDIR_TEST/project/GEMINI.md" "remove me"
assert_file_not_contains "$TMPDIR_TEST/project/AGENTS.md" "remove me"

echo "PASS: uninstall rollback"
