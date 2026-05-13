#!/usr/bin/env bash
# sandshell: prune Claude Code permissions.allow entries across all scopes.
#
# The cc.permissions.review audit finding nudges users to review approved
# Bash/tool permissions periodically, but those entries live in up to four
# settings.json files (user, user-local, project, project-local). Editing
# each by hand is friction; this script enumerates them with global indices
# and applies surgical jq removes. The 'managed' scope is admin-owned and
# never touched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/diff-apply.sh
. "$SCRIPT_DIR/lib/diff-apply.sh"

usage() {
  cat <<EOF
Usage: sandshell prune-permissions [options]

Interactively prune entries from .permissions.allow across all Claude Code
settings.json scopes (user, user-local, project, project-local).

Options:
  --scope=SCOPE          Limit to one scope (user|user-local|project|project-local).
                         Default: all four.
  --remove=INDICES       Non-interactive: remove the listed global indices
                         (e.g. "1,3,5" or "1,3,5-7" or "all").
  --remove-matching=STR  Non-interactive: remove entries whose value contains
                         this substring (case-sensitive).
  --dry-run              Show planned changes without writing.
  -y, --yes              Skip the confirmation prompt.
  -h, --help             Show this message.

Behavior:
  - Writes atomically via jq; preserves all other settings.json keys.
  - Prints a unified diff per file changed (via lib/diff-apply.sh).
  - With no flags, runs interactively and prompts for indices.

Examples:
  sandshell prune-permissions
  sandshell prune-permissions --remove=1,3,5 --yes
  sandshell prune-permissions --remove-matching=foobar --yes
  sandshell prune-permissions --scope=project-local --dry-run
EOF
}

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required for prune-permissions." >&2
  exit 1
fi

SCOPE_FILTER=""
REMOVE_INDICES=""
REMOVE_MATCHING=""
DRY_RUN=false
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope=*)          SCOPE_FILTER="${1#--scope=}"; shift ;;
    --remove=*)         REMOVE_INDICES="${1#--remove=}"; shift ;;
    --remove-matching=*) REMOVE_MATCHING="${1#--remove-matching=}"; shift ;;
    --dry-run)          DRY_RUN=true; shift ;;
    -y|--yes)           ASSUME_YES=true; shift ;;
    -h|--help|help)     usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# Resolve candidate scopes. Mirrors agents/claude/audit.sh::existing_scopes
# but excludes 'managed' (admin-owned, read-only).
HOME_CLAUDE_SETTINGS="$HOME/.claude/settings.json"
HOME_CLAUDE_LOCAL="$HOME/.claude/settings.local.json"
SCOPE_PAIRS=(
  "user:$HOME_CLAUDE_SETTINGS"
  "user-local:$HOME_CLAUDE_LOCAL"
  "project:.claude/settings.json"
  "project-local:.claude/settings.local.json"
)

# Collected entries: parallel arrays indexed by global position (1-based).
ENTRY_SCOPES=()
ENTRY_PATHS=()
ENTRY_VALUES=()

for pair in "${SCOPE_PAIRS[@]}"; do
  scope="${pair%%:*}"
  path="${pair#*:}"
  if [[ -n "$SCOPE_FILTER" && "$scope" != "$SCOPE_FILTER" ]]; then continue; fi
  [[ -f "$path" ]] || continue
  if ! jq -e . "$path" >/dev/null 2>&1; then
    echo "WARNING: $path is not valid JSON; skipping" >&2
    continue
  fi
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    ENTRY_SCOPES+=("$scope")
    ENTRY_PATHS+=("$path")
    ENTRY_VALUES+=("$entry")
  done < <(jq -r '(.permissions.allow // [])[]' "$path" 2>/dev/null)
done

TOTAL=${#ENTRY_VALUES[@]}

if [[ "$TOTAL" -eq 0 ]]; then
  if [[ -n "$SCOPE_FILTER" ]]; then
    echo "No permissions.allow entries in scope '$SCOPE_FILTER'."
  else
    echo "No permissions.allow entries found across any scope."
  fi
  exit 0
fi

list_entries() {
  echo "Approved permissions ($TOTAL total):"
  echo ""
  local i width=${#TOTAL}
  for ((i=0; i<TOTAL; i++)); do
    printf "  %${width}d.  %-15s  %s\n" "$((i+1))" "${ENTRY_SCOPES[i]}" "${ENTRY_VALUES[i]}"
  done
  echo ""
}

# Parse "1,3,5-7" or "all" into a sorted unique list of 1-based indices,
# printed one per line.
parse_indices() {
  local input="$1"
  if [[ "$input" == "all" ]]; then
    seq 1 "$TOTAL"
    return
  fi
  local part lo hi i
  IFS=',' read -ra parts <<< "$input"
  for part in "${parts[@]}"; do
    part="${part//[[:space:]]/}"
    [[ -z "$part" ]] && continue
    if [[ "$part" == *-* ]]; then
      lo="${part%-*}"
      hi="${part#*-}"
      if [[ ! "$lo" =~ ^[0-9]+$ || ! "$hi" =~ ^[0-9]+$ ]]; then
        echo "Invalid range: $part" >&2; return 1
      fi
      for ((i=lo; i<=hi; i++)); do echo "$i"; done
    else
      if [[ ! "$part" =~ ^[0-9]+$ ]]; then
        echo "Invalid index: $part" >&2; return 1
      fi
      echo "$part"
    fi
  done | sort -nu
}

list_entries

# Determine which indices to remove.
TARGETS=()
if [[ -n "$REMOVE_INDICES" ]]; then
  while IFS= read -r idx; do TARGETS+=("$idx"); done < <(parse_indices "$REMOVE_INDICES")
elif [[ -n "$REMOVE_MATCHING" ]]; then
  for ((i=0; i<TOTAL; i++)); do
    if [[ "${ENTRY_VALUES[i]}" == *"$REMOVE_MATCHING"* ]]; then
      TARGETS+=("$((i+1))")
    fi
  done
  if [[ "${#TARGETS[@]}" -eq 0 ]]; then
    echo "No entries match substring: $REMOVE_MATCHING"
    exit 0
  fi
else
  # Interactive prompt. Skipped entirely under --yes (which makes no sense
  # without --remove= or --remove-matching=, so we bail).
  if [[ "$ASSUME_YES" = true ]]; then
    echo "ERROR: --yes requires --remove= or --remove-matching=" >&2
    exit 1
  fi
  printf 'Enter indices to remove (e.g. "1,3,5-7" or "all"), or empty to cancel: '
  read -r reply
  if [[ -z "$reply" ]]; then
    echo "No changes."
    exit 0
  fi
  while IFS= read -r idx; do TARGETS+=("$idx"); done < <(parse_indices "$reply")
fi

# Validate target indices.
for idx in "${TARGETS[@]}"; do
  if [[ "$idx" -lt 1 || "$idx" -gt "$TOTAL" ]]; then
    echo "ERROR: index $idx out of range (1..$TOTAL)" >&2
    exit 1
  fi
done

if [[ "${#TARGETS[@]}" -eq 0 ]]; then
  echo "No changes."
  exit 0
fi

# Group targets by path. macOS bash 3.2 has no associative arrays, so we use
# two parallel arrays: BUCKET_PATHS holds unique paths, BUCKET_BLOBS holds the
# matching newline-joined values at the same index.
BUCKET_PATHS=()
BUCKET_BLOBS=()
for idx in "${TARGETS[@]}"; do
  i=$((idx-1))
  path="${ENTRY_PATHS[i]}"
  val="${ENTRY_VALUES[i]}"
  found=-1
  for ((j=0; j<${#BUCKET_PATHS[@]}; j++)); do
    if [[ "${BUCKET_PATHS[j]}" == "$path" ]]; then found=$j; break; fi
  done
  if [[ "$found" -lt 0 ]]; then
    BUCKET_PATHS+=("$path")
    BUCKET_BLOBS+=("${val}"$'\n')
  else
    BUCKET_BLOBS[found]="${BUCKET_BLOBS[found]}${val}"$'\n'
  fi
done

echo "Plan:"
for ((k=0; k<${#BUCKET_PATHS[@]}; k++)); do
  echo "  ${BUCKET_PATHS[k]}:"
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    echo "    - $v"
  done <<< "${BUCKET_BLOBS[k]}"
done
echo ""

if [[ "$DRY_RUN" = true ]]; then
  echo "Dry run — no files modified."
  exit 0
fi

if [[ "$ASSUME_YES" != true ]]; then
  printf 'Apply? [y/N]: '
  read -r confirm
  case "$confirm" in
    y|Y|yes|YES) ;;
    *) echo "Cancelled."; exit 0 ;;
  esac
fi

# Apply per-file: jq filter that drops the specific values, then write
# atomically. Snapshot first so we can print a diff.
for ((k=0; k<${#BUCKET_PATHS[@]}; k++)); do
  path="${BUCKET_PATHS[k]}"
  # Build a JSON array of values to drop for this file.
  to_drop_json=$(printf '%s' "${BUCKET_BLOBS[k]}" \
    | jq -R . | jq -s 'map(select(. != ""))')

  sandshell_diff_snapshot "$path"
  updated=$(jq \
    --argjson drop "$to_drop_json" '
    .permissions.allow = ((.permissions.allow // []) | map(select(. as $v | $drop | index($v) | not))) |
    if (.permissions.allow // [] | length) == 0 then del(.permissions.allow) else . end |
    if (.permissions // {}) == {} then del(.permissions) else . end
  ' "$path")
  printf '%s\n' "$updated" | jq '.' > "$path"
  sandshell_diff_show "$path"
done

echo ""
echo "Pruned ${#TARGETS[@]} entr$([[ ${#TARGETS[@]} -eq 1 ]] && echo y || echo ies)."
