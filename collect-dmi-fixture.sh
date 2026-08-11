#!/bin/bash
# Collect DMI/hardware samples from this host for model-detection fixtures.
#
# Run on each machine, then copy the output dir back to the fixtures tree:
#   ./collect-dmi-fixture.sh
#   scp -r dmi-fixture-<hostname>/ user@devbox:updamon-scripts/fixtures/
#
# Optional:
#   ./collect-dmi-fixture.sh [output-parent-dir]
#   FIXTURE_NAME=aspire-e1-571 ./collect-dmi-fixture.sh

set -euo pipefail

DMI_ID_DIR="/sys/devices/virtual/dmi/id"

# Fields used by post-computer-info.sh plus extras that help decide heuristics.
DMI_FIELDS=(
    sys_vendor
    product_name
    product_version
    product_family
    product_sku
    board_vendor
    board_name
    board_version
    chassis_vendor
    chassis_type
    chassis_version
    bios_vendor
    bios_version
    bios_date
)

die() {
    echo "Error: $*" >&2
    exit 1
}

hostname_safe="$(uname -n | tr -c 'A-Za-z0-9._-' '_')"
fixture_name="${FIXTURE_NAME:-$hostname_safe}"
output_parent="${1:-.}"
out_dir="${output_parent%/}/dmi-fixture-${fixture_name}"

mkdir -p "$out_dir"

if [[ ! -d "$DMI_ID_DIR" ]]; then
    die "DMI directory not found: $DMI_ID_DIR"
fi

for field in "${DMI_FIELDS[@]}"; do
    src="${DMI_ID_DIR}/${field}"
    dest="${out_dir}/${field}"
    if [[ -r "$src" ]]; then
        # Preserve exact contents (including trailing newline quirks).
        cp -a "$src" "$dest" 2>/dev/null || cat "$src" >"$dest"
    else
        # Empty file means "field missing/unreadable" on this host.
        : >"$dest"
    fi
done

printf '%s\n' "$(uname -n)" >"${out_dir}/hostname"
printf '%s\n' "$(uname -r)" >"${out_dir}/kernel"
printf '%s\n' "$(date -Is)" >"${out_dir}/collected_at"

if command -v hostnamectl >/dev/null 2>&1; then
    hostnamectl >"${out_dir}/hostnamectl.txt" 2>/dev/null || true
fi

# Fill this in after review; the test harness will compare against it.
if [[ ! -f "${out_dir}/expected_model" ]]; then
    cat >"${out_dir}/expected_model" <<'EOF'
# Replace this comment with the desired model string on one line, e.g.:
# Aspire E1-571 (V1.07)
EOF
fi

# Human-readable dump for quick eyeballing.
{
    echo "fixture: ${fixture_name}"
    echo "host: $(uname -n)"
    echo "collected_at: $(date -Is)"
    echo
    for field in "${DMI_FIELDS[@]}"; do
        value="$(tr -d '\n' <"${out_dir}/${field}" 2>/dev/null || true)"
        printf '%-16s %s\n' "${field}:" "${value:-<empty>}"
    done
} | tee "${out_dir}/summary.txt"

echo
echo "Wrote fixture to: ${out_dir}"
echo "Next: edit ${out_dir}/expected_model, then copy the directory to fixtures/."
