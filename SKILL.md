---
name: sandshell
description: >
  Execute all code in a disposable, network-hardened container with full audit
  trail. Auto-activates when the task involves writing or running code. Supports
  Docker, Podman, and Lima.
---

# sandshell — Sandboxed Execution

You MUST execute all code inside a sandshell container. Never run code directly
on the host machine.

## Environment

```!
${CLAUDE_SKILL_DIR}/scripts/detect.sh
```

## Rules

### 1. Always sandbox

Before writing or executing any code, create a sandbox:

```bash
${CLAUDE_SKILL_DIR}/scripts/sandbox.sh create sandshell-${CLAUDE_SESSION_ID:0:8}
```

Run ALL commands inside it:

```bash
${CLAUDE_SKILL_DIR}/scripts/sandbox.sh exec sandshell-${CLAUDE_SESSION_ID:0:8} <command>
```

### 2. Host exceptions

These commands MAY run on the host (they need host credentials/context):
- `git push`, `git pull`, `git fetch`
- `gh pr create`, `gh pr merge`, `gh issue`
- `docker`/`podman`/`limactl` management commands
- Reading files with the Read tool (this is safe, read-only)

Everything else — builds, tests, linters, scripts, installs — runs in the
sandbox. When you run a host command, log it:

```bash
${CLAUDE_SKILL_DIR}/scripts/audit.sh log ${CLAUDE_SESSION_ID:0:8} \
  "{\"op\":\"host_cmd\",\"cmd\":\"$(echo $CMD | head -c 200)\",\"reason\":\"requires host git credentials\"}"
```

### 3. Network hardening

After creating the sandbox, apply network restrictions based on the project:

- `package.json` detected → `${CLAUDE_SKILL_DIR}/scripts/harden.sh sandshell-${CLAUDE_SESSION_ID:0:8} --profile=node`
- `pyproject.toml` or `requirements.txt` → `--profile=python`
- `go.mod` → `--profile=default`
- Otherwise → `--profile=default`

If the task needs a domain not in the profile:

```bash
${CLAUDE_SKILL_DIR}/scripts/harden.sh sandshell-${CLAUDE_SESSION_ID:0:8} --allow=extra-domain.com
```

### 4. Permission minimization

- Do NOT use `--dangerouslyDisableSandbox` or equivalent flags
- Mount the working directory read-only unless the task requires writing output files back to the host
- If write-back is needed, use `sandbox.sh copy-out` rather than RW mounts when possible
- Do not write files outside the project directory on the host

### 5. Audit trail

The scripts log automatically, but you MUST also log your reasoning when
making sandbox-vs-host decisions:

```bash
${CLAUDE_SKILL_DIR}/scripts/audit.sh log ${CLAUDE_SESSION_ID:0:8} \
  "{\"op\":\"decision\",\"choice\":\"host\",\"reason\":\"git push requires SSH keys from host\"}"
```

### 6. Cleanup

When your task is complete, destroy the sandbox:

```bash
${CLAUDE_SKILL_DIR}/scripts/sandbox.sh destroy sandshell-${CLAUDE_SESSION_ID:0:8}
```

The audit trail persists at `~/.sandshell/audit/` after the container is gone.

## Quick reference

| Action | Command |
|--------|---------|
| Create sandbox | `sandbox.sh create <name> [--runtime=docker\|lima] [--mount=ro\|rw]` |
| Run command | `sandbox.sh exec <name> <cmd...>` |
| Copy file in | `sandbox.sh copy-in <name> <src> <dest>` |
| Copy file out | `sandbox.sh copy-out <name> <src> <dest>` |
| Harden network | `harden.sh <name> --profile=<name>` |
| Harden custom | `harden.sh <name> --allow=domain1,domain2` |
| Destroy | `sandbox.sh destroy <name>` |
| View audit log | `audit.sh show <session-id>` |
