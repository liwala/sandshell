# sandshell — Skill Plan

## What

A Claude Code + Codex skill that makes AI coding agents execute all code in
disposable, network-hardened containers. Ships as a git repo you clone into
`~/.claude/skills/sandshell/`.

## Why

Provisioning and auth are hard. Instead of an orchestrator managing the sandbox
from outside, sandshell tells the agent to sandbox *itself*. The agent uses its
own auth, spins up a dumb container, hardens the network, and logs everything
it does. No daemon, no RPC bridge, no credential forwarding.

## Design principles

1. **Instruct, don't enforce** — sandshell is defense-in-depth via agent
   instruction, not a security boundary. The audit trail closes the gap.
2. **Dumb containers** — `ubuntu:24.04` + `sleep infinity`. No init system,
   no supervisor. The agent drives everything via `docker exec`.
3. **Network allowlist** — iptables inside the container, domain-based.
   Only the domains the task needs are reachable.
4. **Audit everything** — every command the wrapper runs is logged with
   timestamp, exit code, and truncated output. Independent of agent self-report.
5. **Zero install** — pure bash + markdown. `git clone` and go.

## Architecture

```
User invokes Claude Code / Codex
  └── Skill auto-activates (SKILL.md loaded into context)
        ├── detect.sh → identifies runtime (docker / podman / lima)
        ├── sandbox.sh create → spins up ephemeral container
        ├── sandbox.sh exec → all code runs inside container
        ├── harden.sh → applies network allowlist
        ├── audit.sh → logs all operations to audit trail
        └── sandbox.sh destroy → tears down on completion
```

## Repo structure

```
sandshell/
├── SKILL.md                  # Main skill instructions (auto-invoked)
├── CLAUDE.md                 # Dev instructions for contributing
├── scripts/
│   ├── detect.sh             # Runtime detection (docker/podman/lima)
│   ├── sandbox.sh            # Container lifecycle (create/exec/destroy)
│   ├── harden.sh             # Network hardening (iptables allowlist)
│   └── audit.sh              # Audit trail logging
├── profiles/
│   ├── default.conf          # Default network profile (github, npm, pypi)
│   ├── node.conf             # Node.js project allowlist
│   ├── python.conf           # Python project allowlist
│   └── minimal.conf          # DNS-only (maximum restriction)
├── examples/
│   └── workflow.md           # Example sandboxed session
├── tests/
│   ├── test_detect.sh        # Detection tests
│   ├── test_sandbox.sh       # Lifecycle tests
│   └── test_harden.sh        # Network hardening tests
├── LICENSE
└── README.md
```

## SKILL.md behavior

### Auto-invocation

The skill activates automatically for any task that involves writing or
executing code. Frontmatter:

```yaml
---
name: sandshell
description: >
  Execute all code in a disposable, network-hardened container.
  Auto-activates when the task involves writing or running code.
  Provides audit trail of all operations.
---
```

### Phase 1: Environment detection (on load)

Shell injection runs `detect.sh` before the agent sees the prompt:

```
Available runtime: !`${CLAUDE_SKILL_DIR}/scripts/detect.sh`
```

This gives the agent: runtime name, version, and whether lima is available
as fallback.

### Phase 2: Behavioral contract

The skill instructs the agent to:

1. **Create a sandbox** before writing any code
   - `sandbox.sh create <name> [--runtime=docker|lima]`
   - Mount CWD read-only by default, read-write only if the task requires output files
   - Name derived from task/session ID

2. **Execute all commands inside the sandbox**
   - `sandbox.sh exec <name> <command>`
   - Never run code on the host directly
   - If a command must run on the host (git push, gh pr), use the host
     shell but log it explicitly

3. **Apply network hardening**
   - `harden.sh <name> --profile=default`
   - Or `harden.sh <name> --allow=github.com,registry.npmjs.org`
   - Agent selects profile based on detected project type

4. **Minimize host permissions**
   - No `--dangerouslyDisableSandbox`
   - No writes outside project directory
   - Prefer Read over cat, Edit over sed (Claude Code native tools)

5. **Destroy on completion**
   - `sandbox.sh destroy <name>`
   - Audit log persists after container is gone

### Phase 3: Audit trail

Every `sandbox.sh` and `harden.sh` invocation appends to:
`~/.sandshell/audit/<session-id>.jsonl`

Each line:
```json
{
  "ts": "2026-04-09T14:32:01Z",
  "op": "exec",
  "container": "sandshell-abc123",
  "cmd": "npm test",
  "exit_code": 0,
  "duration_ms": 3420,
  "stdout_lines": 12,
  "stderr_lines": 0
}
```

The skill also instructs the agent to log its own reasoning about
host-vs-container decisions, appended as `"op": "decision"` entries.

## Scripts — detailed design

### detect.sh

Outputs a machine-readable summary:

```
runtime=docker
runtime_version=24.0.7
lima_available=true
lima_version=1.0.1
os=darwin
arch=arm64
```

Detection order: docker → podman → lima (as container fallback).
If nothing found, outputs `runtime=none` and the skill instructs the
agent to warn the user and offer to install docker.

### sandbox.sh

Subcommands:

| Command | What it does |
|---------|-------------|
| `create <name> [--runtime=X] [--mount=rw\|ro]` | Spin up container, mount CWD |
| `exec <name> <cmd...>` | Run command inside container |
| `copy-in <name> <src> <dest>` | Copy file into container |
| `copy-out <name> <src> <dest>` | Copy file out of container |
| `status <name>` | Check if container is running |
| `destroy <name>` | Remove container + cleanup |
| `list` | List active sandshell containers |

Docker implementation:
- `create`: `docker run -d --name <name> --entrypoint sleep -v $(pwd):/workspace:ro ubuntu:24.04 infinity`
- `exec`: `docker exec <name> <cmd>`
- `destroy`: `docker rm -f <name>`

Lima implementation:
- `create`: `limactl create --name=<name> --plain` with minimal YAML
- `exec`: `limactl shell <name> <cmd>`
- `destroy`: `limactl delete --force <name>`

All subcommands call `audit.sh log` before and after execution.

### harden.sh

```
harden.sh <container> --profile=<name>
harden.sh <container> --allow=domain1,domain2 [--ports=443,22]
```

Inside the container, it:
1. Installs iptables (if not present)
2. Flushes OUTPUT chain
3. Allows loopback + established + DNS
4. Resolves each allowed domain via `dig +short`
5. Adds per-IP rules for allowed ports
6. Drops everything else
7. Saves rules

Profiles are simple conf files:
```
# default.conf
github.com
api.github.com
registry.npmjs.org
pypi.org
files.pythonhosted.org
proxy.golang.org
```

### audit.sh

```
audit.sh init <session-id>        # Create audit file
audit.sh log <session-id> <json>  # Append entry
audit.sh show <session-id>        # Pretty-print audit trail
audit.sh summary <session-id>     # Stats (commands run, host vs container)
```

Storage: `~/.sandshell/audit/<session-id>.jsonl`

Retention: keeps last 50 sessions by default. Configurable via
`~/.sandshell/config`.

## Network profiles

| Profile | Domains | Use case |
|---------|---------|----------|
| `minimal` | (none, DNS only) | Maximum lockdown, offline work |
| `default` | github.com, npmjs.org, pypi.org, proxy.golang.org | General dev |
| `node` | default + cdn.jsdelivr.net, unpkg.com | Node.js projects |
| `python` | default + files.pythonhosted.org, conda.anaconda.org | Python projects |

The agent auto-selects based on project detection (package.json → node,
pyproject.toml → python, go.mod → default, etc).

## Codex compatibility

Same SKILL.md works for both Claude Code and Codex since they share the
skill format. Behavioral differences:

- Codex already sandboxes by default → sandshell adds network hardening
  and audit trail on top
- Claude Code needs explicit container creation → sandshell handles this

The skill detects which agent it's running under via environment variables
and adjusts instructions accordingly.

## What this is NOT

- **Not a security boundary** — defense-in-depth via instruction, not enforcement
- **Not a replacement for letai** — letai does multi-agent orchestration, issue
  tracking, and workflow automation. sandshell is one skill.
- **Not deterministic** — the agent follows instructions probabilistically.
  The audit trail is how you verify compliance.

## Launch plan

### v0.1 — MVP (target: this week)
- [ ] detect.sh (docker + lima)
- [ ] sandbox.sh (create, exec, destroy)
- [ ] harden.sh (domain allowlist, default profile)
- [ ] audit.sh (init, log, show)
- [ ] SKILL.md (auto-invoke, full behavioral contract)
- [ ] README.md
- [ ] Manual testing with Claude Code

### v0.2 — Polish
- [ ] Network profiles (node, python, minimal)
- [ ] `sandbox.sh copy-in/copy-out`
- [ ] Audit summary + retention
- [ ] Codex-specific testing
- [ ] Shell test suite

### v0.3 — Distribution
- [ ] Published to skill catalogs
- [ ] Blog post / launch
- [ ] Community feedback loop
