#!/usr/bin/env bash
# Builds all variants with Docker and exports them to bin/<variant>/.
# The binaries target linux/amd64 (the GitHub Actions runner), also when run on macOS.
#
# Usage: scripts/build.sh [variant...]   (default: glibc musl-sdk musl-mimalloc-v3)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PLATFORM=${PLATFORM:-linux/amd64}
variants=("$@")
((${#variants[@]})) || variants=(glibc musl-sdk musl-mimalloc-v3)

for variant in "${variants[@]}"; do
  echo "== building $variant"
  rm -rf "$ROOT/bin/$variant"
  docker buildx build \
    --platform "$PLATFORM" \
    --file "$ROOT/docker/Dockerfile" \
    --target "$variant" \
    --output "type=local,dest=$ROOT/bin/$variant" \
    "$ROOT"
done
