#!/usr/bin/env bash
# Compiles mimalloc into a single object file for the Swift Static Linux SDK (musl).
#
# This follows mimalloc's documented static override for Unix: link mimalloc.o into the
# final executable so its malloc/free/... definitions are used instead of libc's.
# Flags mirror mimalloc's CMake `mimalloc-obj` target with MI_OVERRIDE=ON and MI_LIBC_MUSL=ON.
#
# Usage: build-mimalloc.sh <mimalloc-source-dir> <output.o>
set -euo pipefail

SRC=$1
OUT=$2
ARCH=$(uname -m)

SYSROOT=$(find "$HOME" -type d -path "*/musl-*.sdk/${ARCH}" -print -quit)
if [[ -z "$SYSROOT" ]]; then
  echo "error: musl sysroot for ${ARCH} not found (is the Static Linux SDK installed?)" >&2
  exit 1
fi
echo "Using musl sysroot: $SYSROOT"

clang \
  --target="${ARCH}-unknown-linux-musl" \
  --sysroot="$SYSROOT" \
  -O3 -DNDEBUG \
  -DMI_MALLOC_OVERRIDE \
  -DMI_LIBC_MUSL=1 \
  -fno-builtin-malloc \
  -ftls-model=local-dynamic \
  -fPIC \
  -fvisibility=hidden \
  -Wno-unknown-pragmas \
  -I "$SRC/include" \
  -c "$SRC/src/static.c" \
  -o "$OUT"

# Sanity check: the object must export the standard allocation entry points.
# (nm output is captured first: with pipefail, `nm | grep -q` fails on SIGPIPE.)
symbols=$(nm "$OUT")
for sym in malloc free calloc realloc posix_memalign aligned_alloc malloc_usable_size; do
  if ! grep -qE " [TW] ${sym}$" <<<"$symbols"; then
    echo "error: $OUT does not define ${sym}" >&2
    grep -E " ${sym}$" <<<"$symbols" >&2 || true
    exit 1
  fi
done
echo "Built $OUT"
