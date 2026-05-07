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

# Echo a one-line summary of the snapshot directory: "<count> snapshots in
# <dir> (oldest <YYYY-MM-DD>)". For 0 snapshots: "no snapshots yet". For 1:
# omits the "(oldest …)" clause. The dir is shortened with $HOME → ~.
#
# Used by apply scripts (after each --snapshot) and by audit-config.sh's
# drift output to tell the user how thick the trail has gotten.
sandshell_baseline_summary() {
  local dir; dir="$(sandshell_baseline_dir)"
  if [[ ! -d "$dir" ]]; then
    echo "no snapshots yet"
    return 0
  fi
  local files=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && files+=("$f")
  done < <(find "$dir" -maxdepth 1 -type f -name 'audit-*.json' 2>/dev/null | sort)
  local count="${#files[@]}"
  local short_dir="${dir/#$HOME/~}"
  if [[ "$count" -eq 0 ]]; then
    echo "no snapshots yet"
  elif [[ "$count" -eq 1 ]]; then
    echo "1 snapshot in $short_dir"
  else
    local oldest_date
    oldest_date=$(echo "${files[0]}" | sed -E 's|.*/audit-([0-9]{4}-[0-9]{2}-[0-9]{2}).*|\1|')
    echo "$count snapshots in $short_dir (oldest $oldest_date)"
  fi
}
