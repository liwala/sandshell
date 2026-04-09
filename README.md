# sandshell

A Claude Code + Codex skill that makes AI coding agents execute all code in
disposable, network-hardened containers with a full audit trail.

## What it does

sandshell instructs your AI agent to:

1. **Sandbox all code execution** in an ephemeral Docker/Lima container
2. **Harden the network** to only allow domains the task needs
3. **Expose dev server ports** for web development (bound to localhost only)
4. **Log everything** to a JSONL audit trail for observability
5. **Minimize permissions** — read-only mounts, no dangerous flags
6. **Scan web content** for prompt injection (optional, via Pipelock)

## Install

```bash
# For all your projects (personal skill)
git clone https://github.com/anthropics/sandshell ~/.claude/skills/sandshell

# For one project only
git clone https://github.com/anthropics/sandshell .claude/skills/sandshell
```

## Requirements

- **Required:** Docker, Podman, or Lima
- **Optional:** [Pipelock](https://github.com/luckyPipewrench/pipelock) for prompt injection scanning

Don't have Docker or Lima? sandshell will detect this and offer to install:

```bash
# Install Docker
~/.claude/skills/sandshell/scripts/install.sh docker

# Or Lima (lighter, no daemon)
~/.claude/skills/sandshell/scripts/install.sh lima

# Optional: Pipelock for prompt injection scanning
~/.claude/skills/sandshell/scripts/install.sh pipelock

# Everything
~/.claude/skills/sandshell/scripts/install.sh all
```

## How it works

The skill auto-activates when your agent needs to write or run code.
It injects behavioral instructions that tell the agent to:

- Create a container before executing anything
- Run all builds, tests, and scripts inside the container
- Expose dev server ports for webdev projects (localhost only)
- Apply iptables-based network hardening
- Keep git/gh commands on the host (they need local credentials)
- Scan fetched web content for prompt injection (if Pipelock installed)
- Destroy the container when done

## Network profiles

| Profile | Domains allowed | Auto-selected when |
|---------|----------------|-------------------|
| `minimal` | None (DNS only) | Manual only |
| `default` | GitHub, npm, PyPI, Go proxy | `go.mod` or fallback |
| `node` | Default + jsdelivr, unpkg, yarnpkg | `package.json` |
| `python` | Default + conda, anaconda | `pyproject.toml`, `requirements.txt` |

## Port exposure

For web development, the agent auto-detects and exposes dev server ports:

| Framework | Ports |
|-----------|-------|
| Vite, Next.js, Remix, Rails | 3000, 5173 |
| Django | 8000 |
| Webpack, Go, Rust web | 8080 |

All ports bind to `127.0.0.1` only — never exposed to the network.

## Prompt injection scanning (optional)

If [Pipelock](https://github.com/luckyPipewrench/pipelock) is installed,
sandshell integrates with it to scan web content fetched by the agent.
Pipelock sits inline and scans for:

- Jailbreak phrases and instruction manipulation
- Zero-width character evasion
- Credential requests and data exfiltration attempts
- SSRF and DNS rebinding attacks

This is optional — sandshell works without Pipelock, but logs that web
content was not scanned.

## Audit trail

Every operation is logged to `~/.sandshell/audit/<session>.jsonl`:

```bash
# View the trail
./scripts/audit.sh show <session-id>

# Get stats
./scripts/audit.sh summary <session-id>
```

The summary includes a **sandbox ratio** — what percentage of commands ran
inside the sandbox vs on the host.

### Complete audit coverage with hooks

By default, the audit trail only captures commands that go through
`sandbox.sh`. To log *every* Bash command the agent runs (including direct
host commands), install the PostToolUse hook:

```bash
# For all your projects
~/.claude/skills/sandshell/scripts/setup-hooks.sh personal

# For this project only
~/.claude/skills/sandshell/scripts/setup-hooks.sh project
```

This gives you complete observability — every command classified as `git`,
`github_cli`, `container_mgmt`, `read_only`, or `unclassified`. The summary
highlights unclassified host commands that may have bypassed the sandbox.

Requires `jq` (`brew install jq` / `apt install jq`).

## Threat model

**sandshell prevents:** supply chain attacks, blast radius from bugs,
network exfiltration, credential theft via code execution, persistent
compromise.

**sandshell does NOT prevent:** prompt injection from web content (use
Pipelock for this), agent non-compliance (audit trail detects it), host-side
tool abuse (git/gh must run on host).

See [PLAN.md](PLAN.md) for the full threat model breakdown.

## Important

sandshell is **defense-in-depth**, not a security boundary. It instructs the
agent to sandbox itself — the agent follows these instructions with high
reliability but not with certainty. The audit trail is how you verify
compliance.

## License

MIT
