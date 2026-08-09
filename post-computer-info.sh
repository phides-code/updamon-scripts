#!/bin/bash
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

# DMI fields are often left as OEM placeholders.
is_usable_dmi() {
    local v="${1:-}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    case "${v,,}" in
        "" | "none" | "default string" | "to be filled by o.e.m." | \
        "system product name" | "system version" | "not specified" | "not applicable")
            return 1
        ;;
    esac
    return 0
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

get_hostname() {
    uname -n
}

get_ip() {
    local ip
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')"
    require "$ip" "could not determine local IP"
    printf '%s\n' "$ip"
}

get_os() {
    local os
    [[ -r /etc/os-release ]] || die "/etc/os-release not found"
    # shellcheck source=/dev/null
    . /etc/os-release
    os="${PRETTY_NAME:-}"
    require "$os" "could not determine OS from /etc/os-release"
    printf '%s\n' "$os"
}

get_kernel() {
    uname -r
}

# Prefer product_version
# Fall back when version is an OEM placeholder (e.g. AZW/Beelink "Default string").
get_model() {
    local model="" dmi_field dmi_value
    for dmi_field in product_version product_name board_name; do
        dmi_value="$(cat "/sys/devices/virtual/dmi/id/${dmi_field}" 2>/dev/null || true)"
        if is_usable_dmi "$dmi_value"; then
            dmi_value="${dmi_value#"${dmi_value%%[![:space:]]*}"}"
            dmi_value="${dmi_value%"${dmi_value##*[![:space:]]}"}"
            model="$dmi_value"
            break
        fi
    done
    require "$model" "could not determine hardware model"
    printf '%s\n' "$model"
}

# Snap MemTotal up to the next power-of-2 marketing size (e.g. ~15.4 GiB -> 16 GB).
get_ram() {
    local ram
    ram="$(awk '/MemTotal:/ {
        mib = $2 / 1024
        p = 1
        while (p < mib) {
            p *= 2
        }
        if (p >= 1024) {
            printf "%d GB\n", p / 1024
        } else {
            printf "%d MB\n", p
        }
        exit
    }' /proc/meminfo)"
    require "$ram" "could not determine total RAM"
    printf '%s\n' "$ram"
}

get_cpu() {
    local cpu
    cpu="$(awk -F: '/^model name/ { gsub(/^ +/, "", $2); print $2; exit }' /proc/cpuinfo)"
    require "$cpu" "could not determine CPU"
    printf '%s\n' "$cpu"
}

get_root_disk() {
    local root_source root_disk
    root_source="$(findmnt -n -o SOURCE /)"
    root_disk="$(lsblk -no PKNAME "$root_source" 2>/dev/null | head -1)"
    if [[ -z "$root_disk" ]]; then
        # SOURCE may already be the whole disk
        root_disk="$(lsblk -no NAME,TYPE "$root_source" 2>/dev/null \
            | awk '$2 == "disk" { print $1; exit }')"
    fi
    require "$root_disk" "could not determine disk for /"
    printf '%s\n' "$root_disk"
}

# Map raw disk bytes to a common marketing size (128/256/512 GB, 1 TB, ...).
marketing_storage() {
    local bytes="$1"
    awk -v bytes="$bytes" 'BEGIN {
        n = split("8 16 32 64 120 128 240 250 256 480 500 512 1000 1024 2000 2048 4000 4096 8000 8192", sizes, " ")
        gb = bytes / 1000 / 1000 / 1000
        best = sizes[1] + 0
        best_d = 1e99
        for (i = 1; i <= n; i++) {
            s = sizes[i] + 0
            d = gb - s
            if (d < 0) {
                d = -d
            }
            if (d < best_d) {
                best_d = d
                best = s
            }
        }
        if (best >= 1000) {
            printf "%d TB\n", int(best / 1000 + 0.5)
        } else {
            printf "%d GB\n", best
        }
    }'
}

get_storage() {
    local root_disk bytes storage
    root_disk="$(get_root_disk)"
    bytes="$(lsblk -dn -bno SIZE "/dev/${root_disk}" | awk '{ print $1; exit }')"
    require "$bytes" "could not determine storage size for /dev/${root_disk}"
    storage="$(marketing_storage "$bytes")"
    require "$storage" "could not determine storage size for /dev/${root_disk}"
    printf '%s\n' "$storage"
}

collect_host_info() {
    hostname="$(get_hostname)"
    ip="$(get_ip)"
    os="$(get_os)"
    kernel="$(get_kernel)"
    model="$(get_model)"
    ram="$(get_ram)"
    cpu="$(get_cpu)"
    storage="$(get_storage)"
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

show_http_error() {
    local http_code="$1"
    echo "Error: request failed with HTTP ${http_code}" >&2
    cat "$response_file" >&2 || true
    echo >&2
    exit 1
}

post_payload() {
    local http_code
    response_file=$(mktemp)
    trap 'rm -f "$response_file"' EXIT

    http_code=$(curl -sS -o "$response_file" -w "%{http_code}" "${curl_args[@]}") \
        || die "curl request failed"

    if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
        show_http_error "$http_code"
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
