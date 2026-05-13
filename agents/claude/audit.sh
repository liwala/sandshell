#!/usr/bin/env bash
# sandshell Claude Code audit adapter.
#
# Reads safety settings from all four scopes (managed, user, project, and the
# *-local variants) plus MCP server config from ~/.claude.json and .mcp.json.
# Emits NDJSON findings to stdout. Self-skips if Claude Code isn't installed.
set -uo pipefail

# emit_finding ID SEVERITY TITLE [SCOPE] [FIX] [DETAILS]
emit_finding() {
  local id="$1" sev="$2" title="$3"
  local scope="${4:-}" fix="${5:-}" details="${6:-}"
  jq -nc \
    --arg id "$id" \
    --arg sev "$sev" \
    --arg title "$title" \
    --arg scope "$scope" \
    --arg fix "$fix" \
    --arg details "$details" \
    '{id: $id, severity: $sev, title: $title}
     + (if $scope   != "" then {scope: $scope}     else {} end)
     + (if $fix     != "" then {fix: $fix}         else {} end)
     + (if $details != "" then {details: $details} else {} end)'
}

# Resolve managed-settings path per OS.
managed_settings_path() {
  case "$(uname -s)" in
    Darwin) echo "/Library/Application Support/ClaudeCode/managed-settings.json" ;;
    Linux)  echo "/etc/claude-code/managed-settings.json" ;;
    *)      echo "" ;;
  esac
}

is_claude_present() {
  command -v claude >/dev/null 2>&1 \
    || [[ -d "$HOME/.claude" ]] \
    || [[ -f "$HOME/.claude.json" ]] \
    || [[ -d ".claude" ]]
}

# List existing settings scopes as "<scope-name> <path>" pairs.
# Order is significant: highest precedence first (managed → user → ...).
# Only scopes whose files exist, are readable, and parse as valid JSON.
existing_scopes() {
  local scope_pairs=(
    "managed:$(managed_settings_path)"
    "user:$HOME/.claude/settings.json"
    "user-local:$HOME/.claude/settings.local.json"
    "project:.claude/settings.json"
    "project-local:.claude/settings.local.json"
  )
  local pair scope path
  for pair in "${scope_pairs[@]}"; do
    scope="${pair%%:*}"
    path="${pair#*:}"
    [[ -z "$path" ]] && continue
    [[ -f "$path" ]] || continue
    if [[ ! -r "$path" ]]; then
      echo "WARNING: $path exists but is not readable; skipping" >&2
      continue
    fi
    if ! jq -e . "$path" >/dev/null 2>&1; then
      echo "WARNING: $path is not valid JSON; skipping" >&2
      continue
    fi
    echo "$scope $path"
  done
}

# ---------- cc.sandbox.enabled ----------
# Critical: sandbox.enabled is true in *no* scope = no enforcement.
check_sandbox_enabled() {
  local scope path
  while read -r scope path; do
    if jq -e '.sandbox.enabled == true' "$path" >/dev/null 2>&1; then
      return 0
    fi
  done < <(existing_scopes)

  emit_finding \
    "cc.sandbox.enabled" \
    "critical" \
    "Claude Code sandbox is not enabled in any settings scope" \
    "" \
    "sandshell apply --profile=default" \
    "Without sandbox.enabled=true, Claude Code does not enforce filesystem or network restrictions even if a sandbox block is present."
}

# ---------- cc.sandbox.silent_disable ----------
# Critical per scope: sandbox block present but enabled !== true.
check_sandbox_silent_disable() {
  local scope path
  while read -r scope path; do
    if jq -e '.sandbox' "$path" >/dev/null 2>&1; then
      if ! jq -e '.sandbox.enabled == true' "$path" >/dev/null 2>&1; then
        emit_finding \
          "cc.sandbox.silent_disable" \
          "critical" \
          "Sandbox block present in $scope scope but sandbox.enabled is not true" \
          "$path" \
          "sandshell apply (re-enable explicitly)" \
          "The sandbox block is inert unless sandbox.enabled is exactly true."
      fi
    fi
  done < <(existing_scopes)
}

# ---------- cc.sandbox.legacy_schema ----------
# Critical per scope: settings use v0.1's legacy field names that Claude Code's
# current sandbox does NOT enforce as expected. Notably `network.allowedHosts`
# is silently ignored (the documented field is `network.allowedDomains`).
# Detect any of: filesystem.write.allowOnly, filesystem.read.denyOnly,
# network.allowedHosts.
check_sandbox_legacy_schema() {
  local scope path
  while read -r scope path; do
    jq -e '
      (.sandbox.filesystem.write.allowOnly // null) != null
      or (.sandbox.filesystem.read.denyOnly // null) != null
      or (.sandbox.network.allowedHosts // null) != null
    ' "$path" >/dev/null 2>&1 || continue

    emit_finding \
      "cc.sandbox.legacy_schema" \
      "critical" \
      "Sandbox in $scope scope uses v0.1 legacy field names that Claude Code does not enforce" \
      "$path" \
      "sandshell apply (rewrites with allowWrite / denyRead / allowedDomains)" \
      "Old sandshell installs wrote filesystem.write.allowOnly, filesystem.read.denyOnly, and network.allowedHosts. Claude Code's current schema is filesystem.allowWrite, filesystem.denyRead, and network.allowedDomains; the legacy network field in particular is silently ignored, leaving outbound traffic unrestricted."
  done < <(existing_scopes)
}

# ---------- cc.sandbox.write_scope ----------
# High per scope: filesystem.allowWrite contains a broad path.
# (cwd is implicitly writable; allowWrite is for ADDITIONAL paths only.)
check_sandbox_write_scope() {
  local scope path broad
  while read -r scope path; do
    jq -e '.sandbox.filesystem.allowWrite' "$path" >/dev/null 2>&1 || continue
    broad=$(jq -r '.sandbox.filesystem.allowWrite[]?' "$path" 2>/dev/null \
            | grep -E '^(/|~|\$HOME|\*)$' | head -1 || true)
    if [[ -n "$broad" ]]; then
      emit_finding \
        "cc.sandbox.write_scope" \
        "high" \
        "Sandbox additional-write scope in $scope scope is too broad: '$broad' allows writes anywhere" \
        "$path" \
        "sandshell apply (re-bound to safe additional paths)"
    fi
  done < <(existing_scopes)
}

# ---------- cc.sandbox.network_allowlist ----------
# Medium/high per scope: allowedDomains missing, empty, or contains "*".
check_sandbox_network_allowlist() {
  local scope path
  while read -r scope path; do
    # Only check scopes where sandbox is actually enabled.
    jq -e '.sandbox.enabled == true' "$path" >/dev/null 2>&1 || continue

    if ! jq -e '.sandbox.network.allowedDomains' "$path" >/dev/null 2>&1; then
      emit_finding \
        "cc.sandbox.network_allowlist" \
        "medium" \
        "Sandbox enabled in $scope scope but sandbox.network.allowedDomains is missing" \
        "$path" \
        "sandshell apply --profile=<lang> (default, node, or python)" \
        "Note: Claude Code's macOS network proxy has an open bug (#37970) where allowedDomains may not enforce reliably for Bash subprocesses. See KNOWN_ISSUES.md."
      continue
    fi
    if jq -e '.sandbox.network.allowedDomains == []' "$path" >/dev/null 2>&1; then
      emit_finding \
        "cc.sandbox.network_allowlist_empty" \
        "high" \
        "Sandbox network.allowedDomains is empty in $scope scope (semantics ambiguous; may permit all outbound)" \
        "$path" \
        "sandshell apply --profile=default (or another non-empty profile)" \
        "Empty allowlists are not reliably interpreted as deny-all. Note also: macOS network enforcement is affected by upstream bug claude-code#37970 — see KNOWN_ISSUES.md."
      continue
    fi
    if jq -e '.sandbox.network.allowedDomains | index("*")' "$path" >/dev/null 2>&1; then
      emit_finding \
        "cc.sandbox.network_allowlist" \
        "medium" \
        "Sandbox allowedDomains in $scope scope contains '*' (no restriction)" \
        "$path" \
        "sandshell apply --profile=<lang>"
    fi
  done < <(existing_scopes)
}

# ---------- cc.sandbox.deny_disable_flag ----------
# High: when sandbox is enabled in a scope, permissions.deny should also list
# the dangerouslyDisableSandbox guard so the agent can't toggle it off mid-run.
check_sandbox_deny_disable_flag() {
  local scope path
  while read -r scope path; do
    jq -e '.sandbox.enabled == true' "$path" >/dev/null 2>&1 || continue
    if ! jq -e '
      (.permissions.deny // [])
      | map(select(test("dangerouslyDisableSandbox"; "i")))
      | length > 0
    ' "$path" >/dev/null 2>&1; then
      emit_finding \
        "cc.sandbox.deny_disable_flag" \
        "high" \
        "Sandbox enabled in $scope scope but permissions.deny does not block dangerouslyDisableSandbox" \
        "$path" \
        "sandshell apply (adds Bash(dangerouslyDisableSandbox:true) to permissions.deny)"
    fi
  done < <(existing_scopes)
}

# ---------- cc.sandbox.strict_reads ----------
# Info — aggregated across scopes: filesystem.denyRead should include common
# credential paths. The fix (sandshell apply --strict) is identical regardless
# of which scopes are missing it, so we surface a single finding listing all
# affected scopes rather than one finding per scope (which read as duplicates).
check_sandbox_strict_reads() {
  local scope path
  local missing_scopes=()
  while read -r scope path; do
    jq -e '.sandbox.enabled == true' "$path" >/dev/null 2>&1 || continue
    if ! jq -e '
      (.sandbox.filesystem.denyRead // [])
      | map(select(test("\\.ssh|\\.aws|\\.gnupg|\\.kube"; "i")))
      | length > 0
    ' "$path" >/dev/null 2>&1; then
      missing_scopes+=("$scope")
    fi
  done < <(existing_scopes)

  if [[ "${#missing_scopes[@]}" -gt 0 ]]; then
    # Build a ", "-joined list (IFS only uses the first char with ${arr[*]},
    # so we can't do this in one expansion — loop instead).
    local scope_list="" s
    for s in "${missing_scopes[@]}"; do
      [[ -n "$scope_list" ]] && scope_list+=", "
      scope_list+="$s"
    done
    emit_finding \
      "cc.sandbox.strict_reads" \
      "info" \
      "Sandbox does not deny reads to credential directories (~/.ssh, ~/.aws, etc.) in: $scope_list" \
      "" \
      "sandshell apply --strict"
  fi
}

# ---------- cc.permissions.no_wildcard_bash ----------
# High per scope: permissions.allow contains a wildcard *command* entry.
# Dangerous patterns: bare `Bash`, `Bash()`, `Bash(*)`, `Bash(*:*)`, `Bash(*:...)`.
# Safe patterns (do NOT flag): `Bash(npm test:*)`, `Bash(wc:*)`, `Bash(git status)`,
# anything with an explicit command prefix before the `:`.
check_permissions_no_wildcard_bash() {
  local scope path bad
  while read -r scope path; do
    bad=$(jq -r '.permissions.allow[]?' "$path" 2>/dev/null \
          | grep -E '^Bash($|\(\)$|\(\*\)$|\(\*:.*\)$)' | head -1 || true)
    if [[ -n "$bad" ]]; then
      emit_finding \
        "cc.permissions.no_wildcard_bash" \
        "high" \
        "Wildcard Bash permission in $scope scope: '$bad' allows any command" \
        "$path" \
        "Remove the wildcard; allow specific commands only (e.g. Bash(npm test:*))"
    fi
  done < <(existing_scopes)
}

# ---------- cc.permissions.no_curl_pipe_sh ----------
# High per scope: permissions.allow blanket-permits curl|bash or wget|sh patterns.
check_permissions_no_curl_pipe_sh() {
  local scope path bad
  while read -r scope path; do
    bad=$(jq -r '.permissions.allow[]?' "$path" 2>/dev/null \
          | grep -E 'Bash\(.*(curl|wget).*(\||\$\().*(sh|bash).*\)' | head -1 || true)
    if [[ -n "$bad" ]]; then
      emit_finding \
        "cc.permissions.no_curl_pipe_sh" \
        "high" \
        "Permissions in $scope scope allow piping fetched content to a shell: '$bad'" \
        "$path" \
        "Remove the entry; fetch and inspect before executing"
    fi
  done < <(existing_scopes)
}

# ---------- cc.hooks.pre_bash ----------
# Medium: no scope wires up the PreToolUse Bash guard.
check_hooks_pre_bash() {
  local scope path
  while read -r scope path; do
    if jq -e '
      (.hooks.PreToolUse // [])
      | map(select(.matcher == "Bash"))
      | map(.hooks[]? | .command // "")
      | map(select(test("hook-pre-bash\\.sh"; "i")))
      | length > 0
    ' "$path" >/dev/null 2>&1; then
      return 0
    fi
  done < <(existing_scopes)

  emit_finding \
    "cc.hooks.pre_bash" \
    "medium" \
    "Claude Code PreToolUse Bash guard hook is not configured" \
    "" \
    "sandshell apply (or scripts/setup-hooks.sh user)" \
    "The pre-hook blocks obvious sandbox-disable attempts; it's a narrow guard, not the main wall."
}

# ---------- cc.hooks.post_bash ----------
# Info: no scope wires up the PostToolUse audit-trail hook.
check_hooks_post_bash() {
  local scope path
  while read -r scope path; do
    if jq -e '
      (.hooks.PostToolUse // [])
      | map(select(.matcher == "Bash"))
      | map(.hooks[]? | .command // "")
      | map(select(test("hook-post-bash\\.sh"; "i")))
      | length > 0
    ' "$path" >/dev/null 2>&1; then
      return 0
    fi
  done < <(existing_scopes)

  emit_finding \
    "cc.hooks.post_bash" \
    "info" \
    "Claude Code PostToolUse audit-trail hook is not configured" \
    "" \
    "sandshell apply" \
    "The post-hook writes session JSONL into ~/.sandshell/audit/ for retrospective review."
}

# ---------- cc.mcp.curated ----------
# Medium per unknown server: an MCP appears in user-scope or project-scope
# config but isn't in the user's curated allowlist at ~/.sandshell/known-mcps.json.
# If the allowlist file doesn't exist, this check stays silent (info-level
# omission, not a finding — first-run users will see this on bootstrap).
check_mcp_curated() {
  local known="$HOME/.sandshell/known-mcps.json"
  [[ -f "$known" ]] || return 0
  jq -e 'type == "array"' "$known" >/dev/null 2>&1 || {
    echo "WARNING: $known is not a JSON array; skipping MCP curation check" >&2
    return 0
  }

  # Collect all configured MCP server names with their source.
  # Source 1: ~/.claude.json — anywhere a "mcpServers" key appears.
  # Source 2: project-root .mcp.json — a top-level mcpServers object.
  local user_claude="$HOME/.claude.json"
  if [[ -f "$user_claude" ]] && jq -e . "$user_claude" >/dev/null 2>&1; then
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      if ! jq -e --arg n "$name" 'index($n)' "$known" >/dev/null 2>&1; then
        emit_finding \
          "cc.mcp.curated" \
          "medium" \
          "Unknown MCP server '$name' in user MCP config" \
          "$user_claude" \
          "Review the server; add to ~/.sandshell/known-mcps.json if trusted, or remove via 'claude mcp remove $name'"
      fi
    done < <(jq -r '[.. | objects | select(has("mcpServers")) | .mcpServers | keys[]?] | unique[]?' "$user_claude" 2>/dev/null)
  fi
  if [[ -f ".mcp.json" ]] && jq -e . ".mcp.json" >/dev/null 2>&1; then
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      if ! jq -e --arg n "$name" 'index($n)' "$known" >/dev/null 2>&1; then
        emit_finding \
          "cc.mcp.curated" \
          "medium" \
          "Unknown MCP server '$name' in project MCP config" \
          ".mcp.json" \
          "Review the server; add to ~/.sandshell/known-mcps.json if trusted, or remove from .mcp.json"
      fi
    done < <(jq -r '.mcpServers // {} | keys[]?' ".mcp.json" 2>/dev/null)
  fi
}

# ---------- cc.mcp.project_auto_approve ----------
# High per scope: enableAllProjectMcpServers === true silently auto-approves
# every project's MCP servers. Negates the point of curating MCPs.
check_mcp_project_auto_approve() {
  local scope path
  while read -r scope path; do
    if jq -e '.enableAllProjectMcpServers == true' "$path" >/dev/null 2>&1; then
      emit_finding \
        "cc.mcp.project_auto_approve" \
        "high" \
        "enableAllProjectMcpServers is true in $scope scope (auto-approves every project's MCP servers)" \
        "$path" \
        "Remove the setting or set to false; approve project MCPs explicitly via claude mcp"
    fi
  done < <(existing_scopes)
}

# ---------- cc.permissions.review ----------
# Info — aggregated across scopes: enumerate the user's approved Bash/tool
# permissions so they can periodically prune entries they no longer need.
# Lists are useful even when individual entries pass the no-wildcard /
# no-curl-pipe-sh checks. Emitted as a single rolled-up finding regardless of
# how many scopes contribute (per-scope emission read as duplicates).
check_permissions_review() {
  local scope path count
  local total=0
  local scope_summary=""
  local details=""
  while read -r scope path; do
    count=$(jq -r '(.permissions.allow // []) | length' "$path" 2>/dev/null || echo 0)
    [[ "$count" == "0" ]] && continue
    total=$((total + count))
    [[ -n "$scope_summary" ]] && scope_summary+=", "
    scope_summary+="$scope ($count)"
    local list
    list=$(jq -r '(.permissions.allow // []) | join(", ")' "$path" 2>/dev/null)
    [[ -n "$details" ]] && details+=$'\n'
    details+="$scope: $list"
  done < <(existing_scopes)

  if [[ "$total" -gt 0 ]]; then
    emit_finding \
      "cc.permissions.review" \
      "info" \
      "$total approved Bash/tool permission(s) across scopes ($scope_summary) — review periodically" \
      "" \
      "Run 'sandshell prune-permissions' to remove entries you no longer need" \
      "$details"
  fi
}

if ! is_claude_present; then
  exit 0
fi

check_sandbox_enabled
check_sandbox_silent_disable
check_sandbox_legacy_schema
check_sandbox_write_scope
check_sandbox_network_allowlist
check_sandbox_deny_disable_flag
check_sandbox_strict_reads
check_permissions_no_wildcard_bash
check_permissions_no_curl_pipe_sh
check_permissions_review
check_hooks_pre_bash
check_hooks_post_bash
check_mcp_curated
check_mcp_project_auto_approve
