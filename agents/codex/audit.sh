#!/usr/bin/env bash
# sandshell Codex CLI audit adapter.
#
# Reads ~/.codex/config.toml (or $CODEX_HOME/config.toml). Requires Python
# 3.11+ for tomllib; older Pythons get one info-level finding noting that
# Codex audit is unavailable in the current environment.
set -uo pipefail

is_codex_present() {
  command -v codex >/dev/null 2>&1 || [[ -d "$HOME/.codex" ]]
}

if ! is_codex_present; then
  exit 0
fi

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CONFIG="$CODEX_HOME/config.toml"

# If Codex is installed but no config file exists, that's worth a heads-up:
# the user may be running with implicit defaults, which on Codex are usually
# safe but worth confirming.
if [[ ! -f "$CONFIG" ]]; then
  jq -nc \
    --arg path "$CONFIG" \
    '{
      id: "codex.no_config",
      severity: "info",
      title: "Codex installed but no config.toml found at \($path)",
      fix: "Create \($path) with your safety preferences explicit, or rely on Codex defaults"
    }'
  exit 0
fi

exec python3 - "$CONFIG" <<'PY'
import json, sys, os

config_path = sys.argv[1]

COMPACT = {"separators": (",", ":")}

try:
    import tomllib
except ImportError:
    print(json.dumps({
        "id": "codex.audit_unavailable",
        "severity": "info",
        "title": "Codex audit requires Python 3.11+ (tomllib not available)",
        "fix": "Install Python 3.11+ or use a Python version that ships with tomllib",
        "details": "The Codex audit reads TOML config; older Python versions don't include a TOML parser in the standard library."
    }, **COMPACT))
    sys.exit(0)

try:
    with open(config_path, 'rb') as f:
        cfg = tomllib.load(f)
except (OSError, tomllib.TOMLDecodeError) as e:
    print(json.dumps({
        "id": "codex.parse_error",
        "severity": "info",
        "title": f"Could not parse Codex config: {e}",
        "scope": config_path,
        "fix": "Verify TOML syntax"
    }, **COMPACT))
    sys.exit(0)

def emit(id_, severity, title, scope=None, fix=None, details=None):
    f = {"id": id_, "severity": severity, "title": title}
    if scope:   f["scope"]   = scope
    if fix:     f["fix"]     = fix
    if details: f["details"] = details
    print(json.dumps(f, separators=(",", ":")))

# ---------- codex.sandbox_mode ----------
sandbox_mode = cfg.get("sandbox_mode")
if sandbox_mode == "danger-full-access":
    emit("codex.sandbox_mode", "high",
         f'Codex sandbox_mode is "danger-full-access" — agent runs unsandboxed by default',
         scope=config_path,
         fix='Set sandbox_mode = "workspace-write" (or "read-only") for the default')

# ---------- codex.approval_policy ----------
approval = cfg.get("approval_policy")
# approval_policy can be a string or a granular dict.
if isinstance(approval, str) and approval == "never":
    emit("codex.approval_policy", "medium",
         'Codex approval_policy is "never" — agent never asks before acting',
         scope=config_path,
         fix='Set approval_policy = "on-request" (or "untrusted") for the default')

# ---------- codex.network_access ----------
ws = cfg.get("sandbox_workspace_write", {})
if isinstance(ws, dict) and ws.get("network_access") is True:
    emit("codex.network_access", "medium",
         "Codex sandbox_workspace_write.network_access is true (agent has network in workspace mode)",
         scope=config_path,
         fix="Set network_access = false; gate per-task with CLI flag if needed")

# ---------- codex.writable_roots_bounded ----------
broad_paths = {"/", "~", os.environ.get("HOME", ""), f"{os.environ.get('HOME','')}/", "/Users", "/home"}
broad_paths.discard("")
writable_roots = ws.get("writable_roots", []) if isinstance(ws, dict) else []
if isinstance(writable_roots, list):
    for root in writable_roots:
        if not isinstance(root, str):
            continue
        if root in broad_paths or root.rstrip("/") in broad_paths:
            emit("codex.writable_roots_bounded", "medium",
                 f"Codex writable_roots includes broad path: '{root}'",
                 scope=config_path,
                 fix="Tighten writable_roots to specific project directories")
            break  # one finding per scope is enough

# ---------- codex.no_trusted_broad_dirs ----------
projects = cfg.get("projects", {})
if isinstance(projects, dict):
    for proj_path, proj_cfg in projects.items():
        if not isinstance(proj_cfg, dict):
            continue
        if proj_cfg.get("trust_level") != "trusted":
            continue
        if proj_path in broad_paths or proj_path.rstrip("/") in broad_paths:
            emit("codex.no_trusted_broad_dirs", "high",
                 f'Codex projects."{proj_path}" has trust_level = "trusted" — broad parent dir trusts every subproject',
                 scope=config_path,
                 fix="Remove the entry or narrow to a specific project")

# ---------- codex.granular_bypass ----------
# A granular approval policy can effectively be "never" if all knobs are off.
if isinstance(approval, dict) and "granular" in approval:
    g = approval.get("granular", {})
    if isinstance(g, dict):
        if g.get("sandbox_approval") is False and g.get("request_permissions") is False:
            emit("codex.approval_policy", "medium",
                 "Codex granular approval_policy disables both sandbox and permission prompts (effectively 'never')",
                 scope=config_path,
                 fix='Enable at least one of sandbox_approval or request_permissions, or use approval_policy = "on-request"')

# ---------- codex.trusted_projects.review ----------
# Info: enumerate trusted projects so the user can prune what they no longer need.
# Broad/risky paths are already covered by codex.no_trusted_broad_dirs above.
if isinstance(projects, dict):
    trusted_paths = [p for p, c in projects.items()
                     if isinstance(c, dict) and c.get("trust_level") == "trusted"]
    if trusted_paths:
        emit("codex.trusted_projects.review", "info",
             f"{len(trusted_paths)} Codex project(s) marked trust_level='trusted' — review periodically",
             scope=config_path,
             fix="Remove entries you no longer need",
             details="Trusted: " + ", ".join(trusted_paths))
PY
