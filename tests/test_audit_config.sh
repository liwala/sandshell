#!/usr/bin/env bash
# Tests the audit-config.sh runner: severity sorting, --json schema, --strict
# exit codes, malformed-finding handling. Uses an isolated agents/ directory
# in a temp ROOT to control which adapters run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/testlib.sh"

TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/sandshell-test-runner.XXXXXX")"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Build a minimal sandshell tree in TMPDIR with only the runner script and
# fixture adapters. This way we control exactly which adapters fire.
FAKE_ROOT="$TMPDIR_TEST/sandshell"
mkdir -p "$FAKE_ROOT/scripts/lib" "$FAKE_ROOT/agents"
cp "$ROOT/scripts/audit-config.sh" "$FAKE_ROOT/scripts/audit-config.sh"
cp "$ROOT/scripts/lib/baseline.sh" "$FAKE_ROOT/scripts/lib/baseline.sh"

# Pin the baseline dir into TMPDIR_TEST so drift state doesn't leak into the
# real ~/.sandshell/baselines/ during tests, and earlier test cases can't
# create snapshots that later cases see.
export SANDSHELL_BASELINE_DIR="$TMPDIR_TEST/baselines"

make_adapter() {
  local name="$1"
  local body="$2"
  mkdir -p "$FAKE_ROOT/agents/$name"
  cat > "$FAKE_ROOT/agents/$name/audit.sh" << EOF
#!/usr/bin/env bash
$body
EOF
  chmod +x "$FAKE_ROOT/agents/$name/audit.sh"
}

# Case 1: no adapters → "No findings" + exit 0.
out=$("$FAKE_ROOT/scripts/audit-config.sh" 2>&1)
[[ "$out" == *"No findings"* ]] || fail "case1: expected 'No findings', got: $out"

# Case 2: one critical + one high + one info → severity ordering.
make_adapter test1 'cat <<JSON
{"id":"t.crit","severity":"critical","title":"crit"}
{"id":"t.high","severity":"high","title":"high"}
{"id":"t.info","severity":"info","title":"info"}
JSON'
out=$("$FAKE_ROOT/scripts/audit-config.sh" 2>&1)
# critical must appear before high, and high before info in the text output.
crit_pos=$(echo "$out" | grep -n "t.crit" | head -1 | cut -d: -f1)
high_pos=$(echo "$out" | grep -n "t.high" | head -1 | cut -d: -f1)
info_pos=$(echo "$out" | grep -n "t.info" | head -1 | cut -d: -f1)
[[ -n "$crit_pos" && -n "$high_pos" && -n "$info_pos" ]] \
  || fail "case2: missing one of crit/high/info: $out"
[[ "$crit_pos" -lt "$high_pos" && "$high_pos" -lt "$info_pos" ]] \
  || fail "case2: severity order wrong (crit=$crit_pos high=$high_pos info=$info_pos)"

# Case 3: --strict with high finding → exit 2.
set +e
"$FAKE_ROOT/scripts/audit-config.sh" --strict > /dev/null 2>&1
ec=$?
set -e
[[ "$ec" == "2" ]] || fail "case3: --strict with findings should exit 2, got $ec"

# Case 4: --strict with only info findings → exit 0.
rm -rf "$FAKE_ROOT/agents/test1"
make_adapter test1 'cat <<JSON
{"id":"t.info","severity":"info","title":"info-only"}
JSON'
set +e
"$FAKE_ROOT/scripts/audit-config.sh" --strict > /dev/null 2>&1
ec=$?
set -e
[[ "$ec" == "0" ]] || fail "case4: --strict with only info should exit 0, got $ec"

# Case 5: --json output is valid JSON with required schema.
out=$("$FAKE_ROOT/scripts/audit-config.sh" --json 2> /dev/null)
echo "$out" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'version' in d, 'missing version'
assert 'timestamp' in d, 'missing timestamp'
assert 'findings' in d, 'missing findings'
assert isinstance(d['findings'], list), 'findings not a list'
" || fail "case5: --json output failed schema check: $out"

# Case 6: malformed JSON line is skipped with warning, not fatal.
rm -rf "$FAKE_ROOT/agents/test1"
make_adapter test1 'cat <<JSON
{not valid json
{"id":"t.ok","severity":"info","title":"ok"}
JSON'
out=$("$FAKE_ROOT/scripts/audit-config.sh" 2>&1)
[[ "$out" == *"t.ok"* ]] || fail "case6: valid finding should still appear: $out"
[[ "$out" == *"WARNING"* || "$out" == *"malformed"* ]] \
  || fail "case6: malformed line should produce a warning: $out"

# Case 7: missing required field is skipped with warning.
rm -rf "$FAKE_ROOT/agents/test1"
make_adapter test1 'cat <<JSON
{"id":"t.missing-title","severity":"info"}
{"id":"t.ok","severity":"info","title":"ok"}
JSON'
out=$("$FAKE_ROOT/scripts/audit-config.sh" 2>&1)
[[ "$out" == *"t.ok"* ]] || fail "case7: valid finding should still appear: $out"

# Case 8: invalid severity is skipped — bad finding never rendered as a section
# entry in stdout (it may still appear in stderr WARNING text, which we ignore).
rm -rf "$FAKE_ROOT/agents/test1"
make_adapter test1 'cat <<JSON
{"id":"t.bad-sev","severity":"bogus","title":"bogus severity"}
{"id":"t.ok","severity":"info","title":"ok"}
JSON'
stdout=$("$FAKE_ROOT/scripts/audit-config.sh" 2> /dev/null)
# Rendered findings appear with two leading spaces. A skipped finding never gets
# that rendering.
echo "$stdout" | grep -qE "^  t\.bad-sev$" \
  && fail "case8: invalid severity should not be rendered: $stdout" || true
[[ "$stdout" == *"t.ok"* ]] || fail "case8: valid finding should still appear: $stdout"

# Case 9: --summary emits per-agent worst-severity + counts (key=value).
rm -rf "$FAKE_ROOT/agents/test1"
make_adapter test1 'cat <<JSON
{"id":"test1.crit","severity":"critical","title":"crit"}
{"id":"test1.med","severity":"medium","title":"med"}
JSON'
make_adapter test2 'cat <<JSON
{"id":"test2.info","severity":"info","title":"info"}
JSON'
out=$("$FAKE_ROOT/scripts/audit-config.sh" --summary 2> /dev/null)
[[ "$out" == *"agent_test1=critical"* ]] \
  || fail "case9: expected agent_test1=critical, got: $out"
[[ "$out" == *"agent_test2=info"* ]] \
  || fail "case9: expected agent_test2=info, got: $out"
[[ "$out" == *"total_actionable=2"* ]] \
  || fail "case9: expected total_actionable=2, got: $out"
[[ "$out" == *"count_critical=1"* ]] \
  || fail "case9: expected count_critical=1, got: $out"

# Case 10: adapter with zero findings shows agent_<name>=ok.
rm -rf "$FAKE_ROOT/agents/test1" "$FAKE_ROOT/agents/test2"
make_adapter test_silent 'true'
out=$("$FAKE_ROOT/scripts/audit-config.sh" --summary 2> /dev/null)
[[ "$out" == *"agent_test_silent=ok"* ]] \
  || fail "case10: expected agent_test_silent=ok for silent adapter, got: $out"

# Case 11: --json and --summary are mutually exclusive.
set +e
"$FAKE_ROOT/scripts/audit-config.sh" --json --summary > /dev/null 2>&1
ec=$?
set -e
[[ "$ec" != "0" ]] || fail "case11: --json --summary should error, got exit $ec"

# ---------- Drift detection (cases 12+) ----------
# Reset to a known fixture: one critical, one medium.
rm -rf "$FAKE_ROOT/agents"/*
make_adapter d 'cat <<JSON
{"id":"d.crit","severity":"critical","title":"d crit"}
{"id":"d.med","severity":"medium","title":"d med"}
JSON'

# Case 12: --drift-only with no baseline → friendly "no baseline yet" message.
out=$("$FAKE_ROOT/scripts/audit-config.sh" --drift-only 2>&1)
[[ "$out" == *"No baseline yet"* ]] || fail "case12: expected 'No baseline yet', got: $out"

# Case 13: --snapshot writes current.json + a timestamped historical file.
"$FAKE_ROOT/scripts/audit-config.sh" --snapshot --no-drift --json > /dev/null
[[ -f "$SANDSHELL_BASELINE_DIR/current.json" ]] \
  || fail "case13: --snapshot should write current.json"
hist_count=$(ls "$SANDSHELL_BASELINE_DIR"/audit-*.json 2> /dev/null | wc -l)
[[ "$hist_count" -ge 1 ]] || fail "case13: --snapshot should write a historical audit-*.json"

# Case 14: re-running audit with no changes → drift footer says "No drift".
out=$("$FAKE_ROOT/scripts/audit-config.sh" 2>&1)
[[ "$out" == *"No drift since baseline"* ]] \
  || fail "case14: expected 'No drift since baseline', got: $out"

# Case 15: mutate adapter (resolve d.med, add d.new) → drift detects both.
rm -rf "$FAKE_ROOT/agents/d"
make_adapter d 'cat <<JSON
{"id":"d.crit","severity":"critical","title":"d crit"}
{"id":"d.new","severity":"high","title":"a new finding"}
JSON'
out=$("$FAKE_ROOT/scripts/audit-config.sh" --drift-only 2>&1)
[[ "$out" == *"+1 new"* && "$out" == *"-1 resolved"* ]] \
  || fail "case15: expected +1 new / -1 resolved, got: $out"
[[ "$out" == *"d.new"* ]] || fail "case15: drift should name added id d.new, got: $out"
[[ "$out" == *"d.med"* ]] || fail "case15: drift should name resolved id d.med, got: $out"

# Case 16: --no-drift suppresses the footer in default human output.
out=$("$FAKE_ROOT/scripts/audit-config.sh" --no-drift 2>&1)
[[ "$out" != *"Drift since"* && "$out" != *"No drift"* ]] \
  || fail "case16: --no-drift should suppress drift output, got: $out"

# Case 17: --json includes a drift block when baseline exists.
out=$("$FAKE_ROOT/scripts/audit-config.sh" --json 2> /dev/null)
echo "$out" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'drift' in d, 'json output missing drift block'
assert {f['id'] for f in d['drift']['added']} == {'d.new'}, d['drift']['added']
assert {f['id'] for f in d['drift']['resolved']} == {'d.med'}, d['drift']['resolved']
" || fail "case17: --json drift block malformed: $out"

# Case 18: --summary includes drift counts when baseline exists.
out=$("$FAKE_ROOT/scripts/audit-config.sh" --summary 2> /dev/null)
[[ "$out" == *"drift_added=1"* ]] || fail "case18: expected drift_added=1, got: $out"
[[ "$out" == *"drift_resolved=1"* ]] || fail "case18: expected drift_resolved=1, got: $out"

# Case 19: --drift-only and --json are mutually exclusive.
set +e
"$FAKE_ROOT/scripts/audit-config.sh" --drift-only --json > /dev/null 2>&1
ec=$?
set -e
[[ "$ec" != "0" ]] || fail "case19: --drift-only --json should error, got exit $ec"

# Case 20: drift output includes a snapshot-count line ("N snapshots in ...").
# We have 1 baseline written by case 13's --snapshot; add a second so the
# "(oldest <date>)" clause renders. Sleep 1s so the timestamp differs.
sleep 1
"$FAKE_ROOT/scripts/audit-config.sh" --snapshot --no-drift --json > /dev/null
out=$(NO_COLOR=1 "$FAKE_ROOT/scripts/audit-config.sh" --drift-only 2>&1)
[[ "$out" == *"snapshots in"* ]] \
  || fail "case20: drift-only should include snapshot-count line, got: $out"
[[ "$out" == *"(oldest"* ]] \
  || fail "case20: count line should mention oldest snapshot date, got: $out"

echo "PASS: audit-config runner (sort, --json schema, --strict, --summary, malformed handling, drift, count)"
