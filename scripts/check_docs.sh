#!/usr/bin/env sh
set -eu

script_dir=$(CDPATH='' cd "$(dirname "$0")" && pwd)
cd "$script_dir/.."

# Emit one inline link target per line. Fenced code blocks are skipped, as are
# targets with a URI scheme and anchor-only targets.
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
                target = substr(rest, 1, close_paren - 1)
                line = substr(rest, close_paren + 1)
                if (target == "" || target ~ /^#/ || target ~ /^[A-Za-z][A-Za-z0-9+.-]*:/) {
                    continue
                }
                anchor = index(target, "#")
                if (anchor > 0) {
                    target = substr(target, 1, anchor - 1)
                }
                if (target != "") {
                    print target
                }
            }
        }
    ' "$1"
}

markdown_files=$(
    for file in README.md CODEBASE.md CI_CD_PIPELINE.md SECURITY.md CONTRIBUTING.md; do
        if [ -f "$file" ]; then
            printf '%s\n' "$file"
        fi
    done
    if [ -d docs ]; then
        find docs -type f -name '*.md'
    fi
)

failed=0
for file in $markdown_files; do
    dir=${file%/*}
    if [ "$dir" = "$file" ]; then
        dir=.
    fi
    for target in $(scan_links "$file"); do
        if [ ! -e "$dir/$target" ]; then
            printf '%s: %s\n' "$file" "$target" >&2
            failed=1
        fi
    done
done

if [ "$failed" -ne 0 ]; then
    exit 1
fi

printf '%s\n' "markdown documentation links resolve"
