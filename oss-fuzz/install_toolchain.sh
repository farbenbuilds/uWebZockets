#!/bin/bash
set -euo pipefail

apt-get update
apt-get install -y --no-install-recommends \
    binutils ca-certificates curl git xz-utils zip
rm -rf /var/lib/apt/lists/*

zig_version=0.16.0
zig_archive=/tmp/zig.tar.xz
curl -fsSL -o "$zig_archive" \
    "https://ziglang.org/download/${zig_version}/zig-x86_64-linux-${zig_version}.tar.xz"
printf '%s  %s\n' \
    "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00" \
    "$zig_archive" | sha256sum -c -
tar -xJf "$zig_archive" -C /opt
rm "$zig_archive"
ln -s "/opt/zig-x86_64-linux-${zig_version}/zig" /usr/local/bin/zig
