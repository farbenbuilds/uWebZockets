#!/usr/bin/env sh
set -eu

usage()
{
    printf '%s\n' "usage: scripts/bump_version.sh X.Y.Z" >&2
    exit 2
}

[ "$#" -eq 1 ] || usage

new_version=$1
printf '%s\n' "$new_version" | grep -Eq \
    '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ||
    {
        printf '%s\n' "version must be a plain X.Y.Z semantic version" >&2
        exit 2
    }

script_dir=$(CDPATH='' cd "$(dirname "$0")" && pwd)
cd "$script_dir/.."

major=${new_version%%.*}
minor_and_patch=${new_version#*.}
minor=${minor_and_patch%%.*}
patch=${minor_and_patch#*.}

# Rewrites one file through a temporary so the script works with the
# incompatible -i conventions of GNU and BSD sed.
rewrite()
{
    file=$1
    pattern=$2
    replacement=$3
    tmp_file=$(mktemp "${TMPDIR:-/tmp}/uwebzockets-bump.XXXXXX")
    trap 'rm -f "$tmp_file"' 0 1 2 15
    sed "s|$pattern|$replacement|" "$file" > "$tmp_file"
    mv "$tmp_file" "$file"
    trap - 0 1 2 15
}

# The single Zig source of truth; every other copy below is derived from it.
rewrite src/version.zig \
    '^pub const semantic = std.SemanticVersion{ .major = [0-9]*, .minor = [0-9]*, .patch = [0-9]* };$' \
    "pub const semantic = std.SemanticVersion{ .major = $major, .minor = $minor, .patch = $patch };"

rewrite build.zig.zon \
    '^\([[:space:]]*\)\.version = "[^"]*",$' \
    '\1.version = "'"$new_version"'",'

rewrite flake.nix \
    '^\([[:space:]]*\)releaseVersion = "[^"]*";$' \
    '\1releaseVersion = "'"$new_version"'";'

rewrite include/uWebZockets.h \
    '^#define UWZ_VERSION_MAJOR .*$' \
    "#define UWZ_VERSION_MAJOR $major"
rewrite include/uWebZockets.h \
    '^#define UWZ_VERSION_MINOR .*$' \
    "#define UWZ_VERSION_MINOR $minor"
rewrite include/uWebZockets.h \
    '^#define UWZ_VERSION_PATCH .*$' \
    "#define UWZ_VERSION_PATCH $patch"

rewrite tests/c_api/header_cpp.cc \
    '^static_assert(UWZ_VERSION_MAJOR == .*);$' \
    "static_assert(UWZ_VERSION_MAJOR == $major);"
rewrite tests/c_api/header_cpp.cc \
    '^static_assert(UWZ_VERSION_MINOR == .*);$' \
    "static_assert(UWZ_VERSION_MINOR == $minor);"
rewrite tests/c_api/header_cpp.cc \
    '^static_assert(UWZ_VERSION_PATCH == .*);$' \
    "static_assert(UWZ_VERSION_PATCH == $patch);"

rewrite tests/c_api/smoke.c \
    'strcmp(uwz_version(), "[^"]*")' \
    'strcmp(uwz_version(), "'"$new_version"'")'

rewrite CODEBASE.md \
    '^µWebZockets [0-9][0-9.]* is' \
    "µWebZockets $new_version is"

rewrite examples/readme_examples_test.md \
    '^# µWebZockets [0-9][0-9.]* Examples$' \
    "# µWebZockets $new_version Examples"

if grep -Fq "## [$new_version] -" CHANGELOG.md; then
    printf '%s\n' "CHANGELOG.md already has a $new_version section"
else
    section_file=$(mktemp "${TMPDIR:-/tmp}/uwebzockets-section.XXXXXX")
    trap 'rm -f "$section_file"' 0 1 2 15
    {
        printf '## [%s] - %s\n' "$new_version" "$(date +%Y-%m-%d)"
        printf '\n### Added\n\n-\n'
        printf '\n### Changed\n\n-\n'
        printf '\n### Security\n\n-\n'
        printf '\n'
    } > "$section_file"

    changelog_file=$(mktemp "${TMPDIR:-/tmp}/uwebzockets-changelog.XXXXXX")
    awk -v section_file="$section_file" '
        !inserted && /^## \[/ {
            while ((getline line < section_file) > 0) print line
            close(section_file)
            inserted = 1
        }
        { print }
        END {
            if (!inserted) {
                while ((getline line < section_file) > 0) print line
                close(section_file)
            }
        }
    ' CHANGELOG.md > "$changelog_file"
    mv "$changelog_file" CHANGELOG.md
    rm -f "$section_file"
    trap - 0 1 2 15
fi

sh scripts/check_release_version.sh "$new_version"
