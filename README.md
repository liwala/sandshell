# sandshell

Defense-in-depth for AI coding agents.

`0.1.0` is a Claude Code-first release built around the parts we can state
clearly and support directly:

- Claude Code
- macOS or Linux
- Native Claude sandbox configuration via `scripts/setup-sandbox.sh`
- Claude Bash guard + audit hooks via `scripts/setup-hooks.sh`
- Optional prompt-injection scanning via Pipelock

Codex CLI, Gemini CLI, and Amp are secondary instruction paths in this
release. sandshell can install guidance for them, but the setup, hook, and
verification path is Claude-specific.

## Claude vs Codex

Claude Code and Codex CLI have different safety models.

- Claude Code exposes configurable settings, permission rules, and native hook
  points. sandshell uses those surfaces to configure a native sandbox, add a
  Bash guard, and record an audit trail.
- Codex CLI exposes approval modes, including a built-in `--full-auto` mode
  documented as sandboxed, network-disabled, and scoped to the current
  directory. sandshell does not currently have the same native policy and hook
  surface to integrate with there.

In practice:

- Claude Code is the first-class sandshell path for configurable policy and
  audit hooks.
- Codex CLI support focuses on safe defaults, launch guidance, and installed
  instruction files rather than hook-level parity.

## Canonical install

```bash
# Clone the repo
git clone https://github.com/anthropics/sandshell ~/sandshell

# Install the Claude Code skill
~/sandshell/scripts/install-agent.sh claude

# Configure native sandbox + Bash hooks
~/sandshell/scripts/setup.sh personal --profile=default

# Verify what is active
~/sandshell/scripts/detect.sh
```

To roll back later:

```bash
~/sandshell/scripts/uninstall.sh personal
```

## Release status

Current release: `0.1.0`

- Changelog: [CHANGELOG.md](CHANGELOG.md)
- Security model: [SECURITY.md](SECURITY.md)
- Maintainer smoke test: `bash scripts/release-check.sh`

## What It Does

sandshell has three layers, with the native sandbox as the main security
boundary:

### 1. Native OS sandbox

Uses Claude Code's built-in sandbox backed by Seatbelt on macOS or bubblewrap
on Linux.

- Writes restricted to the project directory
- Network limited to the selected profile
- `--dangerouslyDisableSandbox` denied in Claude settings
- Optional `--strict` mode blocks reads to sensitive paths

This is the primary security boundary in `0.1.0`, and the rest of the release
is built around it.

### 2. Claude Bash guard + audit hooks

Claude `PreToolUse` and `PostToolUse` hooks add two host-side controls:

- The pre-hook blocks obvious sandbox-disabling Bash commands
- The post-hook logs Bash commands to `~/.sandshell/audit/<session>.jsonl`

The hooks are intentionally narrow. They are there to catch obvious attempts to
weaken protections and to leave a trail, not to replace the native sandbox with
a general command policy engine.

### 3. Optional prompt-injection scanning

If [Pipelock](https://github.com/luckyPipewrench/pipelock) is installed,
sandshell detects it and can instruct the agent to handle fetched content more
cautiously.

```bash
~/sandshell/scripts/install.sh pipelock
```

## Setup

### One command

```bash
~/.claude/skills/sandshell/scripts/setup.sh personal --profile=default
```

This configures:

1. Native OS sandbox
2. Claude Bash guard + audit hooks
3. Optional Pipelock detection

### Individual components

```bash
# Just the OS sandbox
setup-sandbox.sh personal --profile=node --strict

# Just the guard + audit hooks
setup-hooks.sh personal

# Optional prompt-injection scanner
install.sh pipelock
```

### Project-level setup

```bash
setup.sh project --profile=python
```

## Network Profiles

Profiles control which domains are reachable through the native sandbox.

| Profile | Domains | Typical use |
|---------|---------|-------------|
| `minimal` | None | Offline or maximum restriction |
| `default` | GitHub, npm, PyPI, Go proxy | General projects |
| `node` | Default + jsdelivr, unpkg, yarnpkg | Node projects |
| `python` | Default + conda, anaconda | Python projects |

## Audit Trail

When sandshell hooks are active, logged Bash commands end up in:

```bash
~/.sandshell/audit/<session-id>.jsonl
```

Helpers:

```bash
audit.sh show <session-id>
audit.sh summary <session-id>
```

The audit trail combines:

1. Script-level logging from `audit.sh`
2. Claude `PostToolUse` Bash logging
3. Optional agent self-reporting for notable host-vs-sandbox decisions

## Threat Model

### What sandshell meaningfully reduces

| Threat | How |
|--------|-----|
| Writes outside the repo | Native sandbox restricts filesystem writes |
| Network exfiltration to arbitrary hosts | Native sandbox restricts outbound hosts |
| Accidental sandbox disable flags | Claude settings deny `--dangerouslyDisableSandbox`; pre-hook catches obvious attempts |
| Reads to `~/.ssh`, `~/.aws`, `~/.kube` | `--strict` mode denies sensitive paths |
| Untracked host-side Bash activity | Post-hook audit log records Bash commands |

### What it does not solve on its own

| Threat | Why not |
|--------|---------|
| Full behavioral containment of the agent | sandshell is not an external orchestrator or separate runtime boundary |
| All prompt injection | Pipelock is optional and content scanning is best-effort |
| Non-Claude agent parity | Secondary agents do not get the same native hook/config path |

## Testing

```bash
bash tests/run.sh
bash scripts/release-check.sh
```

GitHub Actions runs the same release check on pushes and pull requests.

## Requirements

- macOS or Linux
- `bash`
- `jq` for setup/hooks/uninstall
- Python 3 for audit helpers
- Claude Code with Bash `PreToolUse` / `PostToolUse` hook support

## Secondary Agent Installs

```bash
~/sandshell/scripts/install-agent.sh codex
~/sandshell/scripts/install-agent.sh gemini
~/sandshell/scripts/install-agent.sh amp
~/sandshell/scripts/install-agent.sh all
```

## License

MIT
