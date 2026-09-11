#!/usr/bin/env sh
set -eu

archive=${1:?usage: check_static_archive.sh ARCHIVE}
if command -v zig >/dev/null 2>&1; then
    members=$(zig ar t "$archive")
else
    members=$(ar t "$archive")
fi

if [ -z "$members" ]; then
    printf '%s\n' "static archive has no object members: $archive" >&2
    exit 1
fi

if invalid=$(printf '%s\n' "$members" | grep -Ev '\.(o|obj)$'); then
    printf '%s\n' "static archive contains non-object members:" >&2
    printf '%s\n' "$invalid" >&2
    exit 1
fi
