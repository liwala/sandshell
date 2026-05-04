# sandshell

Pure bash + markdown project. No build system, no compiled language.

## Structure

- `SKILL.md` — Claude Code skill
- `agents/`
  - `SANDSHELL.md` — agent-agnostic sandshell core guidance
  - `CODEX.md` — Codex CLI adapter
  - `GENERIC.md` — fallback adapter for unsupported agents
- `scripts/`
  - `detect.sh` — sandbox + hooks detection
  - `setup.sh` — one-command Claude setup
  - `setup-sandbox.sh` — configure Claude native sandbox
  - `setup-hooks.sh` — configure Claude Bash guard + audit hooks
  - `uninstall.sh` — rollback Claude settings/hooks and optional agent installs
  - `release-check.sh` — maintainer smoke test
  - `audit-trail.sh` — JSONL audit trail
  - `hook-pre-bash.sh` — narrow PreToolUse guard
  - `hook-post-bash.sh` — PostToolUse Bash logger
- `profiles/` — native sandbox network allowlists
- `examples/` — usage examples

## Testing

Run scripts directly:

```bash
./scripts/detect.sh
./scripts/setup-sandbox.sh personal --profile=default --show
```

Run the regression tests:

```bash
bash tests/run.sh
```

Run the release smoke test:

```bash
bash scripts/release-check.sh
```

CI mirrors this in `.github/workflows/ci.yml`.

## Style

- `set -euo pipefail` in all scripts
- `jq` required only for setup/hooks/uninstall
- Python 3 used for JSON parsing and audit helpers

## Architecture

The support model is split between a core policy and agent adapters:

1. Native Claude sandbox for filesystem/network enforcement
2. Claude Bash guard + audit hooks for light host-side control and observability
3. Behavioral guidance to treat fetched content as untrusted input
4. Codex and generic adapters that lean on each agent's own native controls
