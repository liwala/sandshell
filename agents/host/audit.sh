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
# Only files that actually exist are scanned. Includes cwd `.envrc` because
# direnv-loaded creds end up in the shell env an agent inherits.
#
# Out of scope (would need a runtime probe, not static parsing): launchd
# user agents (~/Library/LaunchAgents/*.plist + `launchctl setenv`),
# systemd user units, IDE run configs, macOS keychain hydration, and
# anything injected by an MCP server / wrapper. We audit the files that
# would populate a fresh shell, not the live env itself.
shell_rc_files() {
  local f
  for f in \
    "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.bash_aliases" \
    "$HOME/.zshrc" "$HOME/.zshenv" "$HOME/.zprofile" "$HOME/.zlogin" \
    "$HOME/.profile" \
    "$HOME/.config/fish/config.fish" "$HOME/.config/fish/aliases.fish" \
    "$PWD/.envrc"; do
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

# ---------- host.creds_in_shell_rc ----------
# Credential-shaped exports persisted in shell rc files, classified by how
# the value is injected. Static parsing only: we never see the live env
# (launchd, IDE, keychain, parent processes), so we can't claim a credential
# is "long-lived" — only that it's materialized as a literal in a file the
# shell sources, vs. fetched at session start from a known secrets manager.
#
# Classification of the RHS:
#   literal       — raw or quoted constant value           → emit medium
#   vault:<tool>  — $(op …), $(aws-vault …), $(vault …),   → silent
#                   $(pass …), $(bw …), $(chamber …),
#                   $(infisical …), $(lpass …), $(sops …),
#                   $(teller …), $(security …),
#                   $(keyring …), $(gcloud secrets …)
#   unknown:*     — backticks, $VAR forwarding,            → emit info
#                   or $(unrecognized-cmd ...)

# Returns one of: "literal", "vault:<tool>", "unknown:command",
# "unknown:varref", "empty". Stdout-only.
classify_cred_rhs() {
  local rhs="$1"
  rhs="$(echo "$rhs" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  # Strip ONE leading quote if the value is wrapped — we still scan inside.
  case "$rhs" in
    \"*) rhs="${rhs#\"}" ;;
    \'*) rhs="${rhs#\'}" ;;
  esac

  if [[ -z "$rhs" || "$rhs" == \"\" || "$rhs" == \'\' ]]; then
    echo "empty"
    return
  fi

  # Backtick command substitution. We don't try to classify which tool —
  # backticks are uncommon enough today that "unknown" is fine.
  if [[ "$rhs" =~ ^\` ]]; then
    echo "unknown:command"
    return
  fi

  # $(...) command substitution.
  if [[ "$rhs" =~ ^\$\([[:space:]]*([A-Za-z][A-Za-z0-9_-]*) ]]; then
    local cmd="${BASH_REMATCH[1]}"
    case "$cmd" in
      op|aws-vault|vault|pass|bw|chamber|infisical|lpass|sops|teller|security|keyring|gh|glab)
        echo "vault:$cmd"
        return
        ;;
      gcloud)
        # gcloud auth print-access-token (short-lived) and gcloud secrets
        # versions access (vault read) are both safe.
        if [[ "$rhs" =~ ^\$\([[:space:]]*gcloud[[:space:]]+(secrets|auth) ]]; then
          echo "vault:gcloud-${BASH_REMATCH[1]}"
          return
        fi
        ;;
      az)
        # az account get-access-token returns a short-lived MSAL token.
        if [[ "$rhs" =~ ^\$\([[:space:]]*az[[:space:]]+account[[:space:]]+get-access-token ]]; then
          echo "vault:az-token"
          return
        fi
        ;;
      aws)
        # aws sts get-session-token / get-caller-identity are short-lived.
        if [[ "$rhs" =~ ^\$\([[:space:]]*aws[[:space:]]+sts ]]; then
          echo "vault:aws-sts"
          return
        fi
        ;;
    esac
    echo "unknown:command"
    return
  fi

  # ${VAR} or $VAR forwarding from another env var. Could be a vault tool
  # exporting it earlier, could be a literal in another file — we can't tell.
  if [[ "$rhs" =~ ^\$\{ ]] || [[ "$rhs" =~ ^\$[A-Za-z_] ]]; then
    echo "unknown:varref"
    return
  fi

  echo "literal"
}

check_creds_in_shell_rc() {
  local cred_vars='AWS_ACCESS_KEY_ID|OPENAI_API_KEY|ANTHROPIC_API_KEY|GITHUB_TOKEN|GH_TOKEN|GOOGLE_API_KEY'

  while IFS= read -r rc; do
    while IFS=: read -r lineno content; do
      [[ -z "$content" ]] && continue
      [[ "$content" =~ ^[[:space:]]*# ]] && continue

      # Pull out the variable name and the raw RHS.
      local var rhs
      if [[ "$content" =~ (^|[[:space:]])(export[[:space:]]+)?($cred_vars)=(.*)$ ]]; then
        var="${BASH_REMATCH[3]}"
        rhs="${BASH_REMATCH[4]}"
      else
        continue
      fi

      # AWS: if AWS_SESSION_TOKEN is paired in the same file, the credential
      # is STS/SSO (short-lived) regardless of how it was injected. Skip.
      if [[ "$var" == "AWS_ACCESS_KEY_ID" ]] && \
         grep -qE "(export[[:space:]]+)?AWS_SESSION_TOKEN=" "$rc" 2>/dev/null; then
        continue
      fi

      # Trim a trailing inline comment (best-effort; doesn't account for
      # comments inside quoted values, but classification only inspects the
      # leading characters).
      rhs="${rhs%%#*}"

      local kind; kind="$(classify_cred_rhs "$rhs")"
      case "$kind" in
        literal)
          emit_finding \
            "host.creds_in_shell_rc" \
            "medium" \
            "Plaintext credential in shell rc: $var" \
            "$rc:$lineno" \
            "Load via a secrets manager (op, aws-vault, vault, pass, chamber, infisical, gcloud secrets) at session start, or move to a per-project .envrc that doesn't auto-load into every shell." \
            "source: literal value. Materialized in $rc, this credential ends up in every shell's environment — including any agent your shell launches."
          ;;
        vault:*)
          # Loaded via a known secrets manager — no finding. (Detected: ${kind#vault:}.)
          continue
          ;;
        unknown:command)
          emit_finding \
            "host.creds_in_shell_rc" \
            "info" \
            "Credential injection source not recognized: $var" \
            "$rc:$lineno" \
            "Verify the substitution invokes a secrets manager (op, aws-vault, vault, pass, bw, chamber, infisical, sops, teller, gcloud secrets). If it's a custom wrapper, this is fine; if it reads a literal from disk, treat it as plaintext." \
            "source: command substitution from an unrecognized tool."
          ;;
        unknown:varref)
          emit_finding \
            "host.creds_in_shell_rc" \
            "info" \
            "Credential forwarded from another variable: $var" \
            "$rc:$lineno" \
            "Trace where the source variable is defined. If it's loaded from a secrets manager at session start, this is fine; if it's a literal in another file, that file is the real exposure." \
            "source: \$VAR forwarding — sandshell can't see the upstream definition statically."
          ;;
        empty)
          continue
          ;;
      esac
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
check_creds_in_shell_rc
check_native_sandbox_available
check_cwd_is_git_repo
check_repo_provenance
