#!/bin/bash
# Compare get_model against expected_model in each dmi-fixture-* directory.
#
# Usage:
#   ./test-get-model.sh
#   ./test-get-model.sh dmi-fixture-acer-debian_

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=post-computer-info.sh
source "${SCRIPT_DIR}/post-computer-info.sh"

read_expected_model() {
    local file="$1"
    # First non-empty, non-comment line.
    awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        { sub(/\r$/, ""); print; exit }
    ' "$file"
}

test_fixture() {
    local fixture_dir="$1"
    local expected actual name

    name="$(basename "$fixture_dir")"
    [[ -f "${fixture_dir}/expected_model" ]] || die "${name}: missing expected_model"

    expected="$(read_expected_model "${fixture_dir}/expected_model")"
    require "$expected" "${name}: expected_model is empty (add the desired model string)"

    DMI_ID_DIR="$fixture_dir"
    actual="$(get_model)"

    if [[ "$actual" == "$expected" ]]; then
        printf 'PASS  %s\n' "$name"
        printf '      got: %s\n' "$actual"
        return 0
    fi

    printf 'FAIL  %s\n' "$name" >&2
    printf '      expected: %s\n' "$expected" >&2
    printf '      got:      %s\n' "$actual" >&2
    return 1
}

main() {
    local fixtures=()
    local fixture fails=0

    if [[ $# -gt 0 ]]; then
        fixtures=("$@")
    else
        shopt -s nullglob
        fixtures=("${SCRIPT_DIR}"/dmi-fixture-*/)
        shopt -u nullglob
    fi

    (( ${#fixtures[@]} > 0 )) || die "no dmi-fixture-* directories found"

    for fixture in "${fixtures[@]}"; do
        fixture="${fixture%/}"
        [[ -d "$fixture" ]] || die "not a directory: $fixture"
        if ! test_fixture "$fixture"; then
            fails=$((fails + 1))
        fi
    done

    echo
    if (( fails > 0 )); then
        echo "${fails} fixture(s) failed" >&2
        exit 1
    fi
    echo "all ${#fixtures[@]} fixture(s) passed"
}

main "$@"
