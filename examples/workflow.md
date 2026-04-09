# Example: Sandboxed Node.js Development

This shows what a sandshell-protected Claude Code session looks like.

## Session start

The skill auto-activates. `detect.sh` runs and reports:

```
os=darwin
arch=arm64
docker_available=true
docker_path=/usr/local/bin/docker
docker_version=24.0.7
runtime=docker
```

## Agent creates sandbox

Claude detects `package.json` in the workspace and creates a sandbox with
the Node.js network profile:

```bash
sandbox.sh create sandshell-a1b2c3d4
harden.sh sandshell-a1b2c3d4 --profile=node
```

## Agent works inside sandbox

```bash
# Install dependencies (inside sandbox)
sandbox.sh exec sandshell-a1b2c3d4 npm install

# Run tests (inside sandbox)
sandbox.sh exec sandshell-a1b2c3d4 npm test

# Build (inside sandbox)
sandbox.sh exec sandshell-a1b2c3d4 npm run build
```

## Host commands (logged with reason)

```bash
# These run on host — agent logs the decision
git add -A
git commit -m "feat: add user profile page"
git push origin feature-branch
gh pr create --title "Add user profile page"
```

## Cleanup

```bash
sandbox.sh destroy sandshell-a1b2c3d4
```

## Audit trail

```
$ audit.sh summary a1b2c3d4

Session: a1b2c3d4
Total operations: 8
Sandbox commands: 4
Host commands: 3
Failures: 0
Operations: {'session_start': 1, 'create': 1, 'harden': 1, 'exec': 3, 'host_cmd': 1, 'destroy': 1}
Sandbox ratio: 80%
```
