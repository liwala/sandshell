#!/usr/bin/env bash
# Tests the bin/sandshell dispatcher: --version matches VERSION file, unknown
# verbs exit non-zero, apply-all forwards args to every detected agent's
# setup script (issue: previously only Claude got "$@").
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/testlib.sh"

TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/sandshell-test-cli.XXXXXX")"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Build a sandbox sandshell tree with stub setup scripts that record their argv
# so we can assert what got forwarded to each agent.
FAKE_ROOT="$TMPDIR_TEST/sandshell"
mkdir -p "$FAKE_ROOT/bin" "$FAKE_ROOT/scripts"
cp "$ROOT/bin/sandshell" "$FAKE_ROOT/bin/sandshell"
echo "0.99.0-test" > "$FAKE_ROOT/VERSION"

CALL_LOG="$TMPDIR_TEST/call_log"
: > "$CALL_LOG"

make_stub() {
  local name="$1"
  cat > "$FAKE_ROOT/scripts/$name" <<EOF
#!/usr/bin/env bash
printf '%s' "$name" >> "$CALL_LOG"
for arg in "\$@"; do printf ' %s' "\$arg" >> "$CALL_LOG"; done
printf '\n' >> "$CALL_LOG"
exit 0
EOF
  chmod +x "$FAKE_ROOT/scripts/$name"
}
make_stub setup.sh
make_stub setup-codex.sh
make_stub setup-gemini.sh
make_stub detect.sh
make_stub install-agent.sh
make_stub uninstall.sh
make_stub audit-trail.sh
make_stub audit-config.sh

# Force "all agents detected" by faking $HOME with the directories the
# dispatcher uses to detect installed agents.
FAKE_HOME="$TMPDIR_TEST/home"
mkdir -p "$FAKE_HOME/.claude" "$FAKE_HOME/.codex" "$FAKE_HOME/.gemini"

# Case 1: --version reads from VERSION file (issue #6).
out=$("$FAKE_ROOT/bin/sandshell" --version)
[[ "$out" == "sandshell 0.99.0-test" ]] \
  || fail "case1: expected 'sandshell 0.99.0-test', got: $out"

# Case 2: unknown verb exits non-zero.
set +e
"$FAKE_ROOT/bin/sandshell" notaverb >/dev/null 2>&1
ec=$?
set -e
[[ "$ec" -ne 0 ]] || fail "case2: unknown verb should exit non-zero"

# Case 3: bare 'apply' (= all detected) forwards no args to each setup script.
: > "$CALL_LOG"
HOME="$FAKE_HOME" "$FAKE_ROOT/bin/sandshell" apply >/dev/null 2>&1
grep -Fq "setup.sh " "$CALL_LOG" || grep -Fq "setup.sh" "$CALL_LOG" \
  || fail "case3: setup.sh was not invoked: $(cat "$CALL_LOG")"
grep -Fq "setup-codex.sh" "$CALL_LOG" \
  || fail "case3: setup-codex.sh was not invoked: $(cat "$CALL_LOG")"
grep -Fq "setup-gemini.sh" "$CALL_LOG" \
  || fail "case3: setup-gemini.sh was not invoked: $(cat "$CALL_LOG")"

# Case 4: 'apply all --skip-hooks' forwards --skip-hooks to every detected
# agent's setup script. Previously only Claude got "$@" (issue #1).
: > "$CALL_LOG"
HOME="$FAKE_HOME" "$FAKE_ROOT/bin/sandshell" apply all --skip-hooks >/dev/null 2>&1
grep -q "^setup.sh .*--skip-hooks" "$CALL_LOG" \
  || fail "case4: --skip-hooks not forwarded to setup.sh: $(cat "$CALL_LOG")"
grep -q "^setup-codex.sh .*--skip-hooks" "$CALL_LOG" \
  || fail "case4: --skip-hooks not forwarded to setup-codex.sh: $(cat "$CALL_LOG")"
grep -q "^setup-gemini.sh .*--skip-hooks" "$CALL_LOG" \
  || fail "case4: --skip-hooks not forwarded to setup-gemini.sh: $(cat "$CALL_LOG")"

# Case 5: 'apply' surfaces non-zero when any agent's setup fails (issue #5).
cat > "$FAKE_ROOT/scripts/setup-codex.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAKE_ROOT/scripts/setup-codex.sh"
set +e
HOME="$FAKE_HOME" "$FAKE_ROOT/bin/sandshell" apply >/dev/null 2>&1
ec=$?
set -e
[[ "$ec" -ne 0 ]] || fail "case5: apply should surface non-zero when an agent fails (got $ec)"
# Restore stub for later cases.
make_stub setup-codex.sh

# Case 6: 'apply --strict' (bare flag) routes to Claude with a notice (legacy
# compat — many flags are Claude-specific). Codex/Gemini setup must NOT run.
: > "$CALL_LOG"
HOME="$FAKE_HOME" "$FAKE_ROOT/bin/sandshell" apply --strict >/dev/null 2>&1
grep -q "^setup.sh .*--strict" "$CALL_LOG" \
  || fail "case6: bare-flag apply should route to setup.sh: $(cat "$CALL_LOG")"
grep -q "^setup-codex.sh" "$CALL_LOG" \
  && fail "case6: bare-flag apply should NOT invoke codex setup: $(cat "$CALL_LOG")" || true
grep -q "^setup-gemini.sh" "$CALL_LOG" \
  && fail "case6: bare-flag apply should NOT invoke gemini setup: $(cat "$CALL_LOG")" || true

# Case 7: 'apply' with no agents detected exits non-zero with a clear message.
EMPTY_HOME="$TMPDIR_TEST/empty"
mkdir -p "$EMPTY_HOME"
set +e
err=$(PATH="/usr/bin:/bin" HOME="$EMPTY_HOME" "$FAKE_ROOT/bin/sandshell" apply 2>&1 >/dev/null)
ec=$?
set -e
[[ "$ec" -ne 0 ]] || fail "case7: apply with no agents should exit non-zero, got $ec"
[[ "$err" == *"No supported agents detected"* ]] \
  || fail "case7: expected 'No supported agents detected', got: $err"

# Case 8: 'apply codex' forwards remaining args to setup-codex.sh.
: > "$CALL_LOG"
HOME="$FAKE_HOME" "$FAKE_ROOT/bin/sandshell" apply codex --force >/dev/null 2>&1
grep -q "^setup-codex.sh .*--force" "$CALL_LOG" \
  || fail "case8: 'apply codex --force' should forward --force: $(cat "$CALL_LOG")"

# Case 9: 'help' / '--help' / no args all print usage and exit 0.
for arg in "" "-h" "--help" "help"; do
  set +e
  if [[ -z "$arg" ]]; then
    out=$("$FAKE_ROOT/bin/sandshell" 2>&1)
  else
    out=$("$FAKE_ROOT/bin/sandshell" "$arg" 2>&1)
  fi
  ec=$?
  set -e
  [[ "$ec" -eq 0 ]] || fail "case9: '$arg' should exit 0, got $ec"
  [[ "$out" == *"sandshell <verb>"* ]] || fail "case9: '$arg' should print usage, got: $out"
done

echo "PASS: bin/sandshell dispatcher (version, apply-all forwarding, failure surfacing)"
