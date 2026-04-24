# Codex CLI adapter

- Prefer `Suggest` or `Auto Edit` for normal work
- Use `codex --full-auto` only when repo-scoped sandboxed execution is
  appropriate for the task
- Keep work inside the current git checkout unless the user approves broader
  access
- Use Codex approvals for actions that exceed the current workspace or need
  elevated access

Codex support in sandshell uses Codex's native approval and sandbox model for
enforcement. sandshell does not configure Codex-specific hooks or policy files.
