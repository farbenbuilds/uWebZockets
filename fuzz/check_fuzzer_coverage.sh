#!/usr/bin/env sh
# Verifies that each libFuzzer object carries non-empty Zig inline-8bit-counter
# coverage. Trace-pc-guard callbacks are rejected by current libFuzzer
# runtimes, and a missing or empty section means the target fuzzes blind.
set -eu

if [ "$#" -eq 0 ]; then
    printf '%s\n' "usage: check_fuzzer_coverage.sh OBJECT..." >&2
    exit 2
fi

if command -v objcopy >/dev/null 2>&1; then
    dumper="objcopy"
elif command -v llvm-objcopy >/dev/null 2>&1; then
    dumper="llvm-objcopy"
else
    dumper=""
fi

if [ -n "$dumper" ]; then
    section=$(mktemp "${TMPDIR:-/tmp}/uwebzockets-sancov.XXXXXX")
    trap 'rm -f "$section"' EXIT
else
    if command -v readelf >/dev/null 2>&1; then
        reader="readelf"
    elif command -v llvm-readelf >/dev/null 2>&1; then
        reader="llvm-readelf"
    elif command -v objdump >/dev/null 2>&1; then
        reader="objdump"
    elif command -v llvm-objdump >/dev/null 2>&1; then
        reader="llvm-objdump"
    else
        printf '%s\n' "no ELF section reader (objcopy/readelf/objdump) available" >&2
        exit 1
    fi
fi

for object in "$@"; do
    if [ ! -f "$object" ]; then
        printf 'missing fuzz object: %s\n' "$object" >&2
        exit 1
    fi
    if [ -n "$dumper" ]; then
        : >"$section"
        if ! "$dumper" --dump-section __sancov_cntrs="$section" "$object" 2>/dev/null; then
            printf 'missing __sancov_cntrs in %s; -ffuzz coverage was not emitted\n' "$object" >&2
            exit 1
        fi
        if [ ! -s "$section" ]; then
            printf 'empty __sancov_cntrs in %s; -ffuzz coverage was not emitted\n' "$object" >&2
            exit 1
        fi
    else
        if ! "$reader" -S "$object" | grep -q '__sancov_cntrs'; then
            printf 'missing __sancov_cntrs in %s; -ffuzz coverage was not emitted\n' "$object" >&2
            exit 1
        fi
    fi
done

printf 'non-empty fuzzer counter sections present in %d object(s)\n' "$#"
