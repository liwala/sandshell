# sandshell

Audit, apply, and drift-check the safety configs of every AI coding agent on your machine.

For each AI coding agent you have installed (Claude Code, Codex CLI, Gemini
CLI), sandshell audits the safety config and reports what's risky, applies
safe defaults, and tracks drift between sessions so quiet regressions don't
slip through. It encodes the threat-model decisions you'd otherwise make by
hand for each agent.

**Sandshell is not a runtime sandbox.** It works on the sandbox primitives
your agent already ships with (Claude Code's native sandbox, Codex's
Seatbelt policy, Gemini's `tools.sandbox`). For *runtime* isolation of
unvetted code, reach for a microVM tool like Docker `sbx`. Sandshell is the
layer below — making sure the sandbox you do have is turned on, narrow, and
stays that way.

## Verbs

| Verb            | What it does                                                                                          |
|-----------------|-------------------------------------------------------------------------------------------------------|
| `detect`        | Report host **inventory**: OS, dependencies, native sandbox primitive, agents installed              |
| `audit`         | Report **safety findings** by severity. `--summary` for per-agent rollup, `--json` for machine-readable |
| `apply`         | Write safe-default configs to detected agents (Claude Code, Codex CLI, Gemini CLI)                   |
| `drift`         | Show what changed since the last apply / snapshot                                                    |
| `verify`        | Re-run audit; exit 2 on findings ≥ medium (for CI / pre-commit)                                      |
| `trail`         | Inspect the Bash audit trail per Claude Code session (`list`, `show`, `summary`)                     |
| `install-agent` | One-time install of sandshell skill / instruction docs into detected agents (idempotent)             |
| `uninstall`     | Remove sandshell-managed configs across detected agents                                              |

`detect` answers *"what do I have?"*; `audit` answers *"is it safe?"*;
`drift` answers *"did anything change since last time?"*. Use them together —
`detect` once at install, `audit` whenever you want a safety review, `drift`
whenever you want to spot config that's regressed since you last applied.

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

## Project-scope configs

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

HIGH (1)
  host.shell_alias_bypass
    Alias 'claude' includes bypass flag '--dangerously-skip-permissions'
    scope: ~/.zshrc:42
    fix:   Remove '--dangerously-skip-permissions' from the alias in ~/.zshrc

MEDIUM (2)
  cc.hooks.pre_bash
    Claude Code PreToolUse Bash guard hook is not configured
    fix:   sandshell apply
  host.creds_in_shell_rc
    Plaintext credential in shell rc: OPENAI_API_KEY
    scope: ~/.zshrc:18
    fix:   Load via a secrets manager (op, aws-vault, vault, pass, chamber, infisical, gcloud secrets) at session start, or move to a per-project .envrc that doesn't auto-load into every shell.
    source: literal value. Materialized in ~/.zshrc, this credential ends up in every shell's environment — including any agent your shell launches.

3 actionable findings (severity >= medium).

Drift since 2026-04-23T11:08:02Z: +1 new / -0 resolved
  + cc.hooks.pre_bash  (medium)  Claude Code PreToolUse Bash guard hook is not configured
```

The trailing block is the drift footer — see [Drift detection](#drift-detection) below for how it's computed.

## What audit checks

Per-agent adapters live in `agents/<name>/audit.sh`. Each reads the agent's
real configuration files and emits findings. Coverage at a glance:

| Adapter      | Surface                                                                                                                                            |
|--------------|----------------------------------------------------------------------------------------------------------------------------------------------------|
| `host`       | **Cross-agent host hygiene.** Bypass aliases (`--dangerously-skip-permissions`, `--full-auto`, `--yolo`), bypass env vars, plaintext creds in shell rc / `.envrc`, missing native sandbox primitive, non-git cwd, unknown repo provenance. |
| `claude`     | **Sandbox on and narrow; bypass paths denied.** Sandbox enabled (catches the silent-disable trap), write/network scope, `dangerouslyDisableSandbox` deny entry, wildcard Bash permissions, curl-pipe-shell patterns, PreToolUse/PostToolUse hooks present, no project-level MCP auto-approve. MCP servers are cross-referenced against an *opt-in* allowlist at `~/.sandshell/known-mcps.json` — silent until you create that file. |
| `codex`      | **Sandbox on, approvals required, no escape hatches.** `sandbox_mode != danger-full-access`, `approval_policy != never`, no broad `writable_roots`, no `trust_level = "trusted"` for `~`/`/`, no network in workspace mode. PreToolUse + PostToolUse hooks present, `[features] codex_hooks = true` set (catches the silent-disable trap where hooks.json is ignored). |
| `gemini`     | **Sandbox on, folder trust on, YOLO and always-allow off.** `tools.sandbox` configured, `sandboxNetworkAccess = false`, `security.folderTrust.enabled`, `security.disableYoloMode`, approval mode set, no wildcard entries in `trustedFolders.json`. |

The credential check classifies each export by injection source: `$(op …)`,
`$(aws-vault …)`, `$(vault …)`, `$(pass …)`, `$(gh auth token)`,
`$(gcloud secrets …)`, `$(infisical …)`, and other recognized
secrets-manager invocations stay silent; only literal values are flagged
at medium.

Adapters self-skip when their agent isn't installed.

## What `apply` configures

`sandshell apply` writes safe defaults for every detected agent. Each agent's
config is independent — `apply` is idempotent, and you can target a single
agent (`apply codex`) or all of them (`apply` / `apply all`).

| Agent       | What `apply` writes                                                                                    | macOS enforcement today                                                |
|-------------|--------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------|
| Claude Code | Native sandbox + Bash PreToolUse/PostToolUse hooks + skill                                             | Filesystem ✓.  Network ✗ (upstream [#37970](https://github.com/anthropics/claude-code/issues/37970)) |
| Codex CLI   | `~/.codex/config.toml` (sandbox_mode, network_access, approval_policy) + `~/.codex/hooks.json` (PreToolUse + PostToolUse Bash) + `[features] codex_hooks = true`                  | Filesystem ✓.  Network ✓ (kernel-enforced via Seatbelt MAC)             |
| Gemini CLI  | `~/.gemini/settings.json`: `tools.sandbox` (auto-detected: `sandbox-exec` on macOS, `docker`/`podman` on Linux based on what's installed), folder trust on, YOLO/always-allow off | Filesystem ✓.  Network ✗ under sandbox-exec ([#20381](https://github.com/google-gemini/gemini-cli/issues/20381)); ✓ under `tools.sandbox=docker` |

On Linux, the upstream bugs above don't apply. Claude Code (bubblewrap)
and Codex (bubblewrap + seccomp + Landlock) enforce both filesystem and
network at the kernel. Gemini on Linux uses `tools.sandbox=docker` or
`podman` (whichever is installed; `sandbox-exec` is macOS-only); the audit
fires `gemini.sandbox.linux_runtime_missing` if neither runtime is
available so the gap is visible rather than silent. Sandshell writes
forward-correct config so users get the benefit automatically when the
macOS fixes land.

Codex and Gemini are configured by a single file each — one place per agent
for safety settings. Claude Code is layered, so `apply` writes three
pieces:

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
sandshell apply user --profile=default

# Project scope (just this repo; gets committed to git)
sandshell apply project --profile=python

# Strict mode also denies reads to ~/.ssh, ~/.aws, ~/.gnupg, etc.
sandshell apply user --profile=default --strict
```

To roll back:

```bash
sandshell uninstall user
```

## Network profiles

Profiles control which hosts Claude Code's native sandbox permits.
(Codex and Gemini have their own per-agent network controls; profiles
don't apply to them.)

| Profile   | Hosts                                                                                          | Typical use         |
|-----------|------------------------------------------------------------------------------------------------|---------------------|
| `default` | GitHub, npm, PyPI, Go module proxy                                                             | General projects    |
| `node`    | GitHub, npm, yarnpkg, jsdelivr, unpkg, nodejs.org                                              | Node projects       |
| `python`  | GitHub, PyPI, conda/anaconda                                                                   | Python projects     |

The full host lists live in `profiles/*.conf` — one host per line, easy to
fork. Each profile is independent (not a superset of `default`).

## Audit trail

Claude Code and Codex CLI. `apply` wires each agent's `PostToolUse` Bash
hook (which fires after every Bash command the agent runs) to append a
one-line record per command into:

```bash
~/.sandshell/audit/<session-id>.jsonl
```

Each record is a JSON object with `ts`, `category` (one of `git`,
`github_cli`, `sandshell`, `read_only`, `unclassified`), `cmd` (truncated
to 500 chars), and `exit_code` — easy to grep, easy to feed into a
classifier later. Sessions from both Claude and Codex land in the same
directory; the file name is the session ID, so they don't collide.

For Codex, the trail requires a feature flag in `~/.codex/config.toml`:

```toml
[features]
codex_hooks = true
```

`sandshell apply codex` flips this on automatically. Without the flag,
Codex silently ignores `~/.codex/hooks.json` — sandshell's audit catches
this case (`codex.hooks.feature_flag`, high severity).

Helpers:

```bash
sandshell trail list                    # enumerate logged sessions, most recent first
sandshell trail show <session-id>       # display every Bash command in a session
sandshell trail summary <session-id>    # roll-up classification of a session
```

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
  + cc.permissions.wildcard_bash  (high)      Wildcard "Bash(*)" present in permissions.allow
  - cc.sandbox.enabled            (critical)  Claude Code sandbox is not enabled  — resolved
  - cc.hooks.pre_bash             (medium)    Claude Code PreToolUse Bash guard hook is not configured  — resolved

15 past snapshots in ~/.sandshell/baselines/ (oldest 2026-04-23).
```

This is the answer to *"did anything change since I last applied?"* — useful
at session start, in pre-commit hooks, or whenever you want to spot quiet
config regressions (a teammate's settings update, an agent self-modifying its
own config, an out-of-band edit). Historical snapshots accumulate as a
config-state audit trail that pairs with the Bash command audit trail above.

Configs shouldn't change often, so the snapshot directory stays small.
Sandshell never prunes — `rm ~/.sandshell/baselines/audit-*.json` if you
want to clean up old ones (`current.json` is the only one drift compares
against).

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
- **Surfaces drift between sessions.** When a setting regresses — teammate
  edit, out-of-band change, or the agent itself modifying its config — the
  next `audit` flags it explicitly instead of letting it silently weaken
  your defaults.

## Threat model

### What sandshell meaningfully reduces

| Threat                                       | How                                                                                                |
|----------------------------------------------|----------------------------------------------------------------------------------------------------|
| Misconfigured sandbox / silent disable        | `audit` flags missing or disabled sandbox; `apply` writes correct config                          |
| Bypass flags persisted in shell aliases       | `audit` parses shell rc files for `--dangerously-skip-permissions`, `--full-auto`, `--yolo`, etc. |
| Wildcard Bash permissions                    | `audit` flags `Bash`, `Bash(*)`, and curl-pipe-shell patterns                                     |
| Untrusted MCP servers                        | `audit` flags MCP servers not in your opt-in allowlist at `~/.sandshell/known-mcps.json` — silent until you create the file |
| Plaintext credentials in shell rc / `.envrc` | `audit` parses each cred export and classifies the injection source — silent for known secret managers (`op`, `aws-vault`, `vault`, `pass`, `gh auth token`, etc.), medium for literal values; `apply --strict` adds read-deny for credential paths |
| Untracked host-side Bash activity            | PostToolUse hook records every Bash command for retrospective review (Claude Code and Codex CLI; Gemini has no equivalent hook system) |
| Filesystem writes outside the repo            | Native sandbox enforces filesystem bounds (Seatbelt on macOS, bubblewrap on Linux)                |

### What it does not solve on its own

| Threat                                | Why not                                                                                                              |
|---------------------------------------|----------------------------------------------------------------------------------------------------------------------|
| **Network exfiltration on macOS** (today, varies by agent) | **Codex** enforces network at kernel level via Seatbelt MAC — `apply codex` actually delivers. **Claude Code** has open bug [#37970](https://github.com/anthropics/claude-code/issues/37970) — `allowedDomains` doesn't enforce for Bash subprocesses today. **Gemini** under `sandbox-exec` silently ignores `sandboxNetworkAccess` (architectural, not a bug); enforces under `tools.sandbox = "docker"`. See [KNOWN_ISSUES.md](KNOWN_ISSUES.md) for full picture. |
| Untrusted code execution at runtime    | Sandshell configures sandboxes; for unvetted dependencies or unknown repos, escalate to a microVM tool like Docker `sbx` |
| Supply-chain compromise (malicious npm / PyPI / etc. packages, compromised agent updates) | Sandshell doesn't detect malicious or compromised packages before install. Once they're running, the sandbox limits blast radius (network egress + filesystem reach), but that's containment, not prevention. For unvetted deps, run inside a microVM. |
| Prompt injection                      | Sandshell limits the *blast radius* of an injected agent (via the sandbox), not the injection itself                  |
| Real-time alerting / live monitoring  | Sandshell is a config linter, not a daemon                                                                           |

## Status

Current release: v0.2. See [CHANGELOG.md](CHANGELOG.md) for what's in it,
[SECURITY.md](SECURITY.md) for the security model,
[NOTES.md](NOTES.md) for design notes, and
[CONTRIBUTING.md](CONTRIBUTING.md) for tests and how to add an audit
check.

### Roadmap toward 1.0

- **Real MCP audit signal.** The MCP curation check is currently a hook
  for users who maintain their own `~/.sandshell/known-mcps.json`
  (silent until you create the file). Sandshell deliberately doesn't
  ship a curated default list — being the trust authority for MCPs is
  not a position we want to occupy. The v0.3+ research direction is
  pulling real signal from external sources: GitHub Security Advisories
  by package name, postinstall-script analysis, freshly-published
  version detection. None of which we ship today.
- **Refine the PreToolUse Bash guard's matcher.** It currently blocks
  any Bash command containing the literal trigger string, including
  inside quoted text in commit messages. Low-priority polish — workaround
  is to avoid the trigger string in shell-visible text.

## Requirements

- macOS or Linux
- `bash`, `python3`, `jq` (Codex audit additionally requires Python 3.11+ for `tomllib`)
- For the full Claude Code path: Claude Code with Bash `PreToolUse`/`PostToolUse` hook support
- For the Linux native sandbox: `bubblewrap` (`apt install bubblewrap`)

`sandshell detect` reports the status of each requirement.

## License

MIT
