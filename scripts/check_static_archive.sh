#!/usr/bin/env sh
set -eu

archive=${1:?usage: check_static_archive.sh ARCHIVE}
members=$(ar t "$archive")

if [ -z "$members" ]; then
    printf '%s\n' "static archive has no object members: $archive" >&2
    exit 1
fi

if invalid=$(printf '%s\n' "$members" | grep -Ev '\.o$'); then
    printf '%s\n' "static archive contains non-object members:" >&2
    printf '%s\n' "$invalid" >&2
    exit 1
fi
