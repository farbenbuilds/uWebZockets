#!/usr/bin/env sh
set -eu

script_directory=$(CDPATH='' cd "$(dirname "$0")" && pwd)
repository=$(CDPATH='' cd "$script_directory/.." && pwd)
output=$(mktemp -d "${TMPDIR:-/tmp}/uwz_sql_gates.XXXXXXXX")
trap 'rm -rf "$output"' 0 1 2 15
command -v zig >/dev/null
command -v nm >/dev/null

probe()
{
    name=$1
    enabled=$2
    sqlite=$3
    exercise=$4
    expect_sql=$5
    expect_sqlite=$6
    (
        cd "$repository/tests/package_consumer"
        zig build -Doptimize=ReleaseSafe -Dsql="$enabled" -Dsqlite="$sqlite" \
            -Dexercise-sql="$exercise" --prefix "$output/$name"
    )
    nm -a "$output/$name/bin/package_consumer" > "$output/$name.symbols"
    has_sql=false
    has_sqlite=false
    if grep -Eq 'sql\.(root|db|pool|connection|tx|pg_auth|sqlite)\.|main\.sql_surface' "$output/$name.symbols"; then has_sql=true; fi
    if grep -Eq '[[:space:]]sqlite3_[[:alnum:]_]+' "$output/$name.symbols"; then has_sqlite=true; fi
    if [ "$has_sql" != "$expect_sql" ] || [ "$has_sqlite" != "$expect_sqlite" ]; then
        printf '%s\n' "$name: unexpected SQL=$has_sql SQLite=$has_sqlite symbols" >&2
        exit 1
    fi
    printf '%s\n' "$name: SQL=$has_sql SQLite=$has_sqlite"
}

probe disabled false false false false false
probe postgres true false true true false
probe sqlite true true true true true
probe unused true true false false false
