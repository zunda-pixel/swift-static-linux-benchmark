#!/usr/bin/env bash
# Verifies that each variant is linked the way its name claims, and that every endpoint
# responds. Exits non-zero on any failure, since a mislabeled binary invalidates the benchmark.
set -euo pipefail

source "$(dirname "$0")/lib.sh"
trap stop_server EXIT

ENDPOINTS_ALL=(plaintext json string array array-reserved allocation parallel-allocation)
failures=0

pass() { echo "  ok: $*"; }
fail() { echo "  FAIL: $*"; failures=$((failures + 1)); }

# Address of a symbol in an `nm` listing, or empty.
# (Command output is captured into variables throughout: with pipefail, a reader that
# exits early, like `grep -q`, makes the writer fail with SIGPIPE.)
symbol_address() {
  awk -v s="$2" '$3 == s { print $1; exit }' <<<"$1"
}

# Expected allocator per variant: "glibc", or the mimalloc version that must be active.
# musl-sdk: the Static Linux SDK replaces musl's allocator in libc.a with its bundled
# mimalloc (swiftlang/swift-docker#488), so any mimalloc version other than ours is expected.
# The mimalloc version we link in is recorded by the Docker build.
MIMALLOC_VERSION=$(grep -oE 'mimalloc v[0-9]+\.[0-9]+\.[0-9]+' "$BIN_DIR/musl-mimalloc-v3/build-info.json" | cut -d' ' -f2 || true)

# glibc version banner (first line of `libc.so.6` run as a program) of the libc a variant uses.
glibc_banner() {
  local glibc out
  glibc=$(bundled_glibc_dir "$1")
  if [[ -n "$glibc" ]]; then
    out=$("$(bundled_loader "$1")" --library-path "$glibc" "$glibc/libc.so.6" 2>&1 || true)
  else
    out=$(ldd --version 2>&1 || true)
  fi
  echo "${out%%$'\n'*}"
}

# The host's libc.so.6, as resolved for any dynamically linked host program.
HOST_LIBC=$(ldd /bin/true | awk '$1 == "libc.so.6" { print $3; exit }')

read -r -a VARIANTS <<<"${VARIANTS:-glibc glibc-noble glibc-noble-2.39 glibc-noble-2.39-jemalloc musl-sdk musl-mimalloc-v3 musl-mallocng musl-sdk-fastmemcpy}"

# Variants that are expected to run on mimalloc (the SDK's or ours).
uses_mimalloc() {
  [[ $1 != glibc* && $1 != musl-mallocng ]]
}

for variant in "${VARIANTS[@]}"; do
  bin=$(server_binary "$variant")
  echo "== $variant ($bin)"
  if [[ ! -x "$bin" ]]; then
    fail "binary missing"
    continue
  fi
  file_out=$(file "$bin")
  glibc=$(bundled_glibc_dir "$variant")
  if [[ -n "$glibc" ]]; then
    ldd_out=$("$(bundled_loader "$variant")" --library-path "$BIN_DIR/$variant/lib:$glibc" --list "$bin" 2>&1 || true)
    expected_libc="$glibc/libc.so.6"
  else
    ldd_out=$(LD_LIBRARY_PATH="$BIN_DIR/$variant/lib" ldd "$bin" 2>&1 || true)
    expected_libc=$HOST_LIBC
  fi
  symbols=$(nm "$bin" 2>/dev/null || true)
  echo "$file_out"
  echo "$ldd_out"

  case $variant in
    glibc*)
      if grep -q "dynamically linked" <<<"$file_out"; then pass "dynamically linked against glibc"; else fail "expected a dynamic executable"; fi
      if grep -q '"swift_stdlib":"static"' "$BIN_DIR/$variant/build-info.json"; then
        if grep -q "libswiftCore" <<<"$ldd_out"; then fail "Swift runtime is linked dynamically, expected static"; else pass "Swift runtime is linked statically"; fi
      else
        if grep -q "$BIN_DIR/$variant/lib/libswiftCore.so" <<<"$ldd_out"; then pass "Swift runtime resolves to the bundled lib/"; else fail "libswiftCore.so is not resolved from bin/$variant/lib"; fi
      fi
      resolved_jemalloc=$(awk '$1 == "libjemalloc.so.2" { print $3; exit }' <<<"$ldd_out")
      if [[ $variant == *jemalloc ]]; then
        if [[ -n "$resolved_jemalloc" && "$resolved_jemalloc" == "$glibc/"* ]]; then pass "libjemalloc.so.2 resolves to $resolved_jemalloc"; else fail "libjemalloc.so.2 resolves to ${resolved_jemalloc:-nothing}, expected the bundled one"; fi
      elif [[ -n "$resolved_jemalloc" ]]; then
        fail "unexpected libjemalloc.so.2 dependency"
      fi
      resolved_libc=$(awk '$1 == "libc.so.6" { print $3; exit }' <<<"$ldd_out")
      if [[ -n "$resolved_libc" && "$(realpath "$resolved_libc")" == "$(realpath "$expected_libc")" ]]; then
        pass "libc.so.6 resolves to $resolved_libc"
      else
        fail "libc.so.6 resolves to ${resolved_libc:-nothing}, expected $expected_libc"
      fi
      if grep -q "not found" <<<"$ldd_out"; then fail "unresolved shared libraries"; else pass "all shared libraries resolved"; fi
      ;;
    *)
      if grep -q "statically linked" <<<"$file_out"; then pass "statically linked"; else fail "expected a static executable"; fi
      ;;
  esac

  mi_malloc=$(symbol_address "$symbols" mi_malloc)
  malloc=$(symbol_address "$symbols" malloc)
  if ! uses_mimalloc "$variant"; then
    if [[ -z "$mi_malloc" ]]; then pass "mimalloc is not linked"; else fail "unexpected mi_malloc symbol"; fi
    if [[ $variant == musl-mallocng ]]; then
      # mallocng keeps its state in the hidden global __malloc_context.
      if [[ -n "$(symbol_address "$symbols" __malloc_context)" ]]; then pass "musl mallocng is linked (__malloc_context)"; else fail "__malloc_context (mallocng) not found"; fi
    fi
  else
    if [[ -n "$mi_malloc" ]]; then pass "mimalloc is linked (mi_malloc @ $mi_malloc)"; else fail "mi_malloc symbol not found"; fi
    if [[ -n "$malloc" && "$malloc" == "$mi_malloc" ]]; then
      pass "malloc resolves to mi_malloc ($malloc)"
    else
      fail "malloc (@ ${malloc:-none}) does not resolve to mi_malloc (@ ${mi_malloc:-none})"
    fi
  fi

  # memcpy: musl-sdk-fastmemcpy replaces it with native/fast_memcpy.c on x86_64 only.
  fast_memcpy=$(symbol_address "$symbols" benchmark_fast_memcpy)
  if [[ $variant == musl-sdk-fastmemcpy && $(uname -m) == x86_64 ]]; then
    memcpy=$(symbol_address "$symbols" memcpy)
    if [[ -n "$fast_memcpy" && "$memcpy" == "$fast_memcpy" ]]; then pass "memcpy resolves to native/fast_memcpy.c ($memcpy)"; else fail "memcpy (@ ${memcpy:-none}) is not native/fast_memcpy.c (@ ${fast_memcpy:-none})"; fi
  elif [[ -n "$fast_memcpy" ]]; then
    fail "unexpected native/fast_memcpy.c in $variant"
  fi

  # Runtime check: mimalloc prints its version and options to stderr when MIMALLOC_VERBOSE=1.
  log=$(mktemp)
  start_server "$variant" "$log" "" MIMALLOC_VERBOSE=1 MALLOC_CONF=stats_print:true
  curl -sf "$BASE_URL/allocation" >/dev/null
  maps=$(cat "/proc/$SERVER_PID/maps" 2>/dev/null || true)
  stop_server
  runtime_version=$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' "$log" | head -n 1 || true)
  if [[ $variant == glibc* ]]; then
    if grep -q "mimalloc" "$log"; then fail "mimalloc output from the glibc build"; else pass "no mimalloc output at runtime"; fi
    # The libc actually mapped into the running server process.
    mapped_libc=$(awk '$6 ~ /libc\.so\.6$/ { print $6; exit }' <<<"$maps")
    if [[ -n "$mapped_libc" && "$(realpath "$mapped_libc")" == "$(realpath "$expected_libc")" ]]; then
      pass "running process uses $mapped_libc"
    else
      fail "running process uses ${mapped_libc:-no libc.so.6}, expected $expected_libc"
    fi
    # jemalloc prints its statistics at exit when MALLOC_CONF=stats_print:true.
    jemalloc_version=$(grep -oE '^Version: "[^"]+"' "$log" | head -n 1 | cut -d'"' -f2 || true)
    if [[ $variant == *jemalloc ]]; then
      if grep -q "libjemalloc.so.2" <<<"$maps"; then pass "running process maps libjemalloc.so.2"; else fail "libjemalloc.so.2 is not mapped in the running process"; fi
      if grep -q "jemalloc statistics" "$log"; then pass "jemalloc ${jemalloc_version:-?} active at runtime"; else fail "no jemalloc statistics with MALLOC_CONF=stats_print:true"; fi
    else
      if grep -q "libjemalloc" <<<"$maps"; then fail "unexpected libjemalloc mapping"; fi
      if grep -q "jemalloc statistics" "$log"; then fail "jemalloc output from a non-jemalloc build"; else pass "no jemalloc output at runtime"; fi
    fi
    banner=$(glibc_banner "$variant")
    echo "  $banner"
    version=$(grep -oE '[0-9]+\.[0-9]+(-[0-9A-Za-z.~+]+)?' <<<"${banner#*GLIBC }" | head -n 1 || true)
    if [[ $variant == *jemalloc ]]; then
      echo "jemalloc ${jemalloc_version:-unknown} (glibc ${version:-unknown})" >"$BIN_DIR/$variant/runtime-allocator.txt"
    else
      echo "glibc malloc (glibc ${version:-unknown})" >"$BIN_DIR/$variant/runtime-allocator.txt"
    fi
  elif [[ $variant == musl-mallocng ]]; then
    if grep -q "mimalloc" "$log"; then fail "mimalloc output from the mallocng build"; else pass "no mimalloc output at runtime"; fi
    musl_version=$(grep -oE 'musl [0-9.]+' "$BIN_DIR/$variant/build-info.json" | head -n 1 || true)
    echo "musl mallocng (${musl_version:-musl ?})" >"$BIN_DIR/$variant/runtime-allocator.txt"
  else
    if [[ -n "$runtime_version" ]]; then pass "mimalloc $runtime_version active at runtime"; else fail "no mimalloc version in MIMALLOC_VERBOSE=1 output"; fi
    if [[ $variant == musl-mimalloc-v3 ]]; then
      if [[ "$runtime_version" == "$MIMALLOC_VERSION" ]]; then pass "our mimalloc $MIMALLOC_VERSION overrides the SDK's"; else fail "expected mimalloc $MIMALLOC_VERSION, got ${runtime_version:-none}"; fi
    else
      if [[ -n "$runtime_version" && "$runtime_version" != "$MIMALLOC_VERSION" ]]; then pass "SDK-bundled mimalloc is in use"; else fail "expected the SDK-bundled mimalloc, got ${runtime_version:-none}"; fi
    fi
    echo "mimalloc ${runtime_version:-unknown}" >"$BIN_DIR/$variant/runtime-allocator.txt"
    sed -n '1,4p' "$log"
  fi
  rm -f "$log"

  # Smoke test every endpoint.
  log=$(mktemp)
  start_server "$variant" "$log" ""
  for endpoint in "${ENDPOINTS_ALL[@]}"; do
    body=$(curl -sf "$BASE_URL/$endpoint") || { fail "/$endpoint request failed"; continue; }
    if [[ -n "$body" ]]; then pass "/$endpoint -> ${body:0:80}"; else fail "/$endpoint returned an empty body"; fi
  done
  stop_server
  rm -f "$log"
done

if ((failures > 0)); then
  echo "$failures verification check(s) failed" >&2
  exit 1
fi
echo "All verification checks passed"
