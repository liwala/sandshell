# Security Notes

This document describes what sandshell enforces, what it only guides or logs,
and the assumptions behind the first release.

## Primary supported path

The primary supported path for `0.1.0` is:

- Claude Code
- macOS or Linux
- Native Claude sandbox configured by `scripts/setup-sandbox.sh`
- Claude Bash hooks configured by `scripts/setup-hooks.sh`
- Optional Pipelock detection

Codex CLI, Gemini CLI, and Amp are secondary paths for this release. They can
use installed instructions, but they do not get the same setup, hook, and
verification path as Claude Code.

## Enforced vs advisory

### Enforced

- Claude native filesystem and network sandbox configured through settings.json
- Denial of `dangerouslyDisableSandbox` in Claude settings
- Optional `--strict` read restrictions for sensitive directories

### Advisory or detection-oriented

- Claude `PreToolUse` Bash guard for obvious sandbox-disabling attempts
- Claude `PostToolUse` Bash logging
- Agent self-reporting of notable host-vs-sandbox decisions
- Pipelock-based prompt-injection scanning
- Non-Claude agent behavior

## Important limitations

- sandshell is not an external orchestrator. The main security boundary is
  Claude's native sandbox, not a separate runtime controller.
- The Bash guard is intentionally narrow. It is meant to catch obvious
  protection-weakening commands, not to act as a complete command policy engine.
- The audit trail helps with observability and review; it does not turn an
  advisory workflow into a hard boundary.
- Pipelock is optional and content scanning is best-effort.

## Reporting

If you believe you found a sensitive issue in sandshell itself, avoid posting
full exploit details in a public issue before maintainers have had time to
assess it through a private channel available to your team or deployment.
