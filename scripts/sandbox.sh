#!/usr/bin/env bash
# sandshell: container lifecycle management
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SANDSHELL_IMAGE="${SANDSHELL_IMAGE:-ubuntu:24.04}"

# Source audit helper
audit_log() {
  local session_id="$1" op="$2" cmd="$3"
  shift 3
  local extra="${*:-}"
  "$SCRIPT_DIR/audit.sh" log "$session_id" \
    "{\"op\":\"${op}\",\"cmd\":$(printf '%s' "$cmd" | head -c 500 | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo "\"${cmd:0:200}\"")${extra:+,$extra}}"
}

# Extract session ID from container name (sandshell-XXXXX → XXXXX)
session_from_name() {
  echo "${1#sandshell-}"
}

# Detect runtime
detect_runtime() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo "docker"
  elif command -v podman >/dev/null 2>&1; then
    echo "podman"
  elif command -v limactl >/dev/null 2>&1; then
    echo "lima"
  else
    echo "none"
  fi
}

# ─── Commands ────────────────────────────────────────────────────────

cmd_create() {
  local name="" runtime="" mount_mode="ro"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --runtime=*) runtime="${1#*=}"; shift ;;
      --mount=*)   mount_mode="${1#*=}"; shift ;;
      -*)          echo "Unknown flag: $1" >&2; exit 1 ;;
      *)           name="$1"; shift ;;
    esac
  done

  if [[ -z "$name" ]]; then
    echo "Usage: sandbox.sh create <name> [--runtime=docker|lima] [--mount=ro|rw]" >&2
    exit 1
  fi

  [[ -z "$runtime" ]] && runtime=$(detect_runtime)
  local session_id
  session_id=$(session_from_name "$name")
  "$SCRIPT_DIR/audit.sh" init "$session_id"

  case "$runtime" in
    docker|podman)
      _create_container "$runtime" "$name" "$mount_mode"
      ;;
    lima)
      _create_lima "$name" "$mount_mode"
      ;;
    none)
      echo "ERROR: No container runtime available." >&2
      echo "Install Docker: https://docs.docker.com/get-docker/" >&2
      echo "Or Lima: https://lima-vm.io" >&2
      exit 1
      ;;
  esac

  audit_log "$session_id" "create" "sandbox.sh create $name" \
    "\"runtime\":\"$runtime\",\"mount\":\"$mount_mode\""
  echo "Sandbox '$name' created (runtime=$runtime, mount=$mount_mode)"
}

_create_container() {
  local runtime="$1" name="$2" mount_mode="$3"
  local mount_flag="ro"
  [[ "$mount_mode" = "rw" ]] && mount_flag="rw"

  # Check if already exists
  if "$runtime" ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
    if "$runtime" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
      echo "Sandbox '$name' already running." >&2
      return 0
    fi
    "$runtime" start "$name" >/dev/null
    return 0
  fi

  "$runtime" run -d \
    --name "$name" \
    --label "sandshell.managed=true" \
    --entrypoint sleep \
    -v "$(pwd):/workspace:${mount_flag}" \
    -w /workspace \
    "$SANDSHELL_IMAGE" \
    infinity >/dev/null

  # Create non-root user inside container
  "$runtime" exec "$name" bash -c '
    if ! id sandshell >/dev/null 2>&1; then
      useradd -m -s /bin/bash sandshell 2>/dev/null || true
    fi
  '
}

_create_lima() {
  local name="$1" mount_mode="$2"
  local writable="false"
  [[ "$mount_mode" = "rw" ]] && writable="true"

  if limactl list -q 2>/dev/null | grep -qx "$name"; then
    if limactl list --json 2>/dev/null | python3 -c "
import sys, json
for vm in json.loads(sys.stdin.read()):
  if vm.get('name') == '$name' and vm.get('status') == 'Running':
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
      echo "Sandbox '$name' already running." >&2
      return 0
    fi
    limactl start "$name" >/dev/null
    return 0
  fi

  # Create minimal Lima YAML
  local config
  config=$(mktemp)
  cat > "$config" <<YAML
images:
  - location: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
    arch: "x86_64"
  - location: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64.img"
    arch: "aarch64"
mounts:
  - location: "$(pwd)"
    mountPoint: "/workspace"
    writable: ${writable}
cpus: 2
memory: "2GiB"
disk: "10GiB"
YAML

  limactl create --name="$name" "$config" >/dev/null
  limactl start "$name" >/dev/null
  rm -f "$config"
}

cmd_exec() {
  local name="$1"; shift
  if [[ -z "$name" || $# -eq 0 ]]; then
    echo "Usage: sandbox.sh exec <name> <command...>" >&2
    exit 1
  fi

  local session_id
  session_id=$(session_from_name "$name")
  local cmd="$*"
  local start_ts exit_code
  start_ts=$(date +%s%3N 2>/dev/null || date +%s)

  local runtime
  runtime=$(detect_runtime)

  local output
  case "$runtime" in
    docker|podman)
      output=$("$runtime" exec -w /workspace "$name" bash -c "$cmd" 2>&1) && exit_code=0 || exit_code=$?
      ;;
    lima)
      output=$(limactl shell "$name" bash -c "cd /workspace && $cmd" 2>&1) && exit_code=0 || exit_code=$?
      ;;
    *)
      echo "ERROR: No runtime available" >&2
      exit 1
      ;;
  esac

  local end_ts
  end_ts=$(date +%s%3N 2>/dev/null || date +%s)
  local duration=$(( end_ts - start_ts ))

  local stdout_lines
  stdout_lines=$(echo "$output" | wc -l | tr -d ' ')

  audit_log "$session_id" "exec" "$cmd" \
    "\"exit_code\":$exit_code,\"duration_ms\":$duration,\"stdout_lines\":$stdout_lines"

  echo "$output"
  return "$exit_code"
}

cmd_copy_in() {
  local name="$1" src="$2" dest="$3"
  local runtime
  runtime=$(detect_runtime)
  local session_id
  session_id=$(session_from_name "$name")

  case "$runtime" in
    docker|podman) "$runtime" cp "$src" "$name:$dest" ;;
    lima)          limactl copy "$src" "$name:$dest" ;;
  esac

  audit_log "$session_id" "copy_in" "copy-in $src → $dest"
}

cmd_copy_out() {
  local name="$1" src="$2" dest="$3"
  local runtime
  runtime=$(detect_runtime)
  local session_id
  session_id=$(session_from_name "$name")

  case "$runtime" in
    docker|podman) "$runtime" cp "$name:$src" "$dest" ;;
    lima)          limactl copy "$name:$src" "$dest" ;;
  esac

  audit_log "$session_id" "copy_out" "copy-out $src → $dest"
}

cmd_status() {
  local name="$1"
  local runtime
  runtime=$(detect_runtime)

  case "$runtime" in
    docker|podman)
      if "$runtime" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
        echo "running"
      elif "$runtime" ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
        echo "stopped"
      else
        echo "not_found"
      fi
      ;;
    lima)
      if limactl list -q 2>/dev/null | grep -qx "$name"; then
        echo "running"
      else
        echo "not_found"
      fi
      ;;
  esac
}

cmd_destroy() {
  local name="$1"
  local runtime
  runtime=$(detect_runtime)
  local session_id
  session_id=$(session_from_name "$name")

  case "$runtime" in
    docker|podman) "$runtime" rm -f "$name" >/dev/null 2>&1 || true ;;
    lima)          limactl delete --force "$name" >/dev/null 2>&1 || true ;;
  esac

  audit_log "$session_id" "destroy" "sandbox.sh destroy $name"
  echo "Sandbox '$name' destroyed. Audit log: ~/.sandshell/audit/${session_id}.jsonl"
}

cmd_list() {
  local runtime
  runtime=$(detect_runtime)

  case "$runtime" in
    docker|podman)
      "$runtime" ps -a --filter "label=sandshell.managed=true" \
        --format 'table {{.Names}}\t{{.Status}}\t{{.CreatedAt}}' 2>/dev/null
      ;;
    lima)
      limactl list 2>/dev/null | grep "sandshell-" || echo "No sandshell VMs found."
      ;;
  esac
}

# ─── Dispatch ────────────────────────────────────────────────────────

case "${1:-help}" in
  create)   shift; cmd_create "$@" ;;
  exec)     shift; cmd_exec "$@" ;;
  copy-in)  shift; cmd_copy_in "$@" ;;
  copy-out) shift; cmd_copy_out "$@" ;;
  status)   shift; cmd_status "$@" ;;
  destroy)  shift; cmd_destroy "$@" ;;
  list)     cmd_list ;;
  *)
    echo "Usage: sandbox.sh <create|exec|copy-in|copy-out|status|destroy|list>"
    echo ""
    echo "Commands:"
    echo "  create  <name> [--runtime=docker|lima] [--mount=ro|rw]"
    echo "  exec    <name> <command...>"
    echo "  copy-in <name> <src> <dest>"
    echo "  copy-out <name> <src> <dest>"
    echo "  status  <name>"
    echo "  destroy <name>"
    echo "  list"
    exit 1
    ;;
esac
