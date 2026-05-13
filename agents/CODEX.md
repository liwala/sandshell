# Codex CLI adapter

- Prefer `Suggest` or `Auto Edit` for normal work
- Use `codex --full-auto` only when repo-scoped sandboxed execution is
  appropriate for the task
- Keep work inside the current git checkout unless the user approves broader
  access
- Use Codex approvals for actions that exceed the current workspace or need
  elevated access

Codex support in sandshell leans on Codex's native approval and sandbox model
for enforcement, and adds optional PreToolUse/PostToolUse Bash hooks that
mirror the Claude Code setup:

- `scripts/setup-codex-hooks.sh [user|project]` installs hooks into
  `~/.codex/hooks.json` or `.codex/hooks.json`, and enables
  `[features] codex_hooks = true` in `~/.codex/config.toml` (Codex ignores
  `hooks.json` silently without that flag)
- PreToolUse runs `scripts/hook-pre-bash.sh` to block obvious sandbox-disable
  attempts (e.g. `--dangerouslyDisableSandbox`) before execution
- PostToolUse runs `scripts/hook-post-bash.sh` to log every Bash command into
  the shared audit trail at `~/.sandshell/audit/`
