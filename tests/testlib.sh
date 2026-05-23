#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_contains() {
  local file="$1" needle="$2"
  [[ -f "$file" ]] || fail "Missing file: $file"
  grep -Fq -- "$needle" "$file" || fail "Expected '$needle' in $file"
}

assert_file_not_contains() {
  local file="$1" needle="$2"
  [[ -f "$file" ]] || fail "Missing file: $file"
  if grep -Fq -- "$needle" "$file"; then
    fail "Did not expect '$needle' in $file"
  fi
}

assert_not_exists() {
  local path="$1"
  [[ ! -e "$path" ]] || fail "Did not expect path to exist: $path"
}

assert_json_value() {
  local file="$1" expr="$2" expected="$3"
  [[ -f "$file" ]] || fail "Missing file: $file"
  local actual
  actual=$(
    python3 - "$file" "$expr" << 'PY'
import json
import sys

path = sys.argv[1]
expr = sys.argv[2]
value = json.load(open(path))
for part in expr.split("."):
    if isinstance(value, list):
        value = value[int(part)]
    else:
        value = value[part]
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("null")
else:
    print(value)
PY
  )
  [[ "$actual" == "$expected" ]] || fail "Expected $expr=$expected in $file, got $actual"
}

assert_symlink_target() {
  local path="$1" expected="$2"
  [[ -L "$path" ]] || fail "Expected symlink: $path"
  local actual
  actual=$(readlink "$path")
  [[ "$actual" == "$expected" ]] || fail "Expected $path -> $expected, got $actual"
}
