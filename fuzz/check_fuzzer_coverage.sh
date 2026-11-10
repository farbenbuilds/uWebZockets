#!/usr/bin/env sh
# Verifies that each libFuzzer object carries non-empty Zig inline-8bit-counter
# coverage. Trace-pc-guard callbacks are rejected by current libFuzzer
# runtimes, and a missing or empty section means the target fuzzes blind.
set -eu

if [ "$#" -eq 0 ]; then
    printf '%s\n' "usage: check_fuzzer_coverage.sh OBJECT..." >&2
    exit 2
fi

if command -v readelf >/dev/null 2>&1; then
    reader="readelf"
    reader_flags="-SW"
    size_field=7
elif command -v llvm-readelf >/dev/null 2>&1; then
    reader="llvm-readelf"
    reader_flags="-SW"
    size_field=7
elif command -v objdump >/dev/null 2>&1; then
    reader="objdump"
    reader_flags="-h"
    size_field=3
elif command -v llvm-objdump >/dev/null 2>&1; then
    reader="llvm-objdump"
    reader_flags="-h"
    size_field=3
else
    printf '%s\n' "no ELF section reader (readelf/objdump) available" >&2
    exit 1
fi

sections=$(mktemp "${TMPDIR:-/tmp}/uwebzockets-sancov.XXXXXX")
trap 'rm -f "$sections"' EXIT

for object in "$@"; do
    if [ ! -f "$object" ]; then
        printf 'missing fuzz object: %s\n' "$object" >&2
        exit 1
    fi
    if ! "$reader" "$reader_flags" "$object" >"$sections"; then
        printf 'failed to read ELF sections: %s\n' "$object" >&2
        exit 1
    fi
    if ! awk -v field="$size_field" '
        /__sancov_cntrs/ {
            if ($field ~ /^[0-9a-fA-F]+$/ && $field !~ /^0+$/) found = 1
        }
        END { exit found ? 0 : 1 }
    ' "$sections"; then
        printf 'missing or empty __sancov_cntrs in %s; -ffuzz coverage was not emitted\n' "$object" >&2
        exit 1
    fi
done

printf 'non-empty fuzzer counter sections present in %d object(s)\n' "$#"
