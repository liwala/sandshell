# Changelog

All notable changes to this project should be documented in this file.

## 0.2.0 - 2026-05-03

### Added

- `bin/sandshell` top-level CLI dispatcher with verbs `detect`, `audit`, `apply`, `verify`, `drift`.
- `sandshell audit` — cross-agent config audit. Per-agent adapters in `agents/<name>/audit.sh` emit NDJSON findings; the runner aggregates, sorts by severity, prints human or `--json` output.
- `sandshell audit --summary` — per-agent worst-severity rollup in `key=value` format (greppable; suitable for scripting).
- `sandshell verify` — `audit --strict`; exits 2 on findings ≥ medium for CI / pre-commit gating.
- **Drift detection.** Every `sandshell apply` snapshots the post-apply audit state to `~/.sandshell/baselines/current.json` plus a timestamped historical copy at `~/.sandshell/baselines/audit-<timestamp>.json`. Subsequent `sandshell audit` runs compare against that baseline and report what's new or resolved. New `sandshell drift` verb shows only the diff; `audit --snapshot` captures a baseline manually; `audit --no-drift` suppresses the footer (e.g. in CI). Historical snapshots accumulate as a config-state audit trail that pairs with the existing Bash command audit trail.
- 32 audit checks across four adapters: 6 host (cross-agent shell aliases, env-var bypasses, long-lived creds, native-sandbox availability, cwd-is-git-repo, repo provenance), 14 Claude Code, 6 Codex, 11 Gemini.
- `sandshell apply codex` — writes safe defaults to `~/.codex/config.toml` (`scripts/setup-codex.sh`).
- `sandshell apply gemini` — writes safe defaults to `~/.gemini/settings.json` or `./.gemini/settings.json` (`scripts/setup-gemini.sh`); merges with existing keys via `jq`.
- `sandshell apply` (no args) — applies safe defaults to every detected agent in one command.
- `KNOWN_ISSUES.md` — central tracker for upstream bugs and architectural limitations affecting sandshell's claims; audit findings cross-reference its entries.

### Changed

- `host.long_lived_creds` (high) → `host.creds_in_shell_rc` (medium), with the RHS of every credential export classified by injection source. Static parsing can't tell long-lived from short-lived, only how the value is materialized: literal in the file (flagged), or fetched at session start from a known secrets manager — `op`, `aws-vault`, `vault`, `pass`, `bw`, `chamber`, `infisical`, `lpass`, `sops`, `teller`, `security`, `keyring`, `gh auth token`, `glab`, `gcloud secrets|auth`, `az account get-access-token`, `aws sts` (silent). Unrecognized command substitutions and `$VAR` forwarding emit info-level so the user can verify. Scope expanded to include cwd `.envrc`. Existing AWS_SESSION_TOKEN exemption preserved.
- **Schema fix for Claude Code sandbox config** — v0.2 writes the documented schema (`sandbox.network.allowedDomains`, `sandbox.filesystem.allowWrite`, `sandbox.filesystem.denyRead`). v0.1 was writing legacy field names (`allowedHosts`, `filesystem.write.allowOnly`, `filesystem.read.denyOnly`) that Claude Code does not enforce; the network field in particular was silently ignored, leaving outbound traffic unrestricted. Audit's new `cc.sandbox.legacy_schema` check fires critical for v0.1 settings; re-running `sandshell apply` migrates them.
- `detect.sh` is now pure inventory — OS, deps, native sandbox primitive, agents installed. Safety status moved to `audit --summary`.
- Field renames in `detect` output: `audit_hooks_configured` → `audit_trail_hooks_configured`; `bash_guard_configured` → `claude_pre_bash_hook_configured`. The previous names have been removed.
- `scripts/audit.sh` (JSONL audit-trail helper) renamed to `scripts/audit-trail.sh` to free the `audit` verb for config audit. References updated across hooks, README, SKILL.md, examples.
- `uninstall.sh` extended to also remove sandshell-managed `~/.codex/config.toml` and sandshell-managed sections of `~/.gemini/settings.json`.

### Removed

- `profiles/minimal.conf` — empty `allowedDomains: []` is unreliably interpreted by Claude Code (may permit all outbound rather than deny all). The new `cc.sandbox.network_allowlist_empty` audit check (high severity) catches this case if anyone hand-rolls it.

### Renamed

- Scope name `personal` renamed to `user` (matches Claude Code's own docs and industry convention). Gemini's `workspace` scope renamed to `project` for cross-agent CLI consistency. Both legacy names still accepted by all scripts; `--help` notes the aliases.

### Migration from 0.1.0

v0.1 users should re-run `sandshell apply` to migrate from the legacy sandbox schema (`allowedHosts`, `allowOnly`, `denyOnly`) to the documented schema (`allowedDomains`, `allowWrite`, `denyRead`). The `cc.sandbox.legacy_schema` audit check fires *critical* for unmigrated settings. Until apply is re-run, Claude Code silently ignores the legacy network field, leaving outbound traffic unrestricted.

```bash
~/sandshell/bin/sandshell apply user --profile=default
~/sandshell/bin/sandshell apply project --profile=default   # if you have project-scope settings
~/sandshell/bin/sandshell audit                              # confirm cc.sandbox.legacy_schema is gone
```

### Compatibility

- **Settings schema**: v0.2 writes Claude Code's documented schema (`sandbox.network.allowedDomains`, `sandbox.filesystem.allowWrite`, `sandbox.filesystem.denyRead`). v0.1's legacy field names (`allowedHosts`, `filesystem.write.allowOnly`, `filesystem.read.denyOnly`) are detected by audit and migrated by re-running apply.
- **`detect` output fields renamed**: `audit_hooks_configured` → `audit_trail_hooks_configured`; `bash_guard_configured` → `claude_pre_bash_hook_configured`. Safety summary fields (`cc_sandbox_configured` etc.) moved out of `detect` entirely; use `sandshell audit --summary` for at-a-glance safety status.
- **Scope names**: `personal` → `user`, `workspace` → `project` across the CLI surface. Legacy names still accepted with deprecation notice on stderr.
- **Internal script rename**: `scripts/audit.sh` (JSONL audit-trail helper) renamed to `scripts/audit-trail.sh` to free the `audit` verb.
- **`profiles/minimal.conf`** removed. Empty `allowedDomains` is unsafe; the new `cc.sandbox.network_allowlist_empty` audit check (high) catches anyone hand-rolling it.

### Known issues (see [KNOWN_ISSUES.md](KNOWN_ISSUES.md))

- **Claude Code macOS network sandbox not enforcing** — `allowedDomains` doesn't reliably restrict Bash subprocess outbound on macOS (upstream [#37970](https://github.com/anthropics/claude-code/issues/37970)). Sandshell writes the documented schema (forward-correct when upstream fixes land) and the audit check makes the limitation visible.
- **Gemini CLI sandbox-exec on macOS silently ignores `sandboxNetworkAccess`** — architectural, not a bug. Only `tools.sandbox = "docker"` / `"podman"` honors it. `sandshell apply gemini` writes the setting (forward-correct + works under docker) and prints the macOS caveat at apply time.
- **Codex CLI macOS sandbox enforces network at kernel level via Seatbelt MAC** — the strongest of the three on macOS, verified empirically. `sandshell apply codex` actually delivers on its promise.

## 0.1.0 - 2026-04-10

First release candidate.

### Added

- Claude Code native sandbox setup, Bash guard hooks, and audit logging.
- Container lifecycle management with Docker, Podman, and Lima support.
- Network hardening with host-side IPv4/IPv6 resolution and post-resolution DNS deny.
- Agent install helpers for Claude Code, Codex CLI, Gemini CLI, and Amp.
- Local regression tests, Docker integration test, and GitHub Actions CI.
- Maintainer smoke test via `scripts/release-check.sh`.
- Claude settings rollback via `scripts/uninstall.sh`.

### Changed

- Clarified that Claude Code is the primary supported path for `0.1.0`.
- Tightened README/install guidance around explicit mounts, ports, and support boundaries.
- Tightened failure behavior when sandbox firewall rules cannot be enforced.

### Compatibility

- Sandbox state files under `~/.sandshell/state/*.env` use `version=1`.
- Claude Code settings written by sandshell use `sandshell_managed`, `hook-pre-bash.sh`, and `hook-post-bash.sh`.
- `scripts/uninstall.sh` removes those sandshell-managed settings without deleting unrelated configuration.
