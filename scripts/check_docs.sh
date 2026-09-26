#!/usr/bin/env sh
set -eu

script_dir=$(CDPATH='' cd "$(dirname "$0")" && pwd)
cd "$script_dir/.."

# Emit one link target per line from inline links and reference definitions.
# Fenced code blocks are skipped, as are targets with a URI scheme and
# anchor-only targets. Optional titles and angle-bracket wrappers are removed.
scan_links()
{
    awk '
        BEGIN { fenced = 0 }
        /^[[:space:]]*(```|~~~)/ {
            fenced = !fenced
            next
        }
        fenced {
            next
        }
        {
            line = $0
            while ((start = index(line, "](")) > 0) {
                rest = substr(line, start + 2)
                close_paren = index(rest, ")")
                if (close_paren == 0) {
                    break
                }
                emit(substr(rest, 1, close_paren - 1))
                line = substr(rest, close_paren + 1)
            }
            if (match(line, /^[[:space:]]*\[[^]]+\]:[[:space:]]*/)) {
                emit(substr(line, RLENGTH + 1))
            }
        }
        function emit(target) {
            sub(/[[:space:]]+["\047].*$/, "", target)
            if (target ~ /^</) {
                sub(/^</, "", target)
                sub(/>.*$/, "", target)
            }
            if (target == "" || target ~ /^#/ || target ~ /^[A-Za-z][A-Za-z0-9+.-]*:/) {
                return
            }
            anchor = index(target, "#")
            if (anchor > 0) {
                target = substr(target, 1, anchor - 1)
            }
            if (target != "") {
                print target
            }
        }
    ' "$1"
}

markdown_files=$(
    for file in README.md CODEBASE.md CI_CD_PIPELINE.md SECURITY.md \
        CONTRIBUTE.md THIRD_PARTY_NOTICES.md CODING_CONVENTION.md \
        AGENTS.md SKILL.md CHANGELOG.md; do
        if [ -f "$file" ]; then
            printf '%s\n' "$file"
        fi
    done
    for directory in docs benchmarks examples oss-fuzz; do
        if [ -d "$directory" ]; then
            find "$directory" -type f -name '*.md'
        fi
    done
)

failed=0
for file in $markdown_files; do
    dir=${file%/*}
    if [ "$dir" = "$file" ]; then
        dir=.
    fi
    targets=$(mktemp "${TMPDIR:-/tmp}/uwebzockets-docs.XXXXXX")
    scan_links "$file" > "$targets"
    while IFS= read -r target; do
        [ -n "$target" ] || continue
        if [ ! -e "$dir/$target" ]; then
            printf '%s: %s\n' "$file" "$target" >&2
            failed=1
        fi
    done < "$targets"
    rm -f "$targets"
done

if [ "$failed" -ne 0 ]; then
    exit 1
fi

printf '%s\n' "markdown documentation links resolve"
