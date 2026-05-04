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
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ADAPTERS_DIR="$ROOT/agents"

JSON_OUTPUT=false
STRICT=false
SUMMARY=false

usage() {
  cat <<EOF
Usage: audit-config.sh [--json | --summary] [--strict]

  --json     Emit findings as a JSON array (machine-readable)
  --summary  Per-agent worst-severity rollup, key=value format (greppable)
  --strict   Exit 2 if any finding has severity >= medium (for verify / CI)

Adapters live in agents/<name>/audit.sh. Each is invoked independently and
emits NDJSON findings to stdout.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)    JSON_OUTPUT=true; shift ;;
    --summary) SUMMARY=true; shift ;;
    --strict)  STRICT=true; shift ;;
    -h|--help|help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ "$JSON_OUTPUT" == "true" && "$SUMMARY" == "true" ]]; then
  echo "ERROR: --json and --summary are mutually exclusive" >&2
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

# Format and emit
python3 - "$findings_file" "$JSON_OUTPUT" "$STRICT" "$SUMMARY" "${ran_adapters[*]:-}" <<'PY'
import json, os, sys
from datetime import datetime, timezone

findings_path = sys.argv[1]
json_output = sys.argv[2] == "true"
strict = sys.argv[3] == "true"
summary = sys.argv[4] == "true"
ran_adapters = sys.argv[5].split() if len(sys.argv) > 5 else []

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

if summary:
    # Worst severity per adapter; "ok" if no findings.
    worst_by_adapter = {a: None for a in ran_adapters}
    for f in findings:
        a = adapter_for(f["id"])
        sev = f["severity"]
        if a not in worst_by_adapter or worst_by_adapter[a] is None \
           or SEVERITY_ORDER[sev] < SEVERITY_ORDER[worst_by_adapter[a]]:
            worst_by_adapter[a] = sev
    # Severity counts
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

elif json_output:
    print(json.dumps({
        "version": "0.2",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "findings": findings,
    }, indent=2))

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
            # All findings shown above are info-level — advisory, not blocking.
            print("No actionable findings. (Entries above are info-level — advisory.)")
        elif actionable == 1:
            print("1 actionable finding (severity >= medium).")
        else:
            print(f"{actionable} actionable findings (severity >= medium).")

if strict:
    actionable = sum(1 for f in findings if f["severity"] in ACTIONABLE)
    sys.exit(2 if actionable > 0 else 0)
sys.exit(0)
PY
