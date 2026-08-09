#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_FILE="${SECRETS_FILE:-$SCRIPT_DIR/secrets.env}"

die() {
  echo "Error: $*" >&2
  exit 1
}

require() {
  local value="$1"
  local message="$2"
  [[ -n "$value" ]] || die "$message"
}

usage() {
  echo "Usage: $0 [-test]" >&2
  exit 1
}

load_secrets() {
  [[ -r "$SECRETS_FILE" ]] || die "secrets file not readable: $SECRETS_FILE"
  # shellcheck source=/dev/null
  set -a
  source "$SECRETS_FILE"
  set +a

  require "${URL:-}" "URL must be set in $SECRETS_FILE"
  require "${X_ADMIN_KEY:-}" "X_ADMIN_KEY must be set in $SECRETS_FILE"
}

collect_host_info() {
  hostname="$(uname -n)"

  ip="$(ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')"
  require "$ip" "could not determine local IP"

  [[ -r /etc/os-release ]] || die "/etc/os-release not found"
  # shellcheck source=/dev/null
  . /etc/os-release
  os="${PRETTY_NAME:-}"
  require "$os" "could not determine OS from /etc/os-release"

  kernel="$(uname -r)"

  model="$(cat /sys/devices/virtual/dmi/id/product_version 2>/dev/null || true)"
  if [[ -z "$model" || "$model" == "None" ]]; then
    model="$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || true)"
  fi
  require "$model" "could not determine hardware model"

  # MemTotal is a bit under installed RAM (firmware/hardware reserved); round up to whole GiB.
  ram="$(awk '/MemTotal:/ { printf "%d GB\n", int($2 / 1024 / 1024 + 0.999); exit }' /proc/meminfo)"
  require "$ram" "could not determine total RAM"

  cpu="$(awk -F: '/^model name/ { gsub(/^ +/, "", $2); print $2; exit }' /proc/cpuinfo)"
  require "$cpu" "could not determine CPU"

  local root_source root_disk
  root_source="$(findmnt -n -o SOURCE /)"
  root_disk="$(lsblk -no PKNAME "$root_source" 2>/dev/null | head -1)"
  if [[ -z "$root_disk" ]]; then
    # SOURCE may already be the whole disk
    root_disk="$(lsblk -no NAME,TYPE "$root_source" 2>/dev/null \
      | awk '$2 == "disk" { print $1; exit }')"
  fi
  require "$root_disk" "could not determine disk for /"

  storage="$(lsblk -dn -o SIZE "/dev/${root_disk}" \
    | awk '{ gsub(/^ +| +$/, "", $0); sub(/G$/, " GB"); print; exit }')"
  require "$storage" "could not determine storage size for /dev/${root_disk}"
}

build_payload() {
  payload=$(jq -nc \
    --arg hostname "$hostname" \
    --arg ip "$ip" \
    --arg os "$os" \
    --arg kernel "$kernel" \
    --arg model "$model" \
    --arg ram "$ram" \
    --arg cpu "$cpu" \
    --arg storage "$storage" \
    '{
      hostname: $hostname,
      ip: $ip,
      os: $os,
      kernel: $kernel,
      model: $model,
      ram: $ram,
      cpu: $cpu,
      storage: $storage
    }')
}

build_curl_args() {
  curl_args=(
    -X POST
    -H "Content-Type: application/json"
    -H "x-admin-key: ${X_ADMIN_KEY}"
    -d "$payload"
    "$URL"
  )
}

preview_request() {
  echo "JSON:"
  jq . <<<"$payload"
  echo
  cat <<EOF
curl \\
  -X POST \\
  -H $(printf '%q' "Content-Type: application/json") \\
  -H $(printf '%q' "x-admin-key: ${X_ADMIN_KEY}") \\
  -d $(printf '%q' "$payload") \\
  $(printf '%q' "$URL")
EOF
}

show_success() {
  echo "success"
  if [[ -s "$response_file" ]]; then
    jq . "$response_file" 2>/dev/null || cat "$response_file"
    echo
  fi
}

post_payload() {
  local http_code
  response_file=$(mktemp)
  trap 'rm -f "$response_file"' EXIT

  http_code=$(curl -sS -o "$response_file" -w "%{http_code}" "${curl_args[@]}") \
    || die "curl request failed"

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "Error: request failed with HTTP ${http_code}" >&2
    cat "$response_file" >&2 || true
    echo >&2
    exit 1
  fi

  show_success
}

main() {
  local test_mode=0
  if [[ "${1:-}" == "-test" ]]; then
    test_mode=1
  elif [[ $# -gt 0 ]]; then
    usage
  fi

  load_secrets
  collect_host_info
  build_payload
  build_curl_args

  if [[ "$test_mode" -eq 1 ]]; then
    preview_request
  else
    post_payload
  fi
}

main "$@"
