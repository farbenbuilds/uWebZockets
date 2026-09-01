#!/usr/bin/env sh
set -eu

if ! command -v rg >/dev/null 2>&1; then
    printf '%s\n' "ripgrep is required for convention checks" >&2
    exit 1
fi

failed=0

bad_files=$(
    rg --files .github src examples tests scripts fuzz oss-fuzz benchmarks include misc patches |
        while IFS= read -r file; do
            base=${file##*/}
            case "$base" in
                build.zig | build.zig.zon | *.schema.json | CODE_OF_CONDUCT.md | COMMIT_CONVENTION.md | Dockerfile | PULL_REQUEST_TEMPLATE.md | README.md | uWebZockets.h)
                    continue
                    ;;
            esac
            stem=${base%.*}
            case "$stem" in
                *[!a-z0-9_]*)
                    printf '%s\n' "$file"
                    ;;
            esac
        done
)

if [ -n "$bad_files" ]; then
    printf '%s\n' "file names must use snake_case:"
    printf '%s\n' "$bad_files"
    failed=1
fi

if rg -n --pcre2 '\b(?:(?:pub|export|inline|noinline)\s+)*fn\s+(?!LLVMFuzzerTestOneInput\b)[A-Za-z_][A-Za-z0-9]*[A-Z][A-Za-z0-9]*\b' build.zig src examples tests fuzz; then
    printf '%s\n' "function names must use snake_case"
    failed=1
fi

if rg -n --pcre2 '\b(?:const|var)\s+[a-z][A-Za-z0-9]*[A-Z][A-Za-z0-9]*\b' build.zig src examples tests fuzz; then
    printf '%s\n' "variable names must use snake_case"
    failed=1
fi

if rg -n --pcre2 '[\x{1F1E6}-\x{1FAFF}\x{2600}-\x{27BF}]' . -g '*.{c,h,json,md,nix,sh,yaml,yml,zig,zon}' -g '!.agents/**' -g '!.git/**' -g '!.zig-cache/**' -g '!vendor/**' -g '!zig-out/**' -g '!zig-pkg/**'; then
    printf '%s\n' "emoji characters are not permitted"
    failed=1
fi

exit "$failed"
