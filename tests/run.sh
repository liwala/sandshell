#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for test_script in "$ROOT"/tests/test_*.sh; do
  bash "$test_script"
done
