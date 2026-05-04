# sandshell

Safe defaults for AI coding agents — across agents, in one command.

Sandshell audits the safety configs of the coding agents you have installed
(Claude Code, Codex CLI, Gemini CLI), reports what's risky, and applies safe
defaults for the ones that support them. It's the executable companion to
the threat-model decisions you'd otherwise make by hand for each agent.

## Why not just use the agent's permission prompts?

Coding agents already prompt before running commands — Claude Code does, Codex
does, every agent does. So why add another layer? Permission systems share
three structural limits:

- **They're per-agent.** Claude's system, Codex's modes, Gemini's
  confirmations — different UIs, different defaults, different bypasses. A
  user switching agents loses any safety habit. Sandshell is one taxonomy
  across all of them.
- **They classify by syscall, not intent.** They can't tell "fresh clone of
  an unknown repo" from "edit in your own repo." Sandshell uses provenance,
  command shape, and context — the things that *make* something risky.
- **They prompt on every action.** A wall that fires on everything is a wall
  users learn to walk through. A wall that fires only when it matters is a
  wall users read.

Sandshell sits one level up from the permission prompt: it triages the *risk
tier* of your current configuration and tells you which settings are unsafe,
which are missing, and what to do about each.

## Verbs

| Verb     | What it does                                                                              |
|----------|-------------------------------------------------------------------------------------------|
| `detect` | Report host **inventory**: OS, dependencies, native sandbox primitive, agents installed   |
| `audit`  | Report **safety findings** by severity. `--summary` for per-agent rollup, `--json` for machine-readable |
| `apply`  | Apply safe defaults to detected agents (Claude Code today)                                |
| `verify` | Re-run audit; exit 2 on findings ≥ medium (for CI / pre-commit)                          |

`detect` answers *"what do I have?"*; `audit` answers *"is it safe?"*. Use both
together — `detect` once at install, `audit` whenever you want a safety review.

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

3 actionable findings (severity >= medium). --json for machine-readable output.
```

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

`sandshell apply` writes safe defaults to Claude Code's settings hierarchy.
Currently Claude-only (Codex/Gemini support follows in v0.3); for those agents,
audit reports findings and points at the manual fixes.

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
~/sandshell/scripts/audit-trail.sh show <session-id>
~/sandshell/scripts/audit-trail.sh summary <session-id>
```

This is *retrospective* data, separate from `sandshell audit` (which is
*pre-flight* config audit). Both are useful; they answer different questions.

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
| Sandbox enforcement on Codex/Gemini   | Audit flags issues but `apply` for those agents is v0.3+; today they need manual fixes                              |

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
