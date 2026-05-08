# Security Notes

This document describes what sandshell enforces, what it only guides or logs,
and the assumptions behind the first release.

## Support model

`0.1.0` has one sandshell-managed enforcement path and several adapter paths:

- Claude Code on macOS or Linux
- Native Claude sandbox configured by `scripts/setup-sandbox.sh`
- Claude Bash hooks configured by `scripts/setup-hooks.sh`
- Codex CLI, Gemini CLI, Amp, and other agents via installed sandshell
  instructions that lean on each agent's own native controls

Only the Claude Code path gets sandshell-managed settings and hooks. Codex gets
a dedicated adapter that points to Codex-native approval and sandbox modes.
Other agents get generic guidance and remain advisory unless the agent itself
has a comparable enforcement surface.

## Enforced vs advisory

### Enforced by sandshell-managed surfaces

- Claude native filesystem and network sandbox configured through settings.json
- Denial of `dangerouslyDisableSandbox` in Claude settings
- Optional `--strict` read restrictions for sensitive directories

### Enforced only through the agent's own surfaces

- Codex approval and sandbox modes when the user runs Codex in those modes
- Repo scoping or approval controls exposed by non-Claude agents

### Advisory or detection-oriented

- Claude `PreToolUse` Bash guard for obvious sandbox-disabling attempts
- Claude `PostToolUse` Bash logging
- Agent self-reporting of notable host-vs-sandbox decisions
- Skill-level guidance to treat fetched content as untrusted input
- Generic sandshell guidance for Codex, Gemini, Amp, and other agents

## Important limitations

- sandshell is not an external orchestrator. The main security boundary is
  Claude's native sandbox, not a separate runtime controller.
- On non-Claude agents, sandshell mainly provides policy guidance. Enforcement
  depends on the agent's own approval, sandbox, and workspace-scoping features.
- The Bash guard is intentionally narrow. It is meant to catch obvious
  protection-weakening commands, not to act as a complete command policy engine.
- The audit trail helps with observability and review; it does not turn an
  advisory workflow into a hard boundary.
- sandshell does not ship a content scanner. Fetched-content hygiene is
  behavioral guidance to the agent; Layers 1 and 2 are what contains the
  consequences if a prompt-injection attempt slips through.

## Adapter trust boundary

`scripts/audit-config.sh` discovers and runs every executable `audit.sh` under
`agents/<name>/` — there is no central registry. This makes adding a new agent
adapter a one-directory drop-in, but it also means any executable file at
`agents/*/audit.sh` in your sandshell checkout will run when you invoke
`sandshell audit`. Treat the `agents/` tree as code you've installed: review
any out-of-tree adapter before placing it there, and avoid pulling adapter
contributions from untrusted sources.

## Reporting

If you believe you found a sensitive issue in sandshell itself, avoid posting
full exploit details in a public issue before maintainers have had time to
assess it through a private channel available to your team or deployment.
