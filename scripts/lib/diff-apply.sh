#!/usr/bin/env bash
# sandshell library: snapshot + diff helpers used by setup-* scripts.
#
# Sourced by setup-sandbox.sh, setup-hooks.sh, setup-codex.sh, setup-gemini.sh
# to give users a transparent before/after view of what `apply` actually
# changed in their config files. Always-on (no flag); empty diffs render as
# a one-line "no changes" message, fresh installs as "created" notes.

# Capture a snapshot of $1 (if it exists) into a temp file, store the path
# in the global SANDSHELL_DIFF_SNAPSHOT for sandshell_diff_show to pick up.
sandshell_diff_snapshot() {
  local file="$1"
  if [[ -f "$file" ]]; then
    SANDSHELL_DIFF_SNAPSHOT=$(mktemp "${TMPDIR:-/tmp}/sandshell-diff.XXXXXX")
    cp "$file" "$SANDSHELL_DIFF_SNAPSHOT"
  else
    SANDSHELL_DIFF_SNAPSHOT=""
  fi
}

# Print a before/after diff for $1 vs SANDSHELL_DIFF_SNAPSHOT, then clean up.
# Output format:
#   - No prior file:        "Created <path>."
#   - File unchanged:       "No changes to <path>."
#   - File changed:         unified diff, indented two spaces
sandshell_diff_show() {
  local file="$1"
  if [[ -z "${SANDSHELL_DIFF_SNAPSHOT:-}" ]]; then
    echo "Created $file."
    return
  fi
  if cmp -s "$SANDSHELL_DIFF_SNAPSHOT" "$file"; then
    echo "No changes to $file."
  else
    echo "Changes to $file:"
    # `diff` exits 1 when files differ (intentional). Swallow that with `|| :`
    # so callers running `set -euo pipefail` don't abort here.
    diff -u --label "before" --label "after" \
      "$SANDSHELL_DIFF_SNAPSHOT" "$file" 2>/dev/null | sed 's/^/  /' || :
  fi
  rm -f "$SANDSHELL_DIFF_SNAPSHOT"
  SANDSHELL_DIFF_SNAPSHOT=""
}
