# Example: Native-Sandboxed Claude Session

An example sandshell-protected Claude Code session focused on the supported
release path.

## 1. Session start

`detect.sh` reports:

```text
os=darwin
arch=arm64
native_sandbox=seatbelt
cc_sandbox_configured=true
audit_hooks_configured=true
bash_guard_configured=true
```

This means:

- Claude's native sandbox is configured
- Bash guard and audit hooks are active

## 2. Normal work

The agent runs normal commands through Claude's Bash tool under the native
sandbox:

```bash
npm install
npm test
npm run build
```

Those commands are constrained by the configured filesystem and network policy.

## 3. Host-side commands

Commands that need host credentials still run normally:

```bash
git add -A
git commit -m "feat: add profile page"
git push origin feature-branch
gh pr create --title "Add profile page"
```

With hooks enabled, Bash invocations are logged to the sandshell audit trail.

## 4. Audit review

```bash
audit.sh summary a1b2c3d4
```

Example output:

```text
Session: a1b2c3d4
Total operations: 8
Sandbox commands: 0
Host commands: 5
Host breakdown: {'git': 3, 'github_cli': 1, 'read_only': 1}
Failures: 0
Operations: {'host_bash': 5, 'decision': 1, 'session_start': 1}
Sandbox ratio: 0%
```

The important point for this release is not container usage. It is that Claude's
native sandbox remains the main boundary and the Bash trail is visible.
