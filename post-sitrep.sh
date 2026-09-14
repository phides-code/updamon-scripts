#!/bin/bash
# Gather a host sitrep and POST it as JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_FILE="${SECRETS_FILE:-$SCRIPT_DIR/secrets.env}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"

HEADER_CONTENT_TYPE="Content-Type: application/json"
HEADER_ADMIN_KEY_NAME="x-admin-key"
API_PATH="/sitreps"

AUTO_UPDATE_DIR="${AUTO_UPDATE_DIR:-$HOME/auto-update}"
LAST_LOGIN_LINES=30

# API sentinel values (keep spelling stable for consumers).
NA="N/A"
STATE_ON="on"
STATE_OFF="off"
STATE_NA="n/a"
TAILSCALE_OFF="off"

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------

die() {
    echo "Error: $*" >&2
    exit 1
}

require() {
    local value="$1"
    local message="$2"
    [[ -n "$value" ]] || die "$message"
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

usage() {
    echo "Usage: $0 [-test]" >&2
    exit 1
}

load_secrets() {
    [[ -r "$SECRETS_FILE" ]] || die "secrets file not readable: $SECRETS_FILE"
    set -a
    # shellcheck source=/dev/null
    source "$SECRETS_FILE"
    set +a

    require "${URL:-}" "URL must be set in $SECRETS_FILE"
    require "${X_ADMIN_KEY:-}" "X_ADMIN_KEY must be set in $SECRETS_FILE"
    # Base URL from secrets may include a trailing slash; API_PATH is absolute.
    ENDPOINT="${URL%/}${API_PATH}"
}

# ---------------------------------------------------------------------------
# Collectors — each returns one sitrep field on stdout
# ---------------------------------------------------------------------------

get_hostname() {
    uname -n
}

get_apt_log() {
    local path

    [[ -d "$AUTO_UPDATE_DIR" ]] || { printf '%s\n' "$NA"; return 0; }

    # Newest regular file by mtime (avoid ls for non-alphanumeric names).
    path="$(find "$AUTO_UPDATE_DIR" -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr \
        | head -n 1 \
        | cut -d' ' -f2-)"
    if [[ -z "$path" || ! -r "$path" ]]; then
        printf '%s\n' "$NA"
        return 0
    fi

    cat "$path"
}

get_last() {
    last | head -n "$LAST_LOGIN_LINES" || true
}

get_free() {
    free -h
}

get_df() {
    df -h
}

get_who() {
    w
}

# --- WAP (connected AP MAC, or N/A) ----------------------------------------

wap_from_nmcli() {
    have_cmd nmcli || return 1

    nmcli -t -f ACTIVE,BSSID dev wifi 2>/dev/null \
        | awk -F: '$1 == "yes" {
            line = $0
            sub(/^yes:/, "", line)
            gsub(/\\:/, ":", line)
            print line
            exit
        }'
}

wap_from_iw() {
    local iface_path iface bssid

    have_cmd iw || return 1

    for iface_path in /sys/class/net/*/wireless; do
        [[ -e "$iface_path" ]] || continue
        iface="$(basename "$(dirname "$iface_path")")"
        bssid="$(iw dev "$iface" link 2>/dev/null \
            | awk '/Connected to/ { print toupper($3); exit }')"
        if [[ -n "$bssid" ]]; then
            printf '%s\n' "$bssid"
            return 0
        fi
    done

    return 1
}

get_wap() {
    local bssid

    bssid="$(wap_from_nmcli || true)"
    if [[ -n "$bssid" ]]; then
        printf '%s\n' "$bssid"
        return 0
    fi

    bssid="$(wap_from_iw || true)"
    if [[ -n "$bssid" ]]; then
        printf '%s\n' "$bssid"
        return 0
    fi

    printf '%s\n' "$NA"
}

# --- Tailscale (IPv4 address, or "off") ------------------------------------

get_tailscale() {
    local ip state

    have_cmd tailscale || { printf '%s\n' "$TAILSCALE_OFF"; return 0; }

    state="$(tailscale status --json 2>/dev/null \
        | jq -r '.BackendState // empty' 2>/dev/null || true)"
    if [[ "$state" != "Running" ]]; then
        printf '%s\n' "$TAILSCALE_OFF"
        return 0
    fi

    ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
    if [[ -n "$ip" ]]; then
        printf '%s\n' "$ip"
        return 0
    fi

    printf '%s\n' "$TAILSCALE_OFF"
}

# --- Bluetooth ("on" | "off" | "n/a") --------------------------------------

# rfkill sysfs state: 0 soft-blocked, 1 unblocked, 2 hard-blocked.
RFKILL_SOFT_BLOCKED=0
RFKILL_HARD_BLOCKED=2

bluetooth_hci_present() {
    compgen -G '/sys/class/bluetooth/hci*' >/dev/null
}

# Prints type/state lines for each bluetooth rfkill device: "<type> <state>"
iter_bluetooth_rfkill() {
    local rf type state

    for rf in /sys/class/rfkill/rfkill*; do
        [[ -e "$rf/type" ]] || continue
        type="$(cat "$rf/type" 2>/dev/null || true)"
        [[ "$type" == "bluetooth" ]] || continue
        state="$(cat "$rf/state" 2>/dev/null || true)"
        printf '%s %s\n' "$type" "$state"
    done
}

has_bluetooth_rfkill() {
    [[ -n "$(iter_bluetooth_rfkill)" ]]
}

hardware_lists_bluetooth() {
    have_cmd lspci && lspci 2>/dev/null | grep -qi bluetooth && return 0
    have_cmd lsusb && lsusb 2>/dev/null | grep -qi bluetooth && return 0
    return 1
}

has_bluetooth_device() {
    bluetooth_hci_present && return 0
    has_bluetooth_rfkill && return 0
    hardware_lists_bluetooth && return 0
    return 1
}

bluetooth_rfkill_blocked() {
    local _type state

    while read -r _type state; do
        if [[ "$state" == "$RFKILL_SOFT_BLOCKED" \
            || "$state" == "$RFKILL_HARD_BLOCKED" ]]; then
            return 0
        fi
    done < <(iter_bluetooth_rfkill)

    return 1
}

bluetoothctl_powered() {
    have_cmd bluetoothctl || return 1
    bluetoothctl show 2>/dev/null \
        | awk -F': ' '/Powered:/ { print tolower($2); exit }'
}

get_bluetooth() {
    local powered

    if ! has_bluetooth_device; then
        printf '%s\n' "$STATE_NA"
        return 0
    fi

    if bluetooth_rfkill_blocked; then
        printf '%s\n' "$STATE_OFF"
        return 0
    fi

    powered="$(bluetoothctl_powered || true)"
    case "$powered" in
        yes)
            printf '%s\n' "$STATE_ON"
            return 0
            ;;
        no)
            printf '%s\n' "$STATE_OFF"
            return 0
            ;;
    esac

    if bluetooth_hci_present; then
        printf '%s\n' "$STATE_ON"
        return 0
    fi

    printf '%s\n' "$STATE_OFF"
}

# ---------------------------------------------------------------------------
# Assemble + transport
# ---------------------------------------------------------------------------

collect_status_info() {
    hostname="$(get_hostname)"
    apt_log="$(get_apt_log)"
    last_logins="$(get_last)"
    wap="$(get_wap)"
    free_out="$(get_free)"
    df_out="$(get_df)"
    who_out="$(get_who)"
    tailscale="$(get_tailscale)"
    bluetooth="$(get_bluetooth)"
}

build_payload() {
    payload=$(jq -nc \
        --arg Hostname "$hostname" \
        --arg AptLog "$apt_log" \
        --arg Last "$last_logins" \
        --arg WAP "$wap" \
        --arg Free "$free_out" \
        --arg DF "$df_out" \
        --arg Who "$who_out" \
        --arg Tailscale "$tailscale" \
        --arg Bluetooth "$bluetooth" \
        '{
            Hostname: $Hostname,
            AptLog: $AptLog,
            Last: $Last,
            WAP: $WAP,
            Free: $Free,
            DF: $DF,
            Who: $Who,
            Tailscale: $Tailscale,
            Bluetooth: $Bluetooth
        }')
}

admin_key_header() {
    printf '%s: %s' "$HEADER_ADMIN_KEY_NAME" "$X_ADMIN_KEY"
}

build_curl_args() {
    curl_args=(
        -X POST
        -H "$HEADER_CONTENT_TYPE"
        -H "$(admin_key_header)"
        -d "$payload"
        "$ENDPOINT"
    )
}

is_http_success() {
    local http_code="$1"
    [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]
}

preview_request() {
    echo "JSON:"
    jq . <<<"$payload"
    echo
    cat <<EOF
curl \\
  -X POST \\
  -H $(printf '%q' "$HEADER_CONTENT_TYPE") \\
  -H $(printf '%q' "$(admin_key_header)") \\
  -d $(printf '%q' "$payload") \\
  $(printf '%q' "$ENDPOINT")
EOF
}

show_success() {
    echo "success"
    if [[ -s "$response_file" ]]; then
        jq . "$response_file" 2>/dev/null || cat "$response_file"
        echo
    fi
}

ensure_log_dir() {
    mkdir -p "$LOG_DIR"
}

# One file per run, under logs/ (gitignored).
new_post_log_path() {
    printf '%s/sitrep-%s.log\n' "$LOG_DIR" "$(date +%Y-%m-%d_%H%M%S)"
}

write_post_log() {
    local http_code="$1"
    local status="$2"
    local log_path="$3"

    {
        echo "time: $(date -Is)"
        echo "endpoint: ${ENDPOINT}"
        echo "http_code: ${http_code}"
        echo "status: ${status}"
        echo "response:"
        if [[ -s "$response_file" ]]; then
            jq . "$response_file" 2>/dev/null || cat "$response_file"
        else
            echo "(empty)"
        fi
    } >"$log_path"
}

post_payload() {
    local http_code log_path
    response_file=$(mktemp)
    trap 'rm -f "$response_file"' EXIT

    ensure_log_dir
    log_path="$(new_post_log_path)"

    http_code=$(curl -sS -o "$response_file" -w "%{http_code}" "${curl_args[@]}") \
        || {
            write_post_log "000" "curl_failed" "$log_path"
            die "curl request failed (logged to ${log_path})"
        }

    if ! is_http_success "$http_code"; then
        write_post_log "$http_code" "error" "$log_path"
        echo "Error: request failed with HTTP ${http_code} (logged to ${log_path})" >&2
        cat "$response_file" >&2 || true
        echo >&2
        exit 1
    fi

    write_post_log "$http_code" "success" "$log_path"
    show_success
    echo "logged to ${log_path}"
}

parse_args() {
    test_mode=0
    if [[ "${1:-}" == "-test" ]]; then
        test_mode=1
    elif [[ $# -gt 0 ]]; then
        usage
    fi
}

main() {
    parse_args "$@"

    load_secrets
    collect_status_info
    build_payload
    build_curl_args

    if [[ "$test_mode" -eq 1 ]]; then
        preview_request
    else
        post_payload
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
