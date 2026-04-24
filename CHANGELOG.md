# Changelog

All notable changes to this project should be documented in this file.

## Unreleased

### Changed

- Narrowed the release scope to Claude native sandboxing, Bash hooks, and audit logging.
- Removed the container runtime path from supported docs, scripts, tests, and CI.
- Fixed `hook-post-bash.sh` so Bash command logging no longer fails on startup.
- Narrowed `hook-pre-bash.sh` so it blocks obvious sandbox-disable attempts without blocking normal build and test commands.
- Split sandshell instructions into an agent-agnostic core plus Claude, Codex, and generic adapters.
- Added a `generic` install target that writes `SANDSHELL.md` for unsupported coding agents.
- Stopped generating Codex instructions that tell Codex users to run Claude-only setup commands.

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
