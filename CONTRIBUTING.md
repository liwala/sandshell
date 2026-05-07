# Contributing to sandshell

Sandshell is pure bash + markdown — no build system, no compiled language.
The development requirements are the same as the runtime: `bash`,
`python3`, and `jq`.

## Running tests

```bash
bash tests/run.sh                # unit tests
bash scripts/release-check.sh    # tests + syntax check + required-file check
```

GitHub Actions runs the release check on every push and pull request.

## Adding an audit check

Per-agent adapters live in `agents/<name>/audit.sh`. Each adapter is a
standalone executable that reads the agent's real config files and emits
NDJSON findings to stdout. See `agents/codex/audit.sh` for the smallest
working example. The runner at `scripts/audit-config.sh` aggregates
findings automatically — you don't need to register the adapter anywhere.

Required finding fields: `id`, `severity` (one of `critical` / `high` /
`medium` / `info`), `title`. Optional: `scope`, `fix`, `details`.

## Style

- `set -euo pipefail` in all scripts.
- Adapters self-skip when their agent isn't installed (return 0, emit no
  findings) — never fail the run on a missing dependency.
- Keep diffs minimal and reviewable; one logical change per commit.
