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

1. **Tiered defense** — works without Docker. Native OS sandbox (Seatbelt/
   bubblewrap) is the baseline; containers add full isolation on top.
2. **Enforce where possible, instruct where not** — Tier 1 (native sandbox)
   is kernel-enforced. Tier 2 (containers) is instruction-based. Audit trail
   closes the gap.
3. **Dumb containers** — `ubuntu:24.04` + `sleep infinity`. No init system,
   no supervisor. The agent drives everything via `docker exec`.
4. **Network allowlist** — iptables inside the container + OS-level domain
   allowlist on the host. Two layers, same profiles.
5. **Audit everything** — every command the wrapper runs is logged with
   timestamp, exit code, and truncated output. PostToolUse hooks capture
   commands that bypass the wrappers.
6. **Zero install** — pure bash + markdown. `git clone` and go. Docker/Lima
   are optional for Tier 2. Pipelock is optional for Tier 3.

## Architecture

```
User invokes Claude Code / Codex
  └── Skill auto-activates (SKILL.md loaded into context)
        │
        ├── Tier 1: Native OS sandbox (always, kernel-enforced)
        │   ├── setup-sandbox.sh → configures CC settings.json
        │   ├── Seatbelt (macOS) / bubblewrap (Linux)
        │   ├── Filesystem: writes restricted to project dir
        │   ├── Network: domain allowlist (same profiles as Tier 2)
        │   └── --dangerouslyDisableSandbox denied
        │
        ├── Tier 2: Container isolation (when Docker/Lima available)
        │   ├── detect.sh → identifies runtime
        │   ├── sandbox.sh create → ephemeral container + port exposure
        │   ├── sandbox.sh exec → all code runs inside container
        │   ├── harden.sh → iptables network allowlist
        │   └── sandbox.sh destroy → teardown on completion
        │
        ├── Tier 3: Prompt injection scanning (optional)
        │   └── Pipelock → scans fetched web content
        │
        └── Audit trail (all tiers)
            ├── audit.sh → script-level logging
            ├── hook-post-bash.sh → PostToolUse hook (all Bash commands)
            └── Agent self-reporting → decision reasoning
```

## Repo structure

```
sandshell/
├── SKILL.md                  # Claude Code skill (auto-invoked)
├── CLAUDE.md                 # Dev instructions for contributing
├── agents/
│   └── SANDSHELL.md          # Agent-agnostic instruction template
├── scripts/
│   ├── detect.sh             # Runtime + sandbox + hooks + pipelock detection
│   ├── install-agent.sh      # Install for claude/codex/gemini/amp
│   ├── setup.sh              # One-command setup for all protection layers
│   ├── setup-sandbox.sh      # Configure CC native OS sandbox
│   ├── setup-hooks.sh        # Configure PostToolUse audit hooks
│   ├── sandbox.sh            # Container lifecycle (create/exec/destroy)
│   ├── harden.sh             # Network hardening (iptables allowlist)
│   ├── audit.sh              # Audit trail logging
│   ├── hook-post-bash.sh     # PostToolUse hook script
│   └── install.sh            # Runtime & tool installer
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
| `create <name> [--runtime=X] [--mount=rw\|ro] [--ports=3000,5173]` | Spin up container, mount CWD, expose ports |
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

## Multi-agent support

sandshell supports four autonomous CLI agents. The scripts are universal —
what differs is how each agent discovers the instructions.

| Agent | Instruction format | Install method |
|-------|-------------------|---------------|
| Claude Code | `SKILL.md` with frontmatter + bang-blocks | Symlink to `.claude/skills/` |
| Codex CLI | `SKILL.md` with frontmatter (no bang-blocks) | Copy to `.codex/skills/` |
| Gemini CLI | `GEMINI.md` (plain markdown) | Append to `GEMINI.md` |
| Amp | `AGENTS.md` (plain markdown) | Append to `AGENTS.md` |

### Agent-specific differences

- **Claude Code**: Full support — SKILL.md with `${CLAUDE_SKILL_DIR}`,
  bang-blocks for auto-detection, PostToolUse hooks for audit
- **Codex CLI**: Has its own sandbox (Seatbelt/Seccomp) — sandshell adds
  container isolation + network hardening on top. No PostToolUse hooks.
- **Gemini CLI**: No hooks, no skill system. Instructions appended to
  `GEMINI.md`. Tier 1 limited to permission minimization (no CC sandbox
  config). Tier 2 (containers) works fully.
- **Amp**: No hooks, no sandbox. Instructions appended to `AGENTS.md`.
  Purely instruction-based — Tier 2 + audit trail.

### Template system

`agents/SANDSHELL.md` is the agent-agnostic template. `install-agent.sh`
renders it with the correct paths for each agent. Claude Code uses its
own `SKILL.md` directly (has features other agents don't support).

## Threat model

### What sandshell prevents

| Threat | How |
|--------|-----|
| Supply chain attacks (malicious packages) | Installs happen in ephemeral container; can't touch host |
| Blast radius from bugs | Broken code can't corrupt host filesystem |
| Network exfiltration | iptables allowlist blocks unauthorized outbound |
| Credential theft via code execution | No host credentials inside container |
| Persistent compromise | Container destroyed after task — nothing persists |

### What sandshell does NOT prevent (and mitigation)

| Threat | Why not | Mitigation |
|--------|---------|------------|
| Prompt injection from web content | Attack is in the context window, not code | Pipelock (optional) scans fetched content |
| Agent non-compliance | Instruction-based, not enforced | Audit trail detects non-compliance |
| Host-side tool abuse (git push, gh) | These must run on host | Agent logs all host commands with reason |
| Credential exfiltration via allowed domains | Agent has env vars, container has network | Network hardening limits where data can go |

### Defense tiers

| Tier | What | Enforcement | Requires |
|------|------|-------------|----------|
| 1 | Native OS sandbox | Kernel-level (Seatbelt/bubblewrap) | Nothing (built into OS) |
| 2 | Container isolation | Process-level (Docker/Lima) | Docker, Podman, or Lima |
| 3 | Prompt injection scanning | Content-level (Pipelock) | Pipelock (optional) |
| - | Audit trail | Hook + script logging | jq (for hooks) |

Tier 1 alone is meaningful protection. Each tier adds to the last.

Note: Container isolation (Tier 2) runs Linux — covers web, backend, CLI,
and infrastructure dev. macOS/Windows-native dev (Xcode, .NET desktop) is
not supported in containers but still benefits from Tier 1.

## What this is NOT

- **Not a full security boundary** — Tier 1 is kernel-enforced, but Tier 2
  is instruction-based. The audit trail is how you verify compliance.
- **Not a replacement for letai** — letai does multi-agent orchestration, issue
  tracking, and workflow automation. sandshell is one skill.
- **Not a Linux-only tool** — Tier 1 works on macOS and Linux natively.
  Tier 2 (containers) runs Linux workloads on any host OS.

## Launch plan

### v0.1 — MVP (target: this week)
- [x] detect.sh (runtime + native sandbox + hooks + pipelock detection)
- [x] sandbox.sh (create, exec, copy-in, copy-out, destroy, list, --ports)
- [x] harden.sh (domain allowlist, profiles)
- [x] audit.sh (init, log, show, summary with host breakdown)
- [x] install.sh (docker, lima, pipelock)
- [x] setup.sh (one-command setup for all tiers)
- [x] setup-sandbox.sh (CC native OS sandbox configuration)
- [x] setup-hooks.sh (PostToolUse audit hooks)
- [x] hook-post-bash.sh (Bash command capture + classification)
- [x] Network profiles (default, node, python, minimal)
- [x] SKILL.md (tiered auto-invoke, full behavioral contract)
- [x] README.md
- [ ] Manual testing with Claude Code
- [ ] Manual testing with Codex

### v0.2 — Harden
- [ ] Pipelock integration testing (fetch proxy mode)
- [ ] Audit summary reports (compliance score)
- [ ] Shell test suite
- [ ] CI with GitHub Actions

### v0.3 — Distribution
- [ ] GitHub repo public
- [ ] Published to skill catalogs
- [ ] Blog post / launch
- [ ] Community feedback loop
