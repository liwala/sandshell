# Known issues affecting sandshell

Upstream bugs in sandshell's dependencies (Claude Code, Codex CLI, Gemini CLI)
that limit what sandshell can deliver today. Sandshell writes correct config
per the documented schemas; when upstream fixes land, our users get the
benefit automatically without any action on our side.

If you hit one of these, the issue isn't sandshell — it's a tracked upstream
limitation. Sandshell's audit checks reference these entries via their
`details` field so you see the caveat at the moment a finding fires.

## Active

### Gemini CLI — Network restriction not enforced under sandbox-exec on macOS

- **Tracking:** [google-gemini/gemini-cli#20381](https://github.com/google-gemini/gemini-cli/issues/20381) (proposal for the missing layer), [#20046](https://github.com/google-gemini/gemini-cli/issues/20046) (V1 macOS post-intent execution, includes "blocks network" in scope)
- **First observed in sandshell:** 2026-04-30 — empirical test confirmed `tools.sandbox = "sandbox-exec"` + `tools.sandboxNetworkAccess = false` does not block `curl https://example.com`. Gemini just shows its generic per-command permission prompt with no sandbox-failure framing.
- **Impact:** Architectural, not a bug. Gemini CLI ships six built-in Seatbelt profiles (`packages/cli/src/utils/sandboxUtils.ts`), all of which either `(allow network-outbound)` or route to a localhost proxy. There's no closed/no-network profile. The `sandboxNetworkAccess` setting is only consumed in the Docker/Podman branch (`packages/cli/src/utils/sandbox.ts:474–487`), where it sets `--internal` on the Docker network.
- **What sandshell does today:** `sandshell apply gemini` writes `tools.sandboxNetworkAccess = false` (forward-correct + works under docker/podman). The post-apply message explicitly warns that on macOS+sandbox-exec, the setting is silently ignored and recommends `tools.sandbox = "docker"` or a manual proxy at `localhost:8877` for real network containment.
- **Workaround for tasks needing real network containment with Gemini on macOS:**
  - `tools.sandbox = "docker"` (requires Docker installed; uses `--internal` network)
  - Or set `SEATBELT_PROFILE=permissive-proxied` and run a proxy via `GEMINI_SANDBOX_PROXY_COMMAND` listening on `localhost:8877`
  - Or use a different agent (Codex's macOS sandbox enforces network at the kernel via Seatbelt MAC; see notes below)

### Claude Code — Network sandbox not enforcing on macOS

- **Tracking:** [anthropics/claude-code#37970](https://github.com/anthropics/claude-code/issues/37970)
- **Related:** [#37782](https://github.com/anthropics/claude-code/issues/37782) (Node.js DNS bypass), [#26466](https://github.com/anthropics/claude-code/issues/26466) (Go tools fail TLS through proxy)
- **First observed in sandshell:** 2026-04-30 — `sandshell apply --profile=default` written correctly per the documented schema (`sandbox.network.allowedDomains`), Claude Code's HTTPS proxy engaged (`HTTP_PROXY` env var set on subprocesses), but `curl https://example.com` from a sandboxed Bash session returns HTTP 200 even though `example.com` is not in the allowlist.
- **Impact:** `sandbox.network.allowedDomains` does not reliably block outbound traffic from Bash subprocesses on macOS. Filesystem isolation works; network isolation does not.
- **What sandshell does today:** Continues to write the correct schema so apply is forward-correct when upstream fixes land. Audit's `cc.sandbox.network_allowlist` and `cc.sandbox.network_allowlist_empty` checks fire when the configuration looks broken, but their `details` note that even a correctly-populated allowlist may not enforce on macOS pending #37970.
- **Workaround for tasks that genuinely need network containment:** Run in Docker `sbx` (microVM-based; not affected) or another isolation layer with verifiable network enforcement. Sandshell + Claude Code's filesystem sandbox is sufficient for most "edit code in a known repo" workflows.

## Notes (not bugs)

### Codex CLI — macOS network sandbox is real MAC and works as documented

For contrast and context: **Codex's macOS sandbox is the strongest of the three major coding agents**. It uses `/usr/bin/sandbox-exec` with a Seatbelt policy whose base is `(deny default)` (`codex-rs/sandboxing/src/seatbelt_base_policy.sbpl:8`); network rules are additive, only emitted when `network_access = true`. With `network_access = false`, no `(allow network-outbound)` is generated, so Seatbelt blocks all outbound TCP/UDP at the kernel for the entire spawned process tree.

Empirical verification (2026-04-30): inside Codex with `network_access = false`, `curl https://example.com` fails with `curl: (6) Could not resolve host: example.com` (DNS UDP blocked by Seatbelt), then Codex surfaces an explicit "Do you want to allow network access so I can run `curl ...`?" escalation — meaningful security UX.

Source: `codex-rs/sandboxing/src/seatbelt.rs` (lines 30, 308–319), `seatbelt_base_policy.sbpl` line 8.

This means: when sandshell's audit catches a workflow that genuinely needs network containment, Codex is a viable on-machine alternative to Docker `sbx`, not just a config-only safety win.

## Resolved

*(none yet — entries move here when upstream confirms a fix)*
