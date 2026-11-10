#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_dir="$(cd -- "${script_dir}/../.." && pwd)"

if [[ "${1:-}" == --clients ]]; then
    exec python3 "${script_dir}/probe.py" run \
        --source "${source_dir}" --artifacts "$2" \
        --server "${script_dir}/zig-out/bin/static_interop"
fi

if [[ "$#" -ne 2 || ! "$1" =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s\n' 'usage: run.sh EXACT_SOURCE_REV NEW_ARTIFACT_DIR' >&2
    exit 2
fi
source_rev="$1"
artifact_dir="$(realpath -m -- "$2")"
test "$(git -C "${source_dir}" rev-parse HEAD)" = "${source_rev}"
test -z "$(git -C "${source_dir}" status --porcelain --untracked-files=normal)"
if [[ "${artifact_dir}/" == "${source_dir}/"* ]]; then
    printf '%s\n' 'artifacts must be outside the source checkout' >&2
    exit 2
fi
test ! -e "${artifact_dir}"
mkdir -p -- "${artifact_dir}"

finish() {
    gate_status=$?
    trap - EXIT
    printf '%s\n' "${gate_status}" >"${artifact_dir}/gate.status"
    exit "${gate_status}"
}
trap finish EXIT

record() {
    local label="$1"
    shift
    printf '%q ' "$@" >"${artifact_dir}/${label}.command"
    printf '\n' >>"${artifact_dir}/${label}.command"
    local status=0
    "$@" >"${artifact_dir}/${label}.log" 2>&1 || status=$?
    printf '%s\n' "${status}" >"${artifact_dir}/${label}.status"
    return "${status}"
}

printf '%s\n' "${source_rev}" >"${artifact_dir}/source.rev"
git -C "${source_dir}" ls-tree -r HEAD >"${artifact_dir}/source.tree"
git -C "${source_dir}" submodule status >"${artifact_dir}/source.submodules"
git -C "${source_dir}" status --porcelain --untracked-files=normal >"${artifact_dir}/source.status"
(
    cd -- "${source_dir}"
    sha256sum flake.lock build.zig.zon build.zig.zon.json build.zig.zon.nix build.zig.zon.txt \
        scripts/http3_compliance/flake.nix scripts/http3_compliance/flake.lock \
        scripts/http3_compliance/expectations.json \
        tests/static_interop/build.zig tests/static_interop/build.zig.zon \
        tests/static_interop/main.zig tests/static_interop/run.sh tests/static_interop/probe.py
) >"${artifact_dir}/source.sha256"
nix --version >"${artifact_dir}/nix.version"

record build nix develop --no-write-lock-file "${source_dir}" --command bash -c '
    set -euo pipefail
    cd -- "$1"
    zig version
    test "$(zig version)" = 0.16.0
    command -v zig
    printf "%s\n" "${UWEBZOCKETS_RUNTIME_DYNAMIC_LINKER:-}" >"$2/server.loader"
    printf "%s\n" "${UWEBZOCKETS_RUNTIME_LIBRARY_PATH:-}" >"$2/server.library_path"
    zig build -j2 -Doptimize=ReleaseSafe --summary all
' _ "${script_dir}" "${artifact_dir}"

record clients nix develop --no-write-lock-file "${source_dir}/scripts/http3_compliance" \
    --command bash "${script_dir}/run.sh" --clients "${artifact_dir}"
git -C "${source_dir}" status --porcelain --untracked-files=normal >"${artifact_dir}/source.status.after"
test ! -s "${artifact_dir}/source.status.after"
