#!/bin/bash
set -euo pipefail

exec "$SRC/uWebZockets/oss-fuzz/build.sh"
