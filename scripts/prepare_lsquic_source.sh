#!/usr/bin/env sh

set -eu

source_dir=$1
output_dir=$2
patch_file=$3
patch_exe=$4

mkdir -p "${output_dir}"
cp -R -p "${source_dir}/." "${output_dir}/"
chmod -R u+w "${output_dir}"
"${patch_exe}" -f -d "${output_dir}" -p1 -i "${patch_file}"
