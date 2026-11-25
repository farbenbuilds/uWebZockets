#!/usr/bin/env sh
# Keeps benchmark result directories reviewable: one README summary and one
# checksum manifest per run. Raw evidence archives stay out of the repository.
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
cd "$script_dir/.."

[ -d benchmarks/results ] || exit 0

failed=0
for file in $(find benchmarks/results -type f | sort); do
    base=${file##*/}
    case "$base" in
        README.md | manifest.sha256)
            ;;
        *.tgz | *.tar.gz)
            printf '%s\n' "raw benchmark archive must not be committed: $file"
            failed=1
            ;;
        *)
            printf '%s\n' "unarchived benchmark artifact: $file"
            failed=1
            ;;
    esac
done

for manifest in $(find benchmarks/results -name manifest.sha256 | sort); do
    directory=${manifest%/*}
    if [ ! -f "$directory/README.md" ]; then
        printf '%s\n' "manifest has no README beside it: $manifest"
        failed=1
        continue
    fi
    if ! (cd "$directory" && sha256sum -c manifest.sha256 >/dev/null); then
        printf '%s\n' "manifest does not match README.md: $manifest"
        failed=1
    fi
done

if [ "$failed" -ne 0 ]; then
    printf '%s\n' \
        "keep README.md and manifest.sha256 only; raw evidence archives stay local" >&2
fi
exit "$failed"
