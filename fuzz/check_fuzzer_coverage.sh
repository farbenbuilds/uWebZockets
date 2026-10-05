#!/usr/bin/env sh
# Fails when an OSS-Fuzz object lacks the trace-pc-guard callbacks libFuzzer
# consumes for coverage feedback.
set -eu

if command -v nm >/dev/null 2>&1; then
    symbol_tool=nm
elif command -v llvm-nm >/dev/null 2>&1; then
    symbol_tool=llvm-nm
else
    printf '%s\n' "nm or llvm-nm is required to verify fuzzer coverage" >&2
    exit 1
fi

if [ "$#" -eq 0 ]; then
    printf '%s\n' "usage: check_fuzzer_coverage.sh OBJECT..." >&2
    exit 2
fi

failed=0
for object in "$@"; do
    if [ ! -f "$object" ]; then
        printf 'object does not exist: %s\n' "$object" >&2
        failed=1
        continue
    fi

    symbols=$("$symbol_tool" "$object" 2>/dev/null || true)
    for symbol in __sanitizer_cov_trace_pc_guard __sanitizer_cov_trace_pc_guard_init; do
        if printf '%s\n' "$symbols" | grep -Fq "$symbol"; then
            continue
        fi
        printf 'missing %s in %s\n' "$symbol" "$object" >&2
        failed=1
    done
done

if [ "$failed" -ne 0 ]; then
    printf '%s\n' "fuzz objects must be built with sanitize_coverage_trace_pc_guard" >&2
    exit 1
fi

printf 'fuzzer coverage symbols present in %s object(s)\n' "$#"
