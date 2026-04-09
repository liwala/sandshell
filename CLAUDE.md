# sandshell

Pure bash + markdown project. No build system, no compiled language.

## Structure

- `SKILL.md` — the skill definition (loaded by Claude Code / Codex)
- `scripts/` — bash scripts the skill invokes
  - `detect.sh` — runtime + sandbox + hooks + pipelock detection
  - `setup.sh` — one-command setup for all protection layers
  - `setup-sandbox.sh` — configure CC native OS sandbox
  - `setup-hooks.sh` — configure PostToolUse audit hooks
  - `sandbox.sh` — container lifecycle (create/exec/destroy)
  - `harden.sh` — iptables network hardening inside containers
  - `audit.sh` — JSONL audit trail
  - `hook-post-bash.sh` — PostToolUse hook that logs all Bash commands
  - `install.sh` — platform-aware installer for docker/lima/pipelock
- `profiles/` — network allowlist configs (shared by Tier 1 and Tier 2)
- `examples/` — usage examples showing tiered behavior

## Testing

Run scripts directly:

```bash
./scripts/detect.sh
./scripts/sandbox.sh create test-box
./scripts/sandbox.sh exec test-box echo hello
./scripts/sandbox.sh destroy test-box
```

Dry-run the sandbox config:

```bash
./scripts/setup-sandbox.sh personal --profile=default --show
```

## Style

- POSIX-compatible bash where possible
- `set -euo pipefail` in all scripts
- No external dependencies beyond docker/lima + standard unix tools
- `jq` required only for hooks and setup scripts
- Python3 used only for JSON parsing in audit.sh (available on all target systems)

## Architecture

Three tiers of defense, each independent:

1. **Tier 1: Native OS sandbox** — kernel-enforced via CC settings.json
2. **Tier 2: Container isolation** — instruction-based, agent runs sandbox.sh
3. **Tier 3: Pipelock** — optional prompt injection scanning

Profiles (*.conf files) are shared across Tier 1 (OS sandbox domain allowlist)
and Tier 2 (iptables inside container). One profile, two enforcement points.
