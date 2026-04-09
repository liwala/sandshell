# Example: Sandboxed Next.js Development

A complete sandshell-protected Claude Code session, showing all three tiers.

## 1. Session start

The skill auto-activates. `detect.sh` runs and reports the environment:

```
os=darwin
arch=arm64
docker_available=true
docker_path=/usr/local/bin/docker
docker_version=28.5.2
runtime=docker
native_sandbox=seatbelt
cc_sandbox_configured=true
audit_hooks_configured=true
pipelock_available=false
```

sandshell sees:
- **Tier 1** active (native sandbox configured, Seatbelt available)
- **Tier 2** available (Docker running)
- **Tier 3** not available (Pipelock not installed — optional)

## 2. Tier 1: OS sandbox (already active)

The native sandbox is already configured via `setup.sh`. The kernel enforces:
- Writes only to the project directory
- Network only to domains in the `node` profile
- `--dangerouslyDisableSandbox` denied

This protects even before the container is created.

## 3. Tier 2: Container sandbox

Claude detects `package.json` with Next.js and creates a container with
appropriate ports and network profile:

```bash
sandbox.sh create sandshell-a1b2c3d4 --ports=3000 --mount=ro
harden.sh sandshell-a1b2c3d4 --profile=node
```

All code execution happens inside the container:

```bash
# Install dependencies (inside container — malicious post-install scripts
# can't touch host filesystem or credentials)
sandbox.sh exec sandshell-a1b2c3d4 npm install

# Run dev server (accessible at localhost:3000 on host)
sandbox.sh exec sandshell-a1b2c3d4 npm run dev

# Run tests
sandbox.sh exec sandshell-a1b2c3d4 npm test

# Build
sandbox.sh exec sandshell-a1b2c3d4 npm run build
```

## 4. Host commands (logged)

Git and GitHub CLI run on the host because they need local credentials.
The PostToolUse hook logs them automatically:

```bash
git add -A
git commit -m "feat: add user profile page"
git push origin feature-branch
gh pr create --title "Add user profile page"
```

The agent also logs its reasoning:
```bash
audit.sh log a1b2c3d4 \
  '{"op":"decision","choice":"host","reason":"git push requires SSH keys from host"}'
```

## 5. Cleanup

```bash
sandbox.sh destroy sandshell-a1b2c3d4
```

## 6. Audit trail

```
$ audit.sh summary a1b2c3d4

Session: a1b2c3d4
Total operations: 12
Sandbox commands: 5
Host commands: 4
Host breakdown: {'git': 3, 'github_cli': 1}
Failures: 0
Operations: {'session_start': 1, 'create': 1, 'harden': 1, 'exec': 5, 'host_bash': 3, 'decision': 1, 'destroy': 1}
Sandbox ratio: 56%
```

No unclassified host commands — everything is accounted for.

---

# Example: Python project without Docker

sandshell is still useful when no container runtime is available.

## Environment

```
os=linux
arch=x86_64
runtime=none
native_sandbox=bubblewrap
cc_sandbox_configured=true
audit_hooks_configured=true
pipelock_available=false
```

## What happens

- **Tier 1 active:** bubblewrap enforces filesystem and network restrictions
- **Tier 2 unavailable:** agent skips container creation, informs user
- Writes restricted to project dir (kernel-enforced)
- Network restricted to `python` profile domains (kernel-enforced)
- All Bash commands logged by PostToolUse hook
- The agent recommends installing Docker for full isolation

Even without Docker, the developer gets:
- No writes outside the project
- No network access to unauthorized domains
- Full audit trail of everything the agent did
