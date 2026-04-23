#!/usr/bin/env bash
# sandshell: maintainer smoke test for release readiness
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -gt 0 ]]; then
  case "$1" in
    --help|-h|help)
      echo "Usage: release-check.sh"
      echo ""
      echo "Runs syntax checks, regression tests, and required-doc checks."
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
fi

cd "$ROOT"

for required_file in README.md CHANGELOG.md SECURITY.md VERSION; do
  [[ -f "$required_file" ]] || {
    echo "ERROR: missing required release file: $required_file" >&2
    exit 1
  }
done

bash -n scripts/*.sh tests/*.sh
bash tests/run.sh

echo "PASS: release-check"
