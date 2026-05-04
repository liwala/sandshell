#!/usr/bin/env bash
# sandshell Gemini CLI audit adapter.
#
# Reads ~/.gemini/settings.json (user) and ./.gemini/settings.json (project;
# Gemini's docs call this scope "workspace"; precedence: project > user), plus
# ~/.gemini/trustedFolders.json. Self-skips if Gemini CLI isn't installed.
set -uo pipefail

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

is_gemini_present() {
  command -v gemini >/dev/null 2>&1 \
    || [[ -d "$HOME/.gemini" ]] \
    || [[ -d ".gemini" ]]
}

if ! is_gemini_present; then
  exit 0
fi

USER_CFG="$HOME/.gemini/settings.json"
WORKSPACE_CFG=".gemini/settings.json"
TRUSTED_FOLDERS="$HOME/.gemini/trustedFolders.json"

# List existing settings scopes as "<scope> <path>" pairs (project > user precedence).
existing_scopes() {
  local pair
  for pair in "project:$WORKSPACE_CFG" "user:$USER_CFG"; do
    local scope="${pair%%:*}"
    local path="${pair#*:}"
    [[ -f "$path" ]] || continue
    if ! jq -e . "$path" >/dev/null 2>&1; then
      echo "WARNING: $path is not valid JSON; skipping" >&2
      continue
    fi
    echo "$scope $path"
  done
}

# Helper: does any scope satisfy the given jq filter?
any_scope_matches() {
  local filter="$1"
  local scope path
  while read -r scope path; do
    if jq -e "$filter" "$path" >/dev/null 2>&1; then
      return 0
    fi
  done < <(existing_scopes)
  return 1
}

# ---------- gemini.sandbox_enabled ----------
# tools.sandbox truthy in at least one scope. Truthy = true, or string in
# {"docker","podman","sandbox-exec","runsc","lxc"}, or object form.
# Falsy = false, null, missing.
check_sandbox_enabled() {
  if any_scope_matches '
    .tools.sandbox
    | (. == true)
      or (type == "string" and (. | IN("docker","podman","sandbox-exec","runsc","lxc")))
      or (type == "object")
  '; then
    return 0
  fi
  emit_finding \
    "gemini.sandbox_enabled" \
    "critical" \
    "Gemini CLI sandbox is not configured (tools.sandbox is missing or false)" \
    "" \
    "Set tools.sandbox in $USER_CFG to a supported provider (docker, podman, sandbox-exec, runsc, lxc, or true)" \
    "Without a sandbox, Gemini's tool calls run with the same access as your shell."
}

# ---------- gemini.sandbox_network_off ----------
# Per-scope: tools.sandboxNetworkAccess === true.
check_sandbox_network_off() {
  local scope path
  while read -r scope path; do
    if jq -e '.tools.sandboxNetworkAccess == true' "$path" >/dev/null 2>&1; then
      emit_finding \
        "gemini.sandbox_network_off" \
        "medium" \
        "Gemini sandbox network access is enabled in $scope scope" \
        "$path" \
        "Set tools.sandboxNetworkAccess = false; gate per-task if needed"
    fi
  done < <(existing_scopes)
}

# ---------- gemini.sandbox_paths_bounded ----------
# Per-scope: tools.sandboxAllowedPaths contains broad paths.
check_sandbox_paths_bounded() {
  local scope path broad
  while read -r scope path; do
    jq -e '.tools.sandboxAllowedPaths' "$path" >/dev/null 2>&1 || continue
    broad=$(jq -r '.tools.sandboxAllowedPaths[]?' "$path" 2>/dev/null \
            | grep -E '^(/|~|\$HOME|/Users|/home)/?$' | head -1 || true)
    if [[ -n "$broad" ]]; then
      emit_finding \
        "gemini.sandbox_paths_bounded" \
        "medium" \
        "Gemini sandboxAllowedPaths in $scope scope contains broad path: '$broad'" \
        "$path" \
        "Tighten tools.sandboxAllowedPaths to specific project directories"
    fi
  done < <(existing_scopes)
}

# ---------- gemini.folder_trust_enabled ----------
# At least one scope has security.folderTrust.enabled === true.
check_folder_trust_enabled() {
  if any_scope_matches '.security.folderTrust.enabled == true'; then
    return 0
  fi
  emit_finding \
    "gemini.folder_trust_enabled" \
    "high" \
    "Gemini folder trust is not enabled" \
    "" \
    "Set security.folderTrust.enabled = true in $USER_CFG" \
    "Folder trust gates auto-edit and other elevated permissions to directories you've explicitly approved."
}

# ---------- gemini.disable_yolo ----------
# At least one scope has security.disableYoloMode === true.
check_disable_yolo() {
  if any_scope_matches '.security.disableYoloMode == true'; then
    return 0
  fi
  emit_finding \
    "gemini.disable_yolo" \
    "high" \
    "Gemini YOLO mode is not disabled" \
    "" \
    "Set security.disableYoloMode = true in $USER_CFG" \
    "YOLO mode bypasses approval prompts; disabling it forces explicit confirmation for risky tools."
}

# ---------- gemini.disable_always_allow ----------
# At least one scope has security.disableAlwaysAllow === true.
check_disable_always_allow() {
  if any_scope_matches '.security.disableAlwaysAllow == true'; then
    return 0
  fi
  emit_finding \
    "gemini.disable_always_allow" \
    "medium" \
    "Gemini 'Always allow' is not disabled" \
    "" \
    "Set security.disableAlwaysAllow = true in $USER_CFG" \
    "When enabled, 'Always allow' lets users mark tools as auto-approved indefinitely; disabling it keeps prompts in front of the user."
}

# ---------- gemini.approval_mode ----------
# Per-scope: general.defaultApprovalMode === "auto_edit".
check_approval_mode() {
  local scope path
  while read -r scope path; do
    if jq -e '.general.defaultApprovalMode == "auto_edit"' "$path" >/dev/null 2>&1; then
      emit_finding \
        "gemini.approval_mode" \
        "medium" \
        "Gemini default approval mode is 'auto_edit' in $scope scope (auto-applies edits without prompt)" \
        "$path" \
        "Set general.defaultApprovalMode = \"default\" or \"plan\""
    fi
  done < <(existing_scopes)
}

# ---------- gemini.trusted_folders_bounded ----------
# trustedFolders.json contains a broad path entry.
check_trusted_folders_bounded() {
  [[ -f "$TRUSTED_FOLDERS" ]] || return 0
  jq -e . "$TRUSTED_FOLDERS" >/dev/null 2>&1 || return 0
  # Heuristic: extract all string keys (object form) and string values that
  # look like paths. Flag any broad pattern.
  local broad
  broad=$(jq -r '
    (if type == "object" then keys[] else (.[]? // empty) end)
    | select(type == "string")
  ' "$TRUSTED_FOLDERS" 2>/dev/null \
    | grep -E '^(/|~|\$HOME|/Users|/home)/?$' | head -1 || true)
  if [[ -n "$broad" ]]; then
    emit_finding \
      "gemini.trusted_folders_bounded" \
      "high" \
      "Gemini trustedFolders.json contains broad path: '$broad'" \
      "$TRUSTED_FOLDERS" \
      "Remove the broad entry; trust specific project directories only"
  fi
}

# ---------- gemini.trusted_folders.review ----------
# Info: enumerate trusted folders so the user can prune what they no longer need.
check_trusted_folders_review() {
  [[ -f "$TRUSTED_FOLDERS" ]] || return 0
  jq -e . "$TRUSTED_FOLDERS" >/dev/null 2>&1 || return 0
  local list count
  list=$(jq -r '
    (if type == "object" then keys[] else (.[]? // empty) end)
    | select(type == "string")
  ' "$TRUSTED_FOLDERS" 2>/dev/null | paste -sd, - || true)
  count=$(echo "$list" | tr ',' '\n' | grep -c . || true)
  [[ "$count" == "0" ]] && return 0
  emit_finding \
    "gemini.trusted_folders.review" \
    "info" \
    "$count Gemini trusted folder(s) — review periodically" \
    "$TRUSTED_FOLDERS" \
    "Remove entries you no longer need" \
    "Trusted: $list"
}

# ---------- gemini.guidance_present ----------
# GEMINI.md (project or user) has sandshell guidance block.
check_guidance_present() {
  local found=false
  local f
  for f in "GEMINI.md" "$HOME/GEMINI.md"; do
    [[ -f "$f" ]] || continue
    if grep -q "sandshell" "$f" 2>/dev/null; then
      found=true
      break
    fi
  done
  if [[ "$found" == false ]]; then
    emit_finding \
      "gemini.guidance_present" \
      "info" \
      "GEMINI.md does not reference sandshell guidance" \
      "" \
      "Run scripts/install-agent.sh gemini" \
      "Adds sandshell's safety reminders into Gemini's instruction context."
  fi
}

check_sandbox_enabled
check_sandbox_network_off
check_sandbox_paths_bounded
check_folder_trust_enabled
check_disable_yolo
check_disable_always_allow
check_approval_mode
check_trusted_folders_bounded
check_trusted_folders_review
check_guidance_present
