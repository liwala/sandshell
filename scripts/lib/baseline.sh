#!/usr/bin/env bash
# sandshell library: audit baseline storage.
#
# Sourced by audit-config.sh to read/write baselines for drift detection.
# A baseline is the JSON output of `sandshell audit --json` captured at a
# point in time. Comparing the current findings against the baseline tells
# the user what changed since their last apply (or last manual snapshot).
#
# Layout under SANDSHELL_BASELINE_DIR (default ~/.sandshell/baselines):
#   current.json              — pointer to the most recent snapshot
#   audit-<ISO-timestamp>.json — historical snapshots, kept indefinitely
#
# Override SANDSHELL_BASELINE_DIR for tests.

sandshell_baseline_dir() {
  echo "${SANDSHELL_BASELINE_DIR:-$HOME/.sandshell/baselines}"
}

sandshell_baseline_current() {
  echo "$(sandshell_baseline_dir)/current.json"
}

# Write stdin (audit --json output) to a timestamped historical snapshot
# and refresh current.json to point at it. Echoes the timestamped path.
sandshell_baseline_write() {
  local dir; dir="$(sandshell_baseline_dir)"
  mkdir -p "$dir"
  local ts; ts="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
  local hist="$dir/audit-$ts.json"
  cat > "$hist"
  cp "$hist" "$dir/current.json"
  echo "$hist"
}
