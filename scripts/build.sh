#!/usr/bin/env bash
# Builds all variants with Docker and exports them to bin/<variant>/.
# The binaries target linux/amd64 by default (PLATFORM=linux/arm64 for ARM64), also on macOS.
#
# Usage: scripts/build.sh [variant...]   (default: all variants)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PLATFORM=${PLATFORM:-linux/amd64}
variants=("$@")
((${#variants[@]})) || variants=(glibc glibc-noble glibc-noble-2.39 glibc-noble-2.39-jemalloc musl-sdk musl-mimalloc-v3 musl-mallocng musl-sdk-fastmemcpy)

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
