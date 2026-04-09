# sandshell

Pure bash + markdown project. No build system, no compiled language.

## Structure

- `SKILL.md` — the skill definition (loaded by Claude Code / Codex)
- `scripts/` — bash scripts the skill invokes
- `profiles/` — network allowlist configs
- `examples/` — usage examples

## Testing

Run scripts directly:

```bash
./scripts/detect.sh
./scripts/sandbox.sh create test-box
./scripts/sandbox.sh exec test-box echo hello
./scripts/sandbox.sh destroy test-box
```

## Style

- POSIX-compatible bash where possible
- `set -euo pipefail` in all scripts
- No external dependencies beyond docker/lima + standard unix tools
- Python3 used only for JSON parsing (available on all target systems)
