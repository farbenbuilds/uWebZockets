#!/bin/bash
set -euo pipefail

project_dir="$SRC/uWebZockets"
install_dir="$WORK/uwebzockets-fuzz"

case "${SANITIZER:-address}" in
    address | coverage)
        ;;
    *)
        printf '%s\n' \
            "uWebZockets OSS-Fuzz targets support address and coverage builds" >&2
        exit 1
        ;;
esac

cd "$project_dir"
zig build oss-fuzz-objects \
    -Doptimize=ReleaseSafe \
    --prefix "$install_dir"

# Zig's -ffuzz counters need a registration hook for the external libFuzzer
# runtime; keep the shim free of sanitizer flags so it cannot drag in a
# rejected coverage flavor of its own.
"$CC" -O2 -c "$project_dir/oss-fuzz/zig_sancov_shim.c" \
    -o "$install_dir/zig_sancov_shim.o"

# Derive the target list from the objects the build installed. This keeps the
# OSS-Fuzz link step in sync with builds/fuzzing.zig without a second manifest.
objects=("$install_dir"/oss-fuzz/*.o)
test "${#objects[@]}" -eq 6
for object in "${objects[@]}"; do
    target="$(basename "$object" .o)"
    test -f "oss-fuzz/options/${target}.options"
    # OSS-Fuzz exposes compiler arguments as space-delimited strings.
    # shellcheck disable=SC2086
    "$CXX" $CXXFLAGS \
        -no-pie \
        "$install_dir/zig_sancov_shim.o" \
        "$object" \
        $LIB_FUZZING_ENGINE \
        -o "$OUT/$target"
    test -x "$OUT/$target"

    if test -d "oss-fuzz/corpus/$target"; then
        zip -q -j \
            "$OUT/${target}_seed_corpus.zip" \
            "oss-fuzz/corpus/$target"/*
    fi
    if test -f "oss-fuzz/dictionaries/${target}.dict"; then
        cp "oss-fuzz/dictionaries/${target}.dict" "$OUT/${target}.dict"
    fi
    cp "oss-fuzz/options/${target}.options" "$OUT/${target}.options"
done
