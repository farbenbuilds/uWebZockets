#!/usr/bin/env sh
set -eu

script_dir=$(CDPATH='' cd "$(dirname "$0")" && pwd)
cd "$script_dir/.."

fail()
{
    printf '%s\n' "$1" >&2
    exit 1
}

require_single_value()
{
    field_name=$1
    field_value=$2
    line_count=$(printf '%s\n' "$field_value" | sed '/^$/d' | wc -l | tr -d ' ')

    [ "$line_count" -eq 1 ] || fail "$field_name must contain exactly one version"
}

manifest_version=$(sed -n \
    's/^[[:space:]]*\.version = "\([^"]*\)",/\1/p' build.zig.zon)
require_single_value "build.zig.zon" "$manifest_version"

expected_version=${1:-$manifest_version}
printf '%s\n' "$expected_version" | grep -Eq \
    '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$' ||
    fail "release version is not valid Semantic Versioning"

flake_version=$(sed -n \
    's/^[[:space:]]*releaseVersion = "\([^"]*\)";/\1/p' flake.nix)
require_single_value "flake.nix" "$flake_version"

abi_major=$(sed -n \
    's/^#define UWZ_VERSION_MAJOR \([0-9][0-9]*\)$/\1/p' include/uWebZockets.h)
abi_minor=$(sed -n \
    's/^#define UWZ_VERSION_MINOR \([0-9][0-9]*\)$/\1/p' include/uWebZockets.h)
abi_patch=$(sed -n \
    's/^#define UWZ_VERSION_PATCH \([0-9][0-9]*\)$/\1/p' include/uWebZockets.h)
require_single_value "UWZ_VERSION_MAJOR" "$abi_major"
require_single_value "UWZ_VERSION_MINOR" "$abi_minor"
require_single_value "UWZ_VERSION_PATCH" "$abi_patch"
abi_version="${abi_major}.${abi_minor}.${abi_patch}"

c_api_version=$(sed -n \
    '/^pub export fn uwz_version()/,/^}/s/^[[:space:]]*return "\([^"]*\)";/\1/p' \
    src/c_api.zig)
require_single_value "uwz_version" "$c_api_version"

version_core=${expected_version%%+*}
version_core=${version_core%%-*}
version_major=$(printf '%s\n' "$version_core" | cut -d. -f1)
version_minor=$(printf '%s\n' "$version_core" | cut -d. -f2)
version_patch=$(printf '%s\n' "$version_core" | cut -d. -f3)

[ "$expected_version" = "$manifest_version" ] ||
    fail "build.zig.zon version does not match $expected_version"
[ "$expected_version" = "$flake_version" ] ||
    fail "flake.nix version does not match $expected_version"
[ "$version_core" = "$abi_version" ] ||
    fail "C ABI macros do not match $version_core"
[ "$expected_version" = "$c_api_version" ] ||
    fail "uwz_version does not match $expected_version"

grep -Fq "static_assert(UWZ_VERSION_MAJOR == $version_major);" \
    tests/c_api/header_cpp.cc || fail "C++ major-version assertion is stale"
grep -Fq "static_assert(UWZ_VERSION_MINOR == $version_minor);" \
    tests/c_api/header_cpp.cc || fail "C++ minor-version assertion is stale"
grep -Fq "static_assert(UWZ_VERSION_PATCH == $version_patch);" \
    tests/c_api/header_cpp.cc || fail "C++ patch-version assertion is stale"
grep -Fq "strcmp(uwz_version(), \"$expected_version\")" tests/c_api/smoke.c ||
    fail "C ABI smoke version is stale"
grep -Fq "## [$expected_version] -" CHANGELOG.md ||
    fail "CHANGELOG.md has no $expected_version release section"
grep -Fq "µWebZockets $expected_version is" CODEBASE.md ||
    fail "CODEBASE.md version is stale"
grep -Fq "# µWebZockets $expected_version Examples" \
    examples/readme_examples_test.md || fail "example documentation version is stale"

printf '%s\n' "release metadata matches $expected_version"
