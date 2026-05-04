# Design notes — v0.2 scope

Working notes. Not for shipping. Source of truth for the README rewrite.

## What sandshell is

A cross-agent linter and configurator for safe defaults. Makes running coding
agents directly on your machine safer by keeping their isolation configs
correct — without competing with sandbox runners (Docker sbx) or trying to
replace the agent's own permission system.

One sentence: **sandshell keeps your coding agents' safety settings correct,
across agents, with one command.**

## v0.2 verbs

| Verb     | Job                                                                                  |
|----------|--------------------------------------------------------------------------------------|
| `detect` | What's installed: Seatbelt? bwrap? sbx? Which agents? What config do they have now?  |
| `audit`  | Read each agent's config and flag risky settings. Output is the product.             |
| `apply`  | Write safe defaults for whatever agents `detect` found.                              |
| `verify` | Re-run audit, exit non-zero on drift. For pre-commit hooks, CI, periodic checks.     |

`detect` and `apply` already exist in v0.1 in Claude-only form. v0.2 widens
them to other agents and adds `audit` + `verify` as new top-level verbs.

## Audit-check spec

The audit-check set *is* the product — every other piece is plumbing around
it. This section is the source of truth; per-agent adapter scripts and the
top-level `sandshell audit` runner consume it.

### Output format

```
sandshell audit — 2026-04-28T15:32:14Z

CRITICAL (1)
  cc.sandbox.enabled
    Claude Code sandbox is not enforcing.
    file: ~/.claude/settings.json
    fix:  sandshell apply --profile=default

HIGH (2)
  cc.permissions.no_wildcard_bash
    Wildcard "Bash(*)" present in permissions.allow.
    file: ~/.claude/settings.json
    fix:  remove "Bash(*)" from permissions.allow

  host.shell_alias_bypass
    Alias 'claude' includes --dangerously-skip-permissions.
    file: ~/.zshrc:42
    fix:  remove the flag from the alias

MEDIUM (3)  ...
INFO (5)    ...

3 actionable findings (severity ≥ medium). --json for machine-readable output.
```

### Check schema

| Field        | Notes                                                            |
|--------------|------------------------------------------------------------------|
| `id`         | Stable kebab-case, scoped: `<agent_or_host>.<area>.<check>`      |
| `severity`   | `critical` / `high` / `medium` / `info`                          |
| `title`      | One-line human-readable summary                                  |
| `applies_when` | When to run the check (e.g., agent installed, file present)    |
| `detect`     | Source file + condition; pure read, no side effects              |
| `remediate`  | Concrete fix: a `sandshell apply` flag, an edit, or manual step  |

Severity scale, for calibration:
- **critical** — silent loss of safety (sandbox disabled, skip-permissions flag in alias)
- **high** — significant attack surface (wildcard permissions, missing deny rules)
- **medium** — narrower attack surface or partial protection (missing hooks, untrusted MCPs)
- **info** — informational, no remediation pressure (audit trail absent, fresh clone of unknown repo)

### Cross-agent host checks

These run regardless of which agents are installed.

| ID                          | Sev      | Detect                                                                            | Remediate                                          |
|-----------------------------|----------|-----------------------------------------------------------------------------------|----------------------------------------------------|
| `host.shell_alias_bypass`   | critical | `~/.zshrc`, `~/.bashrc`, `~/.config/fish/config.fish` — alias for `claude`/`codex`/`gemini`/`amp` containing `--dangerously-skip-permissions`, `--full-auto`, or known bypass flags | Remove the flag from the alias                     |
| `host.env_bypass_var`       | critical | Shell rc files set env vars known to bypass safety (e.g., `CLAUDE_DANGEROUSLY_SKIP_PERMISSIONS=1`) | Remove from rc                                     |
| `host.long_lived_creds`     | high     | Env exports of `AWS_ACCESS_KEY_ID`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, etc. in shell rc + sandbox doesn't deny reading credential paths | Use short-lived tokens, separate user, or `--strict` sandbox |
| `host.native_sandbox_available` | medium | macOS: `sandbox-exec` present (always). Linux: `bwrap` present.                   | `apt install bubblewrap` on Linux                  |
| `host.cwd_is_git_repo`      | high     | `git rev-parse --is-inside-work-tree` succeeds in cwd                             | `git init` (or move to a tracked repo). Without revision control, agent changes can't be reviewed or reverted. |
| `host.repo_provenance`      | info     | `git remote get-url origin` against `~/.sandshell/known-repos.json`               | Add to known-repos if you trust this remote        |

### Claude Code checks

Settings scopes (precedence high → low, per docs.claude.com): `managed` > command-line > `~/.claude/settings.local.json` (gitignored local) > `.claude/settings.json` (project, in git) > `~/.claude/settings.json` (user). For `permissions.allow`/`deny` and sandbox array fields, scopes **merge (union)** rather than replace. v0.2 audits each scope file independently and reports findings per scope path; effective-settings computation is deferred to v0.3.

**Sandbox schema** uses v0.1's working layout: `sandbox.filesystem.write.allowOnly`, `sandbox.filesystem.read.denyOnly`, `sandbox.network.allowedHosts`. (External research suggested `allowWrite`/`allowedDomains`; the v0.1 implementation is authoritative since it has passing tests.)

| ID                                | Sev      | Detect                                                                                  | Remediate                                |
|-----------------------------------|----------|-----------------------------------------------------------------------------------------|------------------------------------------|
| `cc.sandbox.enabled`              | critical | `sandbox.enabled === true` in at least one scope                                        | `sandshell apply --profile=default`      |
| `cc.sandbox.silent_disable`       | critical | `sandbox` block present but `sandbox.enabled !== true` (the silent-off trap)            | `sandshell apply` (re-enable)            |
| `cc.sandbox.write_scope`          | high     | `sandbox.filesystem.write.allowOnly` bounded (project + `$TMPDIR`); not `/`, `~`, `*`    | `sandshell apply`                        |
| `cc.sandbox.network_allowlist`    | medium   | `sandbox.network.allowedHosts` present, non-empty, no `*`                               | `sandshell apply --profile=<lang>`       |
| `cc.sandbox.deny_disable_flag`    | high     | `permissions.deny` includes `Bash(dangerouslyDisableSandbox:true)`                      | `sandshell apply`                        |
| `cc.sandbox.strict_reads`         | info     | `sandbox.filesystem.read.denyOnly` includes `~/.ssh`, `~/.aws`, `~/.gnupg`, etc.        | `sandshell apply --strict`               |
| `cc.permissions.no_wildcard_bash` | high     | `permissions.allow` does not contain wildcards: `Bash`, `Bash(*)`, `Bash(*:*)`          | Remove wildcards; allow specific commands only |
| `cc.permissions.no_curl_pipe_sh`  | high     | `permissions.allow` does not contain `Bash(curl * \| sh)`, `Bash(wget * \| sh)`, `Bash(* \| bash)` patterns | Remove from allow list                  |
| `cc.hooks.pre_bash`               | medium   | `hooks.PreToolUse` has Bash matcher invoking `hook-pre-bash.sh`                         | `sandshell apply` / `setup-hooks.sh`     |
| `cc.hooks.post_bash`              | info     | `hooks.PostToolUse` has Bash matcher invoking `hook-post-bash.sh`                       | `sandshell apply`                        |
| `cc.mcp.curated`                  | medium   | MCP servers in `~/.claude.json` (user-scope, written by `claude mcp add`) and project-level `.mcp.json` all appear in `~/.sandshell/known-mcps.json` | Review each MCP; add to known-mcps if trusted |
| `cc.mcp.project_auto_approve`     | high     | `enableAllProjectMcpServers !== true` in any scope (auto-approving project MCPs is risky) | Remove the setting or set to `false`     |
| `cc.mcp.allowed_only`              | info     | `allowManagedMcpServersOnly === true` in managed scope (most restrictive)               | Set in enterprise contexts                |
| `cc.launch.no_skip_permissions`   | critical | No `--dangerously-skip-permissions` in shell aliases or wrappers for `claude`            | Remove flag from alias/wrapper           |

**MCP storage note:** `claude mcp add` writes to `~/.claude.json` (NOT `~/.claude/settings.json`). Project-shared MCPs go in `.mcp.json` at the repo root. The audit reads both. Restriction settings (`allowedMcpServers`, `deniedMcpServers`, `enableAllProjectMcpServers`, `enabledMcpjsonServers`, `disabledMcpjsonServers`) live in the normal settings hierarchy (settings.json scopes).

### Codex CLI checks

Config: `~/.codex/config.toml` (or `$CODEX_HOME/config.toml`). Schema verified against `codex-rs/core/config.schema.json` in `openai/codex`.

| ID                              | Sev    | Detect                                                                                                          | Remediate                                  |
|---------------------------------|--------|-----------------------------------------------------------------------------------------------------------------|--------------------------------------------|
| `codex.sandbox_mode`            | high   | `sandbox_mode` is `"workspace-write"` or `"read-only"`, not `"danger-full-access"`                              | Set to `workspace-write`                   |
| `codex.approval_policy`         | medium | `approval_policy` is not `"never"`. Acceptable: `"untrusted"`, `"on-request"`. (`"on-failure"` is deprecated.)   | Set to `on-request`                        |
| `codex.network_access`          | medium | `[sandbox_workspace_write].network_access` is `false` (default; only false counts as safe)                      | Set to false; gate per-task with CLI flag  |
| `codex.writable_roots_bounded`  | medium | `[sandbox_workspace_write].writable_roots` empty or scoped (no `~`, `/`, `$HOME`)                               | Tighten list                               |
| `codex.no_trusted_broad_dirs`   | high   | No `[projects."<path>"]` with `trust_level = "trusted"` where `<path>` is `~`, `/`, or a broad parent of work    | Remove or narrow the project entry         |
| `codex.launch.no_bypass`        | high   | No `--full-auto`, `--dangerously-bypass-approvals-and-sandbox`, or `-y` in shell aliases for `codex`             | Remove from alias                          |

There is **no boolean `yolo`/`full_auto` field** — runtime CLI flags set `sandbox_mode = "danger-full-access"` + `approval_policy = "never"` together. The config-time equivalent is detecting that combination.

### Gemini CLI checks

Config: `~/.gemini/settings.json` (user) and `<repo>/.gemini/settings.json` (workspace; overrides user). Trust DB: `~/.gemini/trustedFolders.json` (env override `GEMINI_CLI_TRUSTED_FOLDERS_PATH`). Schema verified against `google-gemini/gemini-cli` docs.

| ID                                       | Sev      | Detect                                                                                  | Remediate                                              |
|------------------------------------------|----------|-----------------------------------------------------------------------------------------|--------------------------------------------------------|
| `gemini.sandbox_enabled`                 | critical | `tools.sandbox` is truthy: `true`, `"docker"`, `"podman"`, `"sandbox-exec"`, `"runsc"`, `"lxc"`, or object | Set `tools.sandbox` to a supported provider            |
| `gemini.sandbox_network_off`             | medium   | `tools.sandboxNetworkAccess !== true`                                                   | Set to `false`                                          |
| `gemini.sandbox_paths_bounded`           | medium   | `tools.sandboxAllowedPaths` empty or scoped (no `~`, `/`)                               | Tighten list                                           |
| `gemini.folder_trust_enabled`            | high     | `security.folderTrust.enabled === true`                                                 | Enable folder trust                                    |
| `gemini.disable_yolo`                    | high     | `security.disableYoloMode === true`                                                     | Set to true                                            |
| `gemini.disable_always_allow`            | medium   | `security.disableAlwaysAllow === true`                                                  | Set to true                                            |
| `gemini.approval_mode`                   | medium   | `general.defaultApprovalMode` is `"default"` or `"plan"` (not `"auto_edit"`)            | Set to `default`                                       |
| `gemini.trusted_folders_bounded`         | high     | `~/.gemini/trustedFolders.json` entries don't cover `~` or `/`                          | Remove broad entries                                   |
| `gemini.guidance_present`                | info     | `GEMINI.md` contains sandshell guidance block                                           | `install-agent.sh gemini`                              |
| `gemini.launch.no_bypass`                | high     | No `--yolo`, `--approval-mode=yolo`, or `GEMINI_SANDBOX=false` in shell aliases for `gemini` | Remove from alias                                      |

### Amp checks — DEFERRED to v0.3

Sourcegraph's manual states `amp.permissions` is being replaced by a plugin API "soon" with a compatibility plugin. Implementing audit against the soon-to-be-legacy schema would mean re-doing the work once the plugin API lands. Defer the Amp adapter; revisit in v0.3 once the new API stabilizes.

Detect should still report Amp's presence (so users know it's installed) and emit one info-severity finding noting that Amp audit is unavailable in v0.2.

Spec preserved below for future reference, against schema at `~/.config/amp/settings.json` (user), `.amp/settings.json` (workspace), enterprise managed-settings on platform-specific paths. All keys nested under `amp.` prefix.

| ID                                | Sev    | Detect                                                                                                       | Remediate                                              |
|-----------------------------------|--------|--------------------------------------------------------------------------------------------------------------|--------------------------------------------------------|
| `amp.permissions_present`         | high   | `amp.permissions` is non-empty (default falls back to a permissive built-in allowlist if absent)             | Add an explicit policy with deny-by-default tail        |
| `amp.no_wildcard_allow`           | high   | No entry of shape `{ tool: "*", action: "allow" }` in `amp.permissions`                                      | Replace with `ask` or `delegate`                       |
| `amp.deny_default_tail`           | medium | Last entry in `amp.permissions` is `{ tool: "*", action: "ask" }` or `"delegate"` or `"reject"`              | Append a deny-by-default tail                          |
| `amp.mcp_permissions_present`     | high   | `amp.mcpPermissions` non-empty (empty = allow all MCPs)                                                      | Add explicit allow/reject rules with reject-by-default |
| `amp.guidance_present`            | info   | `AGENTS.md` contains sandshell guidance block                                                                | `install-agent.sh amp`                                 |
| `amp.launch.no_bypass`            | high   | No `--dangerously-allow-all` in shell aliases for `amp`                                                      | Remove from alias                                      |

Note: Amp has **no host-level sandbox** (in-process enforcement only). For risky tasks, audit's escalation guidance should point at sbx.

### Generic / unknown agent

Fallback when an agent is detected but no specific adapter exists.

| ID                          | Sev    | Detect                                                              | Remediate                                          |
|-----------------------------|--------|---------------------------------------------------------------------|----------------------------------------------------|
| `generic.guidance_present`  | info   | `SANDSHELL.md` referenced from agent's instruction file              | `install-agent.sh generic`                         |
| `generic.no_native_sandbox` | medium | Agent has no detectable native sandbox/approval surface             | Treat as advisory only; recommend sbx for risky tasks |

### Resolved / remaining open questions

After schema research:

1. ~~Codex config schema~~ — **resolved** above (verified against `codex-rs/core/config.schema.json`).
2. ~~Claude Code MCP storage~~ — **resolved**: `~/.claude.json` (user, written by `claude mcp add`) + `.mcp.json` (project). Restriction settings in normal settings.json hierarchy.
3. ~~Gemini CLI config~~ — **resolved**: structured at `~/.gemini/settings.json` with significant safety surface (`tools.sandbox`, `security.folderTrust`, `security.disableYoloMode`, etc.).
4. ~~Amp safety surface~~ — **resolved**: real permission system at `amp.permissions` and `amp.mcpPermissions` in `~/.config/amp/settings.json`. Version-unstable per Sourcegraph's manual.
5. ~~Settings precedence~~ — **resolved**: managed > CLI > local > project > user; arrays merge (union). v0.2 audits each scope file independently.
6. **MCP allowlist seed** — **decided**: ship empty. Curating a baseline is ongoing maintenance and creates a trust claim sandshell can't back. Document a recommended starter list in the README, but don't bake one in.

**New flag from research:** Amp's `amp.permissions` schema is being replaced by a plugin API "soon" — track Sourcegraph's manual for the v0.3 update.

### Implementation note

Each agent's checks should live in `agents/<name>/audit.sh` and emit JSON findings to stdout. The top-level `sandshell audit` runs all detected adapters in parallel, aggregates findings, sorts by severity, formats output. This keeps per-agent knowledge isolated and makes adding agents a matter of dropping in another adapter.

## When audit can't cover something — escalate

When a config can't be made safe (e.g., user wants to install an unvetted
package, fresh-clone an unknown repo), audit's output points at sbx as the
right tool for that case. One line of output, not a separate feature. Same
"taste in defaults" applied to escalation guidance.

## What stays from v0.1

- **Bash + markdown identity.** v0.2 audit logic stays in bash. The TS parser
  is vendored as v0.3 infrastructure, not integrated into the v0.2 hot path.
- **The Claude Code skill (`SKILL.md`).** Sandshell remains installable as a
  skill — that's a key delivery channel for Claude Code users. The skill body
  may evolve as the README is rewritten, but the skill itself stays.
- **Existing setup scripts.** `setup.sh`, `setup-sandbox.sh`, `setup-hooks.sh`,
  `install-agent.sh`, `uninstall.sh`, the two `hook-*.sh` files, the profiles,
  the agent guidance docs (`SANDSHELL.md`, `CODEX.md`, `GENERIC.md`). All keep
  working; v0.2 wraps them under a top-level CLI rather than replacing them.
- **The audit trail hooks.** PostToolUse Bash logging into
  `~/.sandshell/audit/<session>.jsonl` keeps writing — feeds the v0.3 session
  parser when that work lands.

## Dependency handling

Pattern: **fail clearly, fix obviously.** No auto-install, no vendored
binaries, no pure-bash parsing of hostile input.

- **Hard deps:** `bash`, `python3`. Already required; both ubiquitous.
- **Common deps:** `jq`. Already required by setup scripts. Fail-fast with
  per-platform install hint (`brew install jq` / `apt install jq`).
- **Optional per-agent deps:** e.g., Python `tomllib` for Codex audit
  (built-in 3.11+). When unavailable, the agent's adapter returns one
  info-severity finding ("Codex audit unavailable on this Python version")
  and the rest of audit continues. No silent skip.
- **`sandshell detect`** lists dep status explicitly: `jq=present`,
  `python3=3.13`, `tomllib=available`, `bwrap=missing`. First place users
  look when something doesn't work.

## CLI shape

v0.2 introduces a top-level dispatcher: `bin/sandshell <verb> [args]`.
Subverbs map to existing or new scripts:

| Verb     | Implementation                                         |
|----------|--------------------------------------------------------|
| `detect` | `scripts/detect.sh` (extended for cross-agent reports) |
| `audit`  | `scripts/audit-config.sh` (new) — per-agent adapters in `agents/<name>/audit.sh` |
| `apply`  | `scripts/setup.sh` (existing, extended)                |
| `verify` | `scripts/audit-config.sh --strict` (re-runs audit, exits non-zero on findings) |

**Naming collision:** the v0.1 `scripts/audit.sh` (JSONL audit-trail helpers
for PostToolUse log inspection) was renamed to `scripts/audit-trail.sh` to
free up "audit" for config audit. References updated across hooks, README,
SKILL.md, examples, agent docs.

Existing scripts can also still be invoked directly — the dispatcher is sugar,
not a replacement.

## Explicitly out of scope for v0.2

- Lightweight per-command sandbox wrapper (`sandshell run -- <cmd>`).
  Maybe v0.3 if users ask for it.
- In-loop advisor / runtime triage (the "counsel" idea).
  Walked back: too much overlap with permission systems, weak enforcement
  outside Claude Code, and the audit/apply path covers most of what users
  actually need.
- User-facing session review (the TS parser's eventual output verb).
  Parser vendored as v0.3 primitive; UX deferred until we know what's useful.
- Daemon / monitoring / real-time alerting.
  No demand signal yet.
- Sandbox runner of our own.
  Docker sbx exists.

## Moats

1. **Cross-agent neutrality.** A first-party tool (Anthropic, OpenAI) won't
   audit a competitor's config or recommend switching to one.
2. **Taste in defaults.** The set of "what's risky and what's safe" is the
   product. Comes from the threat-model work in the agentic-security guide.
3. **Lightweight discipline.** Not a runner, not a daemon, not a sandbox of
   its own. Stays shippable by one person.

## Name

Sticking with **sandshell**. The "counsel" rename was tied to the advisor
pivot, which we walked back. Sandshell fits the actual scope — wrapping
agents in safe defaults — better than counsel does.
