# sandshell

Safe defaults for AI coding agents — across agents, in one command.

Sandshell audits the safety configs of the coding agents you have installed
(Claude Code, Codex CLI, Gemini CLI), reports what's risky, and applies safe
defaults to each. It's the executable companion to the threat-model
decisions you'd otherwise make by hand for each agent.

**Sandshell is not a runtime sandbox.** It configures the sandbox primitives
your agent already has (Claude Code's native sandbox, Codex's Seatbelt
policy, Gemini's `tools.sandbox`) and tracks how those configs change over
time. For *runtime* isolation of unvetted code, reach for a microVM tool
like Docker `sbx`. Sandshell is the layer below that — making sure the
sandbox you do have is turned on, narrow, and stays that way.

## Verbs

| Verb            | What it does                                                                                          |
|-----------------|-------------------------------------------------------------------------------------------------------|
| `detect`        | Report host **inventory**: OS, dependencies, native sandbox primitive, agents installed              |
| `audit`         | Report **safety findings** by severity. `--summary` for per-agent rollup, `--json` for machine-readable |
| `install-agent` | Install sandshell skill / instruction docs into detected agents. One-time, idempotent                |
| `apply`         | Write safe-default configs to detected agents (Claude Code, Codex CLI, Gemini CLI)                   |
| `drift`         | Show what changed since the last apply / snapshot                                                    |
| `verify`        | Re-run audit; exit 2 on findings ≥ medium (for CI / pre-commit)                                      |

`detect` answers *"what do I have?"*; `audit` answers *"is it safe?"*; `drift`
answers *"did anything change since last time?"*. Use them together — `detect`
once at install, `audit` whenever you want a safety review, `drift` whenever
you want to spot config that's regressed since you last applied.

## Quick start

```bash
# 1. Clone the repo. ~/sandshell is a convenient default; sandshell computes
#    paths from its own location, so anywhere on disk works.
git clone https://github.com/liwala/sandshell ~/sandshell

# 2. (Optional but recommended) put sandshell on $PATH so you can drop
#    the ~/sandshell/bin/ prefix in the commands below.
echo 'export PATH="$HOME/sandshell/bin:$PATH"' >> ~/.zshrc   # or ~/.bashrc
exec $SHELL

# 3. Inventory: what does sandshell see on your machine?
sandshell detect

# 4. Audit your current state — the "before" snapshot. Likely surfaces missing
#    sandbox enablement, missing hooks, and per-agent configuration gaps.
sandshell audit

# 5. Install agent guidance (skill for Claude Code, instruction docs for the
#    others). One-time setup; idempotent.
sandshell install-agent all

# 6. Apply safe-default configs to every detected agent (sandbox + hooks for
#    Claude; safe TOML for Codex; safe JSON for Gemini).
sandshell apply

# 7. Confirm the issues from step 4 are resolved. Should be 0 actionable findings.
sandshell audit --summary

# Later, in a future session: see what's changed since you last applied.
sandshell drift
```

In CI / pre-commit, use `verify` (exits 2 on findings ≥ medium):

```bash
sandshell verify --json
```

For project-specific safe defaults (committed to git, applied to your team
when they clone the repo):

```bash
cd ~/myproject
sandshell apply project --profile=default       # Claude Code
sandshell apply gemini project                   # Gemini CLI
git add .claude/settings.json .gemini/settings.json
git commit -m "Add sandshell safe defaults"
```

Codex doesn't expose a project scope; its settings are user-level only.

## Example audit output

```
sandshell audit — 2026-04-29T15:32:14Z

CRITICAL (1)
  cc.sandbox.enabled
    Claude Code sandbox is not enabled in any settings scope
    fix:   sandshell apply --profile=default

HIGH (2)
  host.shell_alias_bypass
    Alias 'claude' includes bypass flag '--dangerously-skip-permissions'
    scope: ~/.zshrc:42
    fix:   Remove '--dangerously-skip-permissions' from the alias in ~/.zshrc
  host.long_lived_creds
    Long-lived credential persisted in shell rc: AWS_ACCESS_KEY_ID
    scope: ~/.zshrc:18
    fix:   Use short-lived tokens (STS, SSO, gh auth login)

MEDIUM (1)
  cc.hooks.pre_bash
    Claude Code PreToolUse Bash guard hook is not configured
    fix:   sandshell apply

3 actionable findings (severity >= medium).

Drift since 2026-04-23T11:08:02Z: +1 new / -0 resolved
  + cc.hooks.pre_bash  (medium)  Claude Code PreToolUse Bash guard hook is not configured
```

The drift footer compares the current state against the baseline captured at
your last `sandshell apply` (or last manual `sandshell audit --snapshot`).
Resolved findings show as `-`; new findings (regressions) show as `+`.

## What audit checks

Per-agent adapters live in `agents/<name>/audit.sh`. Each reads the agent's
real configuration files and emits findings. Coverage at a glance:

| Adapter      | Surface                                                                                                                                            |
|--------------|----------------------------------------------------------------------------------------------------------------------------------------------------|
| `host`       | Cross-agent: bypass aliases (`--dangerously-skip-permissions`, `--full-auto`, `--yolo`), bypass env vars, long-lived creds, missing native sandbox primitive, non-git cwd, unknown repo provenance |
| `claude`     | Sandbox enabled (and the silent-disable trap), write/network scope, dangerouslyDisableSandbox deny entry, wildcard Bash permissions, curl-pipe-shell patterns, PreToolUse/PostToolUse hooks, MCP curation against your allowlist, project auto-approve |
| `codex`      | `sandbox_mode != danger-full-access`, `approval_policy != never`, no broad `writable_roots`, no `trust_level = "trusted"` for `~`/`/`, network-access in workspace mode |
| `gemini`     | `tools.sandbox` configured, `sandboxNetworkAccess`, `security.folderTrust.enabled`, `security.disableYoloMode`, approval mode, broad entries in `trustedFolders.json` |

Adapters self-skip when their agent isn't installed.

## What `apply` configures

`sandshell apply` writes safe defaults for every detected agent. Each agent's
config is independent — `apply` is idempotent, and you can target a single
agent (`apply codex`) or all of them (`apply` / `apply all`).

| Agent       | What `apply` writes                                                                                    | macOS enforcement today                                                |
|-------------|--------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------|
| Claude Code | Native sandbox + Bash PreToolUse/PostToolUse hooks + skill                                             | Filesystem ✓.  Network ✗ (upstream [#37970](https://github.com/anthropics/claude-code/issues/37970)) |
| Codex CLI   | `~/.codex/config.toml`: `sandbox_mode=workspace-write`, `network_access=false`, `approval_policy=on-request` | Filesystem ✓.  Network ✓ (kernel-enforced via Seatbelt MAC)             |
| Gemini CLI  | `~/.gemini/settings.json`: `tools.sandbox=sandbox-exec`, folder trust on, YOLO/always-allow off        | Filesystem ✓.  Network ✗ under sandbox-exec ([#20381](https://github.com/google-gemini/gemini-cli/issues/20381)); ✓ under `tools.sandbox=docker` |

See [KNOWN_ISSUES.md](KNOWN_ISSUES.md) for upstream bugs that limit network
enforcement on Claude Code and Gemini today. Sandshell writes
forward-correct config so users get the benefit automatically when those
fixes land.

For Claude Code, `apply` configures three layers:

1. **Native OS sandbox** (Seatbelt on macOS, bubblewrap on Linux) — the main
   security boundary. Restricts writes to the project + `$TMPDIR`, network to a
   profile-controlled allowlist, and denies `--dangerouslyDisableSandbox`.
2. **PreToolUse + PostToolUse Bash hooks** — narrow guards that block obvious
   sandbox-disable attempts and write a session JSONL audit trail to
   `~/.sandshell/audit/`.
3. **The Claude Code skill** — instructs the agent to treat fetched content as
   untrusted input and surface suspicious instructions before acting.

```bash
# User scope (applies across all projects on this machine)
~/sandshell/bin/sandshell apply user --profile=default

# Project scope (just this repo; gets committed to git)
~/sandshell/bin/sandshell apply project --profile=python

# Strict mode also denies reads to ~/.ssh, ~/.aws, ~/.gnupg, etc.
~/sandshell/bin/sandshell apply user --profile=default --strict
```

To roll back:

```bash
~/sandshell/scripts/uninstall.sh user
```

## Network profiles

Profiles control which hosts the sandbox permits.

| Profile   | Hosts                                              | Typical use         |
|-----------|----------------------------------------------------|---------------------|
| `default` | GitHub, npm, PyPI, Go proxy                        | General projects    |
| `node`    | Default + jsdelivr, unpkg, yarnpkg                 | Node projects       |
| `python`  | Default + conda, anaconda                          | Python projects     |

## Audit trail

`apply` wires Claude's PostToolUse Bash hook to log every command into:

```bash
~/.sandshell/audit/<session-id>.jsonl
```

Helpers:

```bash
sandshell trail list                    # enumerate logged sessions, most recent first
sandshell trail show <session-id>       # display every Bash command in a session
sandshell trail summary <session-id>    # roll-up classification of a session
```

(Or call `~/sandshell/scripts/audit-trail.sh ...` directly if you prefer.)

This is *retrospective* data, separate from `sandshell audit` (which is
*pre-flight* config audit). Both are useful; they answer different questions.

## Drift detection

Every `sandshell apply` captures the post-apply audit state as a baseline at
`~/.sandshell/baselines/current.json`, plus a timestamped historical copy at
`~/.sandshell/baselines/audit-<timestamp>.json`. Subsequent `sandshell audit`
runs compare against that baseline and report what's new or resolved:

```
$ sandshell drift
Drift since 2026-04-29T15:32:14Z: +1 new / -2 resolved
  + cc.permissions.wildcard_bash  (high)    Wildcard "Bash(*)" present in permissions.allow
  - cc.sandbox.enabled            (critical)  Claude Code sandbox is not enabled  — resolved
  - host.shell_alias_bypass       (high)    Alias 'claude' includes bypass flag    — resolved
```

This is the answer to *"did anything change since I last applied?"* — useful
at session start, in pre-commit hooks, or whenever you want to spot quiet
config regressions (a teammate's settings update, an agent self-modifying its
own config, an out-of-band edit). Historical snapshots accumulate as a
config-state audit trail that pairs with the Bash command audit trail above.

```bash
sandshell drift                       # show only the diff (no full findings list)
sandshell audit                       # full findings + drift footer
sandshell audit --snapshot --no-drift # capture a baseline manually
sandshell audit --no-drift            # suppress drift output (e.g. in CI)
```

## Why not just rely on the agent's permission prompts?

Agents already prompt before commands — Claude Code, Codex, Gemini, all of
them. Sandshell sits one level up: it makes sure the *config the prompts run
inside* is safe, narrow, and doesn't drift. Three things this solves that the
prompts can't:

- **One taxonomy across agents.** Different UIs and bypasses across Claude /
  Codex / Gemini mean a user switching agents loses any safety habit. Audit
  reports them in one format.
- **Catches the silent-disable failure mode.** A `sandbox.enabled=false`
  setting, a bypass alias, a `--dangerously-skip-permissions` shell flag —
  none of these fire a runtime prompt; sandshell fires before the session.
- **Surfaces drift between sessions.** When a setting regresses (teammate
  edit, agent self-modification, out-of-band change), the next `audit`
  flags it explicitly instead of letting it silently weaken your defaults.

## Threat model

### What sandshell meaningfully reduces

| Threat                                       | How                                                                                                |
|----------------------------------------------|----------------------------------------------------------------------------------------------------|
| Misconfigured sandbox / silent disable        | `audit` flags missing or disabled sandbox; `apply` writes correct config                          |
| Bypass flags persisted in shell aliases       | `audit` parses shell rc files for `--dangerously-skip-permissions`, `--full-auto`, `--yolo`, etc. |
| Wildcard Bash permissions                    | `audit` flags `Bash`, `Bash(*)`, and curl-pipe-shell patterns                                     |
| Untrusted MCP servers                        | `audit` cross-references your MCP config against `~/.sandshell/known-mcps.json`                   |
| Long-lived credentials in agent's environment | `audit` flags persistent credential exports; `apply --strict` adds read-deny for credential paths |
| Untracked host-side Bash activity            | PostToolUse hook records every command for retrospective review                                   |
| Filesystem writes outside the repo            | Native sandbox enforces filesystem bounds (Seatbelt on macOS, bubblewrap on Linux)                |

### What it does not solve on its own

| Threat                                | Why not                                                                                                              |
|---------------------------------------|----------------------------------------------------------------------------------------------------------------------|
| **Network exfiltration on macOS** (today, varies by agent) | **Codex** enforces network at kernel level via Seatbelt MAC — `apply codex` actually delivers. **Claude Code** has open bug [#37970](https://github.com/anthropics/claude-code/issues/37970) — `allowedDomains` doesn't enforce for Bash subprocesses today. **Gemini** under `sandbox-exec` silently ignores `sandboxNetworkAccess` (architectural, not a bug); enforces under `tools.sandbox = "docker"`. See [KNOWN_ISSUES.md](KNOWN_ISSUES.md) for full picture. |
| Untrusted code execution at runtime    | Sandshell configures sandboxes; for unvetted dependencies or unknown repos, escalate to a microVM tool like Docker `sbx` |
| Prompt injection                      | Sandshell limits the *blast radius* of an injected agent (via the sandbox), not the injection itself                  |
| Real-time alerting / live monitoring  | Sandshell is a config linter, not a daemon                                                                           |

## Status

Pre-release: v0.2 work in progress. v0.1 was Claude-only; v0.2 adds the
cross-agent audit, the `bin/sandshell` CLI, and per-agent adapters for Codex
and Gemini.

- Changelog: [CHANGELOG.md](CHANGELOG.md)
- Security model: [SECURITY.md](SECURITY.md)
- Design notes: [NOTES.md](NOTES.md)
- Maintainer smoke test: `bash scripts/release-check.sh`

## Testing

```bash
bash tests/run.sh
bash scripts/release-check.sh
```

GitHub Actions runs the same release check on pushes and pull requests.

## Requirements

- macOS or Linux
- `bash`, `python3`, `jq` (Codex audit additionally requires Python 3.11+ for `tomllib`)
- For the full Claude Code path: Claude Code with Bash `PreToolUse`/`PostToolUse` hook support
- For the Linux native sandbox: `bubblewrap` (`apt install bubblewrap`)

`sandshell detect` reports the status of each requirement.

## Per-agent installs (skill / instruction docs)

```bash
~/sandshell/scripts/install-agent.sh claude     # Claude Code skill
~/sandshell/scripts/install-agent.sh codex      # Codex CLI guidance
~/sandshell/scripts/install-agent.sh gemini     # Gemini CLI guidance
~/sandshell/scripts/install-agent.sh generic project   # Generic SANDSHELL.md in cwd
~/sandshell/scripts/install-agent.sh all
```

## License

MIT
