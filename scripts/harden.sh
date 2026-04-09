#!/usr/bin/env bash
# sandshell: network hardening via iptables inside container
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILES_DIR="$(cd "$SCRIPT_DIR/../profiles" && pwd)"

usage() {
  echo "Usage: harden.sh <container> --profile=<name>"
  echo "       harden.sh <container> --allow=domain1,domain2 [--ports=443,22]"
  echo ""
  echo "Profiles: default, node, python, minimal"
  exit 1
}

# Parse arguments
CONTAINER=""
PROFILE=""
ALLOW_DOMAINS=""
PORTS="443,22"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile=*) PROFILE="${1#*=}"; shift ;;
    --allow=*)   ALLOW_DOMAINS="${1#*=}"; shift ;;
    --ports=*)   PORTS="${1#*=}"; shift ;;
    -*)          usage ;;
    *)           CONTAINER="$1"; shift ;;
  esac
done

[[ -z "$CONTAINER" ]] && usage

# Load domains from profile or --allow flag
domains=()
if [[ -n "$PROFILE" ]]; then
  profile_file="$PROFILES_DIR/${PROFILE}.conf"
  if [[ ! -f "$profile_file" ]]; then
    echo "ERROR: Unknown profile '$PROFILE'. Available:" >&2
    ls "$PROFILES_DIR"/*.conf 2>/dev/null | xargs -I{} basename {} .conf >&2
    exit 1
  fi
  while IFS= read -r line; do
    line="${line%%#*}"        # strip comments
    line="${line// /}"        # strip whitespace
    [[ -n "$line" ]] && domains+=("$line")
  done < "$profile_file"
fi

if [[ -n "$ALLOW_DOMAINS" ]]; then
  IFS=',' read -ra extra <<< "$ALLOW_DOMAINS"
  domains+=("${extra[@]}")
fi

# Parse ports
IFS=',' read -ra port_list <<< "$PORTS"

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

runtime=$(detect_runtime)

# Build the iptables script to run inside the container
build_harden_script() {
  cat <<'HEADER'
#!/bin/bash
set -e

# Install iptables if needed
if ! command -v iptables >/dev/null 2>&1; then
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables dnsutils >/dev/null 2>&1
fi

# Flush existing OUTPUT rules
iptables -F OUTPUT 2>/dev/null || true

# Allow loopback
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established connections
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow DNS (required for domain resolution)
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

HEADER

  # Add rules for each domain
  for domain in "${domains[@]}"; do
    cat <<DOMAIN_RULE
# Allow ${domain}
RESOLVED_IPS=\$(dig +short ${domain} 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
for IP in \$RESOLVED_IPS; do
DOMAIN_RULE
    for port in "${port_list[@]}"; do
      echo "  iptables -A OUTPUT -p tcp -d \"\$IP\" --dport ${port} -j ACCEPT"
    done
    echo "done"
    echo ""
  done

  cat <<'FOOTER'
# Drop everything else
iptables -A OUTPUT -j DROP

echo "sandshell: network hardening applied"
echo "sandshell: allowed domains: $ALLOWED_DOMAINS_LIST"
iptables -L OUTPUT -n --line-numbers 2>/dev/null || true
FOOTER
}

# Build and inject the script
harden_script=$(build_harden_script)
# Add the domain list for logging
allowed_list=$(IFS=','; echo "${domains[*]}")
harden_script="${harden_script//\$ALLOWED_DOMAINS_LIST/$allowed_list}"

# Execute inside the container
case "$runtime" in
  docker|podman)
    echo "$harden_script" | "$runtime" exec -i --privileged "$CONTAINER" bash
    ;;
  lima)
    echo "$harden_script" | limactl shell "$CONTAINER" sudo bash
    ;;
  *)
    echo "ERROR: No runtime available" >&2
    exit 1
    ;;
esac

# Log to audit trail
session_id="${CONTAINER#sandshell-}"
"$SCRIPT_DIR/audit.sh" log "$session_id" \
  "{\"op\":\"harden\",\"domains\":\"${allowed_list}\",\"ports\":\"${PORTS}\"}"

echo "Network hardened: ${#domains[@]} domains allowed on ports ${PORTS}"
