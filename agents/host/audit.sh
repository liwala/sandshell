#!/usr/bin/env bash
# sandshell host audit adapter — cross-agent host checks.
#
# Emits NDJSON findings to stdout, one per line. Required fields: id, severity,
# title. Optional: scope, fix, details. Always exits 0; missing tools or files
# simply produce zero findings for that check rather than failing the run.
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

# Files we scan for aliases / env-var bypasses / persisted creds.
# Only files that actually exist are scanned.
shell_rc_files() {
  local f
  for f in \
    "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.bash_aliases" \
    "$HOME/.zshrc" "$HOME/.zshenv" "$HOME/.zprofile" "$HOME/.zlogin" \
    "$HOME/.profile" \
    "$HOME/.config/fish/config.fish" "$HOME/.config/fish/aliases.fish"; do
    [[ -f "$f" ]] && echo "$f"
  done
}

# ---------- host.shell_alias_bypass ----------
# Aliases for known agents that include known bypass flags.
check_shell_alias_bypass() {
  local agents='claude|codex|gemini|amp'
  local bypass_flags='--dangerously-skip-permissions|--full-auto|--dangerously-bypass-approvals-and-sandbox|--dangerously-allow-all|--yolo|--approval-mode=yolo'

  while IFS= read -r rc; do
    # Match: alias <agent>=...<bypass_flag>...
    # Or:    alias <agent> <agent>=...<bypass_flag>... (older shells)
    while IFS=: read -r lineno content; do
      [[ -z "$content" ]] && continue
      local agent_match flag_match
      agent_match=$(echo "$content" | grep -oE "alias[[:space:]]+($agents)=" | head -1 | sed -E "s/alias[[:space:]]+($agents)=/\1/" | head -c 32)
      flag_match=$(echo "$content" | grep -oE -e "$bypass_flags" | head -1)
      if [[ -n "$agent_match" && -n "$flag_match" ]]; then
        emit_finding \
          "host.shell_alias_bypass" \
          "critical" \
          "Alias '$agent_match' includes bypass flag '$flag_match'" \
          "$rc:$lineno" \
          "Remove '$flag_match' from the alias in $rc"
      fi
    done < <(grep -nE "alias[[:space:]]+($agents)=" "$rc" 2>/dev/null || true)
  done < <(shell_rc_files)
}

# ---------- host.env_bypass_var ----------
# Persisted env vars that disable safety, set in shell rc files.
check_env_bypass_var() {
  # Variable names known to bypass safety. Values that count as "set":
  #   anything other than empty string. We flag any export of these.
  local bypass_vars='CLAUDE_DANGEROUSLY_SKIP_PERMISSIONS|CLAUDE_SKIP_PERMISSIONS|GEMINI_SANDBOX'
  # Note: GEMINI_SANDBOX=false is the bypass; GEMINI_SANDBOX=true is fine.

  while IFS= read -r rc; do
    while IFS=: read -r lineno content; do
      [[ -z "$content" ]] && continue
      # Skip comment lines
      [[ "$content" =~ ^[[:space:]]*# ]] && continue
      local var
      var=$(echo "$content" | grep -oE "(export[[:space:]]+)?($bypass_vars)=[^[:space:]#]*" | head -1)
      [[ -z "$var" ]] && continue
      # GEMINI_SANDBOX=true is OK, =false is the bypass
      if [[ "$var" =~ ^(export[[:space:]]+)?GEMINI_SANDBOX=([Tt]rue|1) ]]; then
        continue
      fi
      emit_finding \
        "host.env_bypass_var" \
        "critical" \
        "Persistent env var bypasses agent safety: $var" \
        "$rc:$lineno" \
        "Remove the export from $rc"
    done < <(grep -nE "(export[[:space:]]+)?($bypass_vars)=" "$rc" 2>/dev/null || true)
  done < <(shell_rc_files)
}

# ---------- host.long_lived_creds ----------
# Long-lived credentials persisted in shell rc files. Flags export of common
# long-lived API keys without a paired session-token (which would suggest
# short-lived credentials).
check_long_lived_creds() {
  local cred_vars='AWS_ACCESS_KEY_ID|OPENAI_API_KEY|ANTHROPIC_API_KEY|GITHUB_TOKEN|GH_TOKEN|GOOGLE_API_KEY'

  while IFS= read -r rc; do
    while IFS=: read -r lineno content; do
      [[ -z "$content" ]] && continue
      [[ "$content" =~ ^[[:space:]]*# ]] && continue
      local var
      var=$(echo "$content" | grep -oE "(export[[:space:]]+)?($cred_vars)=" | head -1 | sed -E 's/^(export[[:space:]]+)?//; s/=$//')
      [[ -z "$var" ]] && continue
      # AWS: if AWS_SESSION_TOKEN is also exported in the same rc, treat as
      # short-lived (STS / SSO). Skip the warning.
      if [[ "$var" == "AWS_ACCESS_KEY_ID" ]] && grep -qE "(export[[:space:]]+)?AWS_SESSION_TOKEN=" "$rc" 2>/dev/null; then
        continue
      fi
      emit_finding \
        "host.long_lived_creds" \
        "high" \
        "Long-lived credential persisted in shell rc: $var" \
        "$rc:$lineno" \
        "Use short-lived tokens (STS, SSO, gh auth login) or load from a secrets manager at session start" \
        "Long-lived credentials in env give the agent persistent access to those services. Prefer ephemeral credentials, a separate user account for agent work, or sandshell's --strict mode to deny credential file reads."
    done < <(grep -nE "(export[[:space:]]+)?($cred_vars)=" "$rc" 2>/dev/null || true)
  done < <(shell_rc_files)
}

# ---------- host.native_sandbox_available ----------
# OS-native sandbox primitive present? macOS always has Seatbelt; Linux needs bwrap.
check_native_sandbox_available() {
  local os
  os="$(uname -s)"
  case "$os" in
    Darwin)
      if ! command -v sandbox-exec >/dev/null 2>&1; then
        emit_finding \
          "host.native_sandbox_available" \
          "medium" \
          "macOS sandbox-exec not found (this is unusual)" \
          "host" \
          "Reinstall macOS command-line tools or check PATH"
      fi
      ;;
    Linux)
      if ! command -v bwrap >/dev/null 2>&1; then
        emit_finding \
          "host.native_sandbox_available" \
          "medium" \
          "bubblewrap (bwrap) not installed; Claude Code's native sandbox needs it on Linux" \
          "host" \
          "apt install bubblewrap (Debian/Ubuntu) or your distro's equivalent"
      fi
      ;;
    *)
      emit_finding \
        "host.native_sandbox_available" \
        "medium" \
        "Unknown OS '$os' — sandshell can't verify native sandbox primitive" \
        "host" \
        "Sandshell's native-sandbox path supports macOS (Seatbelt) and Linux (bwrap)"
      ;;
  esac
}

# ---------- host.cwd_is_git_repo ----------
# The agent's working directory should be a git repo so changes are reviewable.
check_cwd_is_git_repo() {
  if ! command -v git >/dev/null 2>&1; then
    return 0  # No git installed; can't check, don't fire spurious finding.
  fi
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    emit_finding \
      "host.cwd_is_git_repo" \
      "high" \
      "Current directory is not a git repository" \
      "$(pwd)" \
      "git init (or move to a tracked repo) before running an agent here" \
      "Without revision control, agent changes can't be reviewed or reverted."
  fi
}

# ---------- host.repo_provenance ----------
# Compare the cwd's git remote against the user's known-repos allowlist.
# Info-only: this is a hint, not enforcement.
check_repo_provenance() {
  local known_repos="$HOME/.sandshell/known-repos.json"
  [[ -f "$known_repos" ]] || return 0
  command -v git >/dev/null 2>&1 || return 0
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  local remote
  remote="$(git remote get-url origin 2>/dev/null || true)"
  [[ -z "$remote" ]] && return 0

  if ! jq -e --arg r "$remote" 'index($r)' "$known_repos" >/dev/null 2>&1; then
    emit_finding \
      "host.repo_provenance" \
      "info" \
      "Working in repo with unknown provenance: $remote" \
      "$(pwd)" \
      "Add this remote to ~/.sandshell/known-repos.json if you trust it" \
      "Unfamiliar repos can contain malicious READMEs, build scripts, or test fixtures the agent might be steered into running."
  fi
}

# Run all checks. Each emits zero or more findings; aggregate to stdout.
check_shell_alias_bypass
check_env_bypass_var
check_long_lived_creds
check_native_sandbox_available
check_cwd_is_git_repo
check_repo_provenance
