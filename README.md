# sandshell

A Claude Code + Codex skill that makes AI coding agents execute all code in
disposable, network-hardened containers with a full audit trail.

## What it does

sandshell instructs your AI agent to:

1. **Sandbox all code execution** in an ephemeral Docker/Lima container
2. **Harden the network** to only allow domains the task needs
3. **Log everything** to a JSONL audit trail for observability
4. **Minimize permissions** — read-only mounts, no dangerous flags

## Install

```bash
# For all your projects (personal skill)
git clone https://github.com/anthropics/sandshell ~/.claude/skills/sandshell

# For one project only
git clone https://github.com/anthropics/sandshell .claude/skills/sandshell
```

## Requirements

- Docker, Podman, or Lima installed
- Claude Code or Codex CLI

## How it works

The skill auto-activates when your agent needs to write or run code.
It injects behavioral instructions that tell the agent to:

- Create a container before executing anything
- Run all builds, tests, and scripts inside the container
- Apply iptables-based network hardening
- Keep git/gh commands on the host (they need local credentials)
- Destroy the container when done

## Network profiles

| Profile | Domains allowed | Use case |
|---------|----------------|----------|
| `minimal` | None (DNS only) | Maximum lockdown |
| `default` | GitHub, npm, PyPI, Go proxy | General development |
| `node` | Default + jsdelivr, unpkg, yarnpkg | Node.js projects |
| `python` | Default + conda, anaconda | Python projects |

The agent auto-selects based on your project files.

## Audit trail

Every operation is logged to `~/.sandshell/audit/<session>.jsonl`:

```bash
# View the trail
./scripts/audit.sh show <session-id>

# Get stats
./scripts/audit.sh summary <session-id>
```

## Important

sandshell is **defense-in-depth**, not a security boundary. It instructs the
agent to sandbox itself — the agent follows these instructions with high
reliability but not with certainty. The audit trail is how you verify
compliance.

## License

MIT
