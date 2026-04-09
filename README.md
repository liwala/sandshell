# sandshell

Defense-in-depth for AI coding agents. A Claude Code + Codex skill that
protects your machine with tiered security — from kernel-enforced OS sandbox
to disposable containers to prompt injection scanning.

## Quick start

```bash
# Install the skill (for all your projects)
git clone https://github.com/anthropics/sandshell ~/.claude/skills/sandshell

# One-command setup for all protection layers
~/.claude/skills/sandshell/scripts/setup.sh personal
```

That's it. Restart Claude Code and sandshell auto-activates.

## How it works

sandshell operates in three tiers. Each tier adds protection, but lower tiers
work on their own — you don't need Docker to benefit.

### Tier 1: Native OS sandbox (kernel-enforced)

Uses Claude Code's built-in sandbox backed by **Seatbelt** (macOS) or
**bubblewrap** (Linux). This is enforced by the OS kernel — the agent
**cannot** bypass it, even if prompt-injected.

- Filesystem writes restricted to the project directory
- Network limited to allowed domains (same profiles as Tier 2)
- `--dangerouslyDisableSandbox` denied at the settings level
- Optional `--strict` mode blocks reads to `~/.ssh`, `~/.aws`, `~/.kube`, etc.

```bash
# Configure with the default network profile
setup-sandbox.sh personal --profile=default

# Strict mode: also deny reads to sensitive directories
setup-sandbox.sh personal --profile=node --strict
```

**No Docker required. Works on any macOS or Linux machine.**

### Tier 2: Container isolation (ephemeral sandboxes)

When Docker, Podman, or Lima is available, sandshell instructs the agent to
run all code in a disposable container (`ubuntu:24.04` + `sleep infinity`).

- Ephemeral filesystem — destroyed after the task
- No host credentials inside the container
- Read-only workspace mount by default
- iptables-based network hardening inside the container
- Dev server ports exposed to localhost for web development

```bash
# The agent does this automatically:
sandbox.sh create sandshell-abc123 --ports=3000,5173
sandbox.sh exec sandshell-abc123 npm install
sandbox.sh exec sandshell-abc123 npm test
harden.sh sandshell-abc123 --profile=node
sandbox.sh destroy sandshell-abc123
```

**Note:** Containers run Linux. This covers web, backend, CLI, and
infrastructure development. macOS/Windows-native dev (Xcode, .NET desktop)
is not supported in containers but still benefits from Tier 1.

### Tier 3: Prompt injection scanning (optional)

If [Pipelock](https://github.com/luckyPipewrench/pipelock) is installed,
sandshell integrates with it to scan web content fetched by the agent.

- Jailbreak phrase detection
- Zero-width character evasion
- Credential request patterns
- SSRF and DNS rebinding protection

```bash
# Install Pipelock
install.sh pipelock
```

## Setup

### One command (recommended)

```bash
~/.claude/skills/sandshell/scripts/setup.sh personal --profile=default
```

This configures:
1. Native OS sandbox (Tier 1)
2. PostToolUse audit hooks
3. Checks for Docker/Lima
4. Checks for Pipelock

### Individual components

```bash
# Just the OS sandbox
setup-sandbox.sh personal --profile=node --strict

# Just the audit hooks
setup-hooks.sh personal

# Install a container runtime
install.sh docker    # or: lima, pipelock, all
```

### Project-level setup

```bash
# Configure for this project only (committed to .claude/settings.json)
setup.sh project --profile=python
```

## Network profiles

Profiles control which domains are reachable, used by both the native
sandbox (Tier 1) and container hardening (Tier 2).

| Profile | Domains | Auto-selected when |
|---------|---------|-------------------|
| `minimal` | None (DNS only) | Manual only |
| `default` | GitHub, npm, PyPI, Go proxy | `go.mod` or fallback |
| `node` | Default + jsdelivr, unpkg, yarnpkg | `package.json` |
| `python` | Default + conda, anaconda | `pyproject.toml`, `requirements.txt` |

## Port exposure

For web development, the agent auto-detects and exposes dev server ports.
All ports bind to `127.0.0.1` — never exposed to the network.

| Framework | Ports |
|-----------|-------|
| Vite, Next.js, Remix, Rails | 3000, 5173 |
| Django | 8000 |
| Webpack, Go, Rust web | 8080 |

## Audit trail

Every operation is logged to `~/.sandshell/audit/<session>.jsonl`.

```bash
# View the trail
audit.sh show <session-id>

# Get stats
audit.sh summary <session-id>
```

Three layers of logging:

1. **Script-level** — `sandbox.sh` and `harden.sh` log automatically
   (ground truth, independent of agent behavior)
2. **PostToolUse hooks** — captures every Bash command the agent runs on the
   host, classified as `git`, `github_cli`, `container_mgmt`, `read_only`,
   or `unclassified`
3. **Agent self-reporting** — the skill instructs the agent to log its
   reasoning for host-vs-sandbox decisions

The summary shows a **sandbox ratio** and flags unclassified host commands
that may have bypassed the sandbox.

### Hook setup

```bash
# For all your projects
setup-hooks.sh personal

# For this project only
setup-hooks.sh project
```

Requires `jq` (`brew install jq` / `apt install jq`).

## Threat model

### What sandshell prevents

| Threat | How | Tier |
|--------|-----|------|
| Writes outside project dir | OS sandbox restricts filesystem | 1 |
| Network exfiltration from host | OS sandbox domain allowlist | 1 |
| `--dangerouslyDisableSandbox` bypass | Denied in settings.json | 1 |
| Reads to `~/.ssh`, `~/.aws` | `--strict` mode denies sensitive paths | 1 |
| Supply chain attacks (malicious packages) | Installs in ephemeral container | 2 |
| Credential theft via code execution | No host credentials in container | 2 |
| Blast radius from bugs | Container filesystem is disposable | 2 |
| Network exfiltration from code | iptables allowlist inside container | 2 |
| Prompt injection from web content | Pipelock scans fetched content | 3 |

### What sandshell does NOT prevent

| Threat | Why not | Mitigation |
|--------|---------|------------|
| Agent ignoring container instructions | Tier 2 is instruction-based | Audit trail detects non-compliance |
| Host-side git/gh abuse | These must run on host | Hooks log all host commands |
| Read access to project files | Agent needs to read code | `--strict` mode limits sensitive dirs |

### Key insight

Tier 1 is **enforced**. Tier 2 is **instructed**. The audit trail bridges
the gap — you can verify whether the agent actually followed the instructions.

## Requirements

- **Tier 1:** Nothing — macOS has Seatbelt built-in, Linux needs `bubblewrap`
- **Tier 2:** Docker, Podman, or Lima
- **Tier 3:** [Pipelock](https://github.com/luckyPipewrench/pipelock)
- **Hooks:** `jq`

## Install

```bash
# The skill itself
git clone https://github.com/anthropics/sandshell ~/.claude/skills/sandshell

# Container runtime (if you don't have one)
~/.claude/skills/sandshell/scripts/install.sh docker   # or: lima

# Pipelock (optional)
~/.claude/skills/sandshell/scripts/install.sh pipelock

# Everything
~/.claude/skills/sandshell/scripts/install.sh all
```

## License

MIT
