#!/usr/bin/env bash
# sandshell audit-config — runs per-agent audit adapters and aggregates findings.
#
# Adapter contract: each agent's adapter at agents/<name>/audit.sh is an
# executable that emits NDJSON findings to stdout. One finding per line:
#
#   {"id":"cc.sandbox.enabled","severity":"critical","title":"...","scope":"...","fix":"..."}
#
# Required fields: id, severity, title.
# Optional fields: scope (file path or "host"), fix (remediation), details.
# Severity must be one of: critical, high, medium, info.
#
# Adapters self-detect whether their agent is installed; if not, they emit
# zero findings and exit 0.
#
# Drift detection: when a baseline exists at ~/.sandshell/baselines/current.json,
# the human/json output also reports findings new or resolved since that
# snapshot. --snapshot writes a fresh baseline. Apply scripts call
# `audit-config.sh --snapshot --no-drift --json >/dev/null` after writing
# their config so the post-apply state becomes the new baseline.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ADAPTERS_DIR="$ROOT/agents"
# shellcheck source=lib/baseline.sh
. "$SCRIPT_DIR/lib/baseline.sh"

JSON_OUTPUT=false
STRICT=false
SUMMARY=false
SNAPSHOT=false
NO_DRIFT=false
DRIFT_ONLY=false
PRUNE_KEEP=""

usage() {
  cat <<EOF
Usage: audit-config.sh [--json | --summary | --drift-only] [--strict] [--snapshot] [--no-drift] [--prune[=N]]

  --json        Emit findings (and drift) as JSON (machine-readable)
  --summary     Per-agent worst-severity rollup, key=value format (greppable)
  --drift-only  Print only the drift block (what's new / resolved since baseline)
  --strict      Exit 2 if any finding has severity >= medium (for verify / CI)
  --snapshot    Write the current findings as the new baseline (used by apply)
  --no-drift    Suppress drift output even if a baseline exists
  --prune[=N]   Delete historical snapshots older than the most recent N
                (default 10). current.json is never pruned.

Adapters live in agents/<name>/audit.sh. Each is invoked independently and
emits NDJSON findings to stdout.

Drift baseline:
  Stored under \${SANDSHELL_BASELINE_DIR:-~/.sandshell/baselines}/.
  current.json is the comparison target; audit-<ts>.json files are
  historical snapshots, retained indefinitely unless --prune is passed.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)        JSON_OUTPUT=true; shift ;;
    --summary)     SUMMARY=true; shift ;;
    --drift-only)  DRIFT_ONLY=true; shift ;;
    --strict)      STRICT=true; shift ;;
    --snapshot)    SNAPSHOT=true; shift ;;
    --no-drift)    NO_DRIFT=true; shift ;;
    --prune)       PRUNE_KEEP="10"; shift ;;
    --prune=*)     PRUNE_KEEP="${1#*=}"; shift ;;
    -h|--help|help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -n "$PRUNE_KEEP" ]]; then
  if ! [[ "$PRUNE_KEEP" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --prune=N requires a non-negative integer (got '$PRUNE_KEEP')" >&2
    exit 1
  fi
fi

modes=0
$JSON_OUTPUT && modes=$((modes+1))
$SUMMARY && modes=$((modes+1))
$DRIFT_ONLY && modes=$((modes+1))
if [[ "$modes" -gt 1 ]]; then
  echo "ERROR: --json, --summary, and --drift-only are mutually exclusive" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required for audit." >&2
  exit 1
fi

# Collect raw NDJSON findings from all adapters.
findings_file="$(mktemp "${TMPDIR:-/tmp}/sandshell-audit.XXXXXX")"
trap 'rm -f "$findings_file"' EXIT

# Track which adapters ran so --summary can report 'ok' for ones that emitted
# zero findings (vs not appearing at all).
ran_adapters=()

shopt -s nullglob
for adapter in "$ADAPTERS_DIR"/*/audit.sh; do
  if [[ -x "$adapter" ]]; then
    agent_name="$(basename "$(dirname "$adapter")")"
    ran_adapters+=("$agent_name")
    if ! "$adapter" >> "$findings_file" 2>/dev/null; then
      echo "WARNING: adapter for '$agent_name' exited non-zero; findings may be incomplete" >&2
    fi
  fi
done
shopt -u nullglob

baseline_dir="$(sandshell_baseline_dir)"
baseline_current="$(sandshell_baseline_current)"
[[ "$NO_DRIFT" = "true" ]] && baseline_current=""
[[ -f "$baseline_current" ]] || baseline_current=""

# Snapshot target (timestamped historical + current.json refresh). Done in
# Python after the JSON envelope is built; here we just compute the path.
snapshot_hist=""
if [[ "$SNAPSHOT" = "true" ]]; then
  mkdir -p "$baseline_dir"
  snapshot_hist="$baseline_dir/audit-$(date -u +%Y-%m-%dT%H-%M-%SZ).json"
fi

# Pre-compute the snapshot-trail summary string so the Python rendering
# layer can print it under the drift block without re-implementing the
# directory walk. (Computed BEFORE writing the new snapshot so the count
# reflects what existed when the audit started.)
baseline_summary_line=""
if [[ -n "$baseline_current" || "$SNAPSHOT" = "true" ]]; then
  baseline_summary_line="$(sandshell_baseline_summary)"
fi

# Format and emit
python3 - \
  "$findings_file" \
  "$JSON_OUTPUT" \
  "$STRICT" \
  "$SUMMARY" \
  "$DRIFT_ONLY" \
  "$baseline_current" \
  "$snapshot_hist" \
  "$baseline_dir/current.json" \
  "$baseline_summary_line" \
  "$PRUNE_KEEP" \
  "${ran_adapters[*]:-}" <<'PY'
import json, os, sys
from datetime import datetime, timezone

findings_path     = sys.argv[1]
json_output       = sys.argv[2] == "true"
strict            = sys.argv[3] == "true"
summary           = sys.argv[4] == "true"
drift_only        = sys.argv[5] == "true"
baseline_current  = sys.argv[6]                                 # "" if no baseline / suppressed
snapshot_hist     = sys.argv[7]                                 # "" if --snapshot not set
baseline_pointer  = sys.argv[8]                                 # current.json path (always set)
baseline_summary  = sys.argv[9]                                 # "" when no drift / not relevant
prune_keep        = sys.argv[10]                                # "" if --prune not set, else N as string
ran_adapters      = sys.argv[11].split() if len(sys.argv) > 11 else []

SEVERITY_ORDER = {"critical": 0, "high": 1, "medium": 2, "info": 3}
ACTIONABLE = {"critical", "high", "medium"}

# Colorize human output when stdout is a TTY and NO_COLOR is unset.
# https://no-color.org/ — respect the env var.
USE_COLOR = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
COLORS = {
    "reset":    "\033[0m",
    "bold":     "\033[1m",
    "dim":      "\033[2m",
    "critical": "\033[1;31m",  # bold red
    "high":     "\033[1;33m",  # bold yellow
    "medium":   "\033[1;34m",  # bold blue
    "info":     "\033[2;37m",  # dim white
    "added":    "\033[1;31m",  # new findings since baseline = regression
    "resolved": "\033[1;32m",  # resolved findings = improvement
}
def c(name, text):
    if not USE_COLOR:
        return text
    return f"{COLORS[name]}{text}{COLORS['reset']}"

# Replace $HOME with ~ in a path-like string for display compactness.
HOME = os.environ.get("HOME", "")
def shorten(s):
    if not isinstance(s, str) or not HOME:
        return s
    return s.replace(HOME, "~") if s.startswith(HOME) else s

# Map a finding ID prefix (the part before the first dot) to the adapter
# directory name. Most are 1:1; cc.* is the exception (claude adapter emits
# findings with a `cc.` prefix for consistency with Claude Code's `cc_` field
# names elsewhere).
ID_PREFIX_TO_ADAPTER = {"cc": "claude"}

def adapter_for(finding_id):
    prefix = finding_id.split(".", 1)[0]
    return ID_PREFIX_TO_ADAPTER.get(prefix, prefix)

findings = []
with open(findings_path) as f:
    for lineno, line in enumerate(f, 1):
        line = line.strip()
        if not line:
            continue
        try:
            f_obj = json.loads(line)
        except json.JSONDecodeError as e:
            print(f"WARNING: skipping malformed finding at line {lineno}: {e}", file=sys.stderr)
            continue
        for required in ("id", "severity", "title"):
            if required not in f_obj:
                print(f"WARNING: skipping finding missing '{required}': {f_obj}", file=sys.stderr)
                break
        else:
            if f_obj["severity"] not in SEVERITY_ORDER:
                print(f"WARNING: skipping finding with invalid severity: {f_obj}", file=sys.stderr)
                continue
            findings.append(f_obj)

findings.sort(key=lambda f: (SEVERITY_ORDER[f["severity"]], f["id"]))

# Compute drift against the baseline (if one is loadable).
drift = None
if baseline_current and os.path.exists(baseline_current):
    try:
        with open(baseline_current) as f:
            base = json.load(f)
        base_findings = base.get("findings", [])
        base_ts = base.get("timestamp", "")
        cur_ids = {f["id"]: f for f in findings}
        base_ids = {f["id"]: f for f in base_findings}
        added_ids   = sorted(cur_ids.keys() - base_ids.keys(),
                             key=lambda i: (SEVERITY_ORDER[cur_ids[i]["severity"]], i))
        resolved_ids = sorted(base_ids.keys() - cur_ids.keys(),
                              key=lambda i: (SEVERITY_ORDER[base_ids[i]["severity"]], i))
        drift = {
            "baseline_timestamp": base_ts,
            "added":    [cur_ids[i]   for i in added_ids],
            "resolved": [base_ids[i]  for i in resolved_ids],
        }
    except (OSError, json.JSONDecodeError) as e:
        print(f"WARNING: could not read baseline at {baseline_current}: {e}", file=sys.stderr)

# Build the JSON envelope (same shape used for output and snapshots).
envelope = {
    "version": "0.2",
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "findings": findings,
}
if drift is not None:
    envelope["drift"] = drift

# Optionally write the snapshot. We snapshot the findings only (not the drift
# block) — the next run will recompute drift against this snapshot.
if snapshot_hist:
    snap = {k: v for k, v in envelope.items() if k != "drift"}
    try:
        os.makedirs(os.path.dirname(snapshot_hist), exist_ok=True)
        with open(snapshot_hist, "w") as f:
            json.dump(snap, f, indent=2)
        with open(baseline_pointer, "w") as f:
            json.dump(snap, f, indent=2)
    except OSError as e:
        print(f"WARNING: could not write snapshot at {snapshot_hist}: {e}", file=sys.stderr)

# Optionally prune old historical snapshots. current.json (the comparison
# pointer) is never pruned. Runs after the new snapshot is written so
# `--snapshot --prune` keeps the latest.
if prune_keep:
    try:
        keep_n = int(prune_keep)
    except ValueError:
        keep_n = -1
    if keep_n >= 0:
        baseline_dir = os.path.dirname(baseline_pointer)
        try:
            entries = []
            for name in os.listdir(baseline_dir):
                if name.startswith("audit-") and name.endswith(".json"):
                    entries.append(os.path.join(baseline_dir, name))
            entries.sort()  # ISO timestamps sort chronologically
            removed = 0
            for victim in entries[:-keep_n] if keep_n > 0 else entries:
                try:
                    os.remove(victim)
                    removed += 1
                except OSError as e:
                    print(f"WARNING: could not remove {victim}: {e}", file=sys.stderr)
            if removed and not (json_output or summary or drift_only):
                print(f"Pruned {removed} historical snapshot(s) (kept latest {keep_n}).", file=sys.stderr)
        except OSError:
            pass

# ---------- output ----------

def print_drift_human(d):
    """Render the drift block to stdout. Caller decides when to call this."""
    added, resolved = d["added"], d["resolved"]
    base_ts = d["baseline_timestamp"]
    if not added and not resolved:
        print(c("dim", f"No drift since baseline ({base_ts})."))
        return
    print(c("bold", f"Drift since {base_ts}: ") +
          f"{c('added', f'+{len(added)} new')} / "
          f"{c('resolved', f'-{len(resolved)} resolved')}")
    if added:
        for f in added:
            print(f"  {c('added', '+')} {c('bold', f['id'])}  "
                  f"({c(f['severity'], f['severity'])})  {shorten(f['title'])}")
    if resolved:
        for f in resolved:
            print(f"  {c('resolved', '-')} {c('bold', f['id'])}  "
                  f"({c(f['severity'], f['severity'])})  {shorten(f['title'])}  "
                  f"{c('dim', '— resolved')}")

if drift_only:
    if drift is None:
        print("No baseline yet. Run 'sandshell apply' (or 'sandshell audit --snapshot') to capture one.")
    else:
        print_drift_human(drift)
        if baseline_summary:
            print()
            print(c("dim", f"{baseline_summary}."))

elif summary:
    # Worst severity per adapter; "ok" if no findings.
    worst_by_adapter = {a: None for a in ran_adapters}
    for f in findings:
        a = adapter_for(f["id"])
        sev = f["severity"]
        if a not in worst_by_adapter or worst_by_adapter[a] is None \
           or SEVERITY_ORDER[sev] < SEVERITY_ORDER[worst_by_adapter[a]]:
            worst_by_adapter[a] = sev
    counts = {s: 0 for s in SEVERITY_ORDER}
    for f in findings:
        counts[f["severity"]] += 1
    actionable = sum(counts[s] for s in ACTIONABLE)

    print(f"total_findings={len(findings)}")
    print(f"total_actionable={actionable}")
    for sev in ("critical", "high", "medium", "info"):
        print(f"count_{sev}={counts[sev]}")
    for a in sorted(worst_by_adapter):
        print(f"agent_{a}={worst_by_adapter[a] or 'ok'}")
    if drift is not None:
        print(f"drift_added={len(drift['added'])}")
        print(f"drift_resolved={len(drift['resolved'])}")

elif json_output:
    print(json.dumps(envelope, indent=2))

else:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"sandshell audit — {ts}")
    print()

    if not findings:
        print("No findings. Configurations look safe.")
    else:
        by_sev = {}
        for f in findings:
            by_sev.setdefault(f["severity"], []).append(f)

        for sev in ("critical", "high", "medium", "info"):
            if sev not in by_sev:
                continue
            count = len(by_sev[sev])
            print(c(sev, f"{sev.upper()} ({count})"))
            for f in by_sev[sev]:
                print(f"  {c('bold', f['id'])}")
                print(f"    {shorten(f['title'])}")
                if f.get("scope"):
                    print(f"    scope: {shorten(f['scope'])}")
                if f.get("fix"):
                    print(f"    fix:   {shorten(f['fix'])}")
                if f.get("details"):
                    print(f"    {c('dim', shorten(f['details']))}")
            print()

        actionable = sum(1 for f in findings if f["severity"] in ACTIONABLE)
        if actionable == 0:
            print("No actionable findings. (Entries above are info-level — advisory.)")
        elif actionable == 1:
            print("1 actionable finding (severity >= medium).")
        else:
            print(f"{actionable} actionable findings (severity >= medium).")

    # Drift footer (default human output only).
    if drift is not None:
        print()
        print_drift_human(drift)
        if baseline_summary:
            print()
            print(c("dim", f"{baseline_summary}."))

if strict:
    actionable = sum(1 for f in findings if f["severity"] in ACTIONABLE)
    sys.exit(2 if actionable > 0 else 0)
sys.exit(0)
PY
