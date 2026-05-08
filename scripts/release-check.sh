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

bash -n bin/sandshell scripts/*.sh scripts/lib/*.sh tests/*.sh agents/*/audit.sh

# Run shellcheck at warning-level. SC1091 is suppressed because lib/*.sh
# sourcing uses a runtime path that the linter can't follow without -x; we
# lint the libs directly instead. Skipped silently if not installed.
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning -e SC1091 \
    bin/sandshell \
    scripts/*.sh \
    scripts/lib/*.sh \
    agents/*/audit.sh \
    tests/*.sh
else
  echo "NOTE: shellcheck not installed; skipping shell linting" >&2
fi

bash tests/run.sh

echo "PASS: release-check"
