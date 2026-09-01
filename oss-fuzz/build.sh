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

for target in http_framing ws_masking quic_packets; do
    # OSS-Fuzz exposes compiler arguments as space-delimited strings.
    # shellcheck disable=SC2086
    "$CXX" $CXXFLAGS \
        "$install_dir/oss-fuzz/${target}.o" \
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
