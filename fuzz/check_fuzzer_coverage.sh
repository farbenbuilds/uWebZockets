#!/usr/bin/env sh
# Verifies that each libFuzzer object carries Zig's inline-8bit-counter
# coverage. Trace-pc-guard callbacks are rejected by current libFuzzer
# runtimes, and a missing section means the target fuzzes blind.
set -eu

if [ "$#" -eq 0 ]; then
    printf '%s\n' "usage: check_fuzzer_coverage.sh OBJECT..." >&2
    exit 2
fi

if command -v readelf >/dev/null 2>&1; then
    reader="readelf"
    reader_flags="-S"
elif command -v llvm-readelf >/dev/null 2>&1; then
    reader="llvm-readelf"
    reader_flags="-S"
elif command -v objdump >/dev/null 2>&1; then
    reader="objdump"
    reader_flags="-h"
elif command -v llvm-objdump >/dev/null 2>&1; then
    reader="llvm-objdump"
    reader_flags="-h"
else
    printf '%s\n' "no ELF section reader (readelf/objdump) available" >&2
    exit 1
fi

for object in "$@"; do
    if [ ! -f "$object" ]; then
        printf 'missing fuzz object: %s\n' "$object" >&2
        exit 1
    fi
    if ! "$reader" "$reader_flags" "$object" | grep -q '__sancov_cntrs'; then
        printf 'missing __sancov_cntrs in %s; -ffuzz coverage was not emitted\n' "$object" >&2
        exit 1
    fi
done

printf 'fuzzer counter sections present in %d object(s)\n' "$#"
