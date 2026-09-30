#!/usr/bin/env bash
# Builds musl's own allocator (mallocng) as object files for the musl-mallocng variant.
#
# The Static Linux SDK deletes musl's allocator objects from libc.a and adds mimalloc.o instead
# (and deletes operator new/delete from libc++abi.a, which mimalloc.o also provides). To measure
# musl's allocator, we build the same musl version from source and link its allocator objects,
# plus operator new/delete on top of malloc, into the executable. Objects on the link line take
# precedence over libc.a members, so the SDK's mimalloc.o is never pulled in.
#
# Usage: build-musl-malloc.sh <musl-source-dir> <native-source-dir> <output-dir>
# Writes <output-dir>/*.o, <output-dir>/objects.txt (one path per line) and <output-dir>/version.
set -euo pipefail

SRC=$1
NATIVE=$2
OUT=$3
ARCH=$(uname -m)
TARGET="${ARCH}-unknown-linux-musl"

SDK_MUSL=$(find "$HOME" -type d -path "*/musl-*.sdk/${ARCH}" -print -quit)
if [[ -z "$SDK_MUSL" ]]; then
  echo "error: musl sysroot for ${ARCH} not found (is the Static Linux SDK installed?)" >&2
  exit 1
fi
SDK_VERSION=$(basename "$(dirname "$SDK_MUSL")" | sed -E 's/^musl-(.*)\.sdk$/\1/')
VERSION=$(cat "$SRC/VERSION")
if [[ "$VERSION" != "$SDK_VERSION" ]]; then
  echo "error: musl source is $VERSION but the Static Linux SDK uses $SDK_VERSION" >&2
  exit 1
fi
echo "Building musl $VERSION allocator for $TARGET"

cd "$SRC"
AR=$(command -v llvm-ar || command -v ar)
RANLIB=$(command -v llvm-ranlib || command -v ranlib)
CC="clang --target=${TARGET}" AR="$AR" RANLIB="$RANLIB" \
  ./configure --target="$ARCH" --disable-shared --prefix=/unused
make -j"$(nproc)" AR="$AR" RANLIB="$RANLIB" lib/libc.a

mkdir -p "$OUT"
: >"$OUT/objects.txt"
# The objects the SDK deletes from libc.a (see swiftlang/swift-docker swift-ci/sdks/static-linux/
# scripts/build.sh): musl's malloc front ends and mallocng, and the string duplicators that
# mimalloc.o also defines.
for obj in obj/src/malloc/*.lo obj/src/malloc/mallocng/*.lo \
  obj/src/string/strdup.lo obj/src/string/strndup.lo obj/src/string/wcsdup.lo obj/src/legacy/valloc.lo; do
  name=$(echo "${obj#obj/src/}" | tr / -)
  cp "$obj" "$OUT/${name%.lo}.o"
  echo "$OUT/${name%.lo}.o" >>"$OUT/objects.txt"
done

clang++ --target="$TARGET" -O2 -fno-exceptions -fno-rtti -c "$NATIVE/new_delete.cpp" -o "$OUT/new_delete.o"
echo "$OUT/new_delete.o" >>"$OUT/objects.txt"

echo "$VERSION" >"$OUT/version"
cat "$OUT/objects.txt"

# Sanity check: the objects must define the allocator entry points.
symbols=$(nm $(cat "$OUT/objects.txt"))
for sym in malloc free calloc realloc aligned_alloc posix_memalign malloc_usable_size _Znwm _ZdlPv; do
  if ! grep -qE " [TW] ${sym}$" <<<"$symbols"; then
    echo "error: musl allocator objects do not define ${sym}" >&2
    exit 1
  fi
done
