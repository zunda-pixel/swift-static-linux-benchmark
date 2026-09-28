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

for variant in glibc musl musl-mimalloc; do
  bin=$(server_binary "$variant")
  echo "== $variant ($bin)"
  if [[ ! -x "$bin" ]]; then
    fail "binary missing"
    continue
  fi
  file_out=$(file "$bin")
  ldd_out=$(ldd "$bin" 2>&1 || true)
  symbols=$(nm "$bin" 2>/dev/null || true)
  echo "$file_out"
  echo "$ldd_out"

  case $variant in
    glibc)
      if grep -q "dynamically linked" <<<"$file_out"; then pass "dynamically linked against glibc"; else fail "expected a dynamic executable"; fi
      if grep -q "libswiftCore" <<<"$ldd_out"; then fail "Swift runtime is linked dynamically"; else pass "Swift runtime is linked statically"; fi
      ;;
    musl | musl-mimalloc)
      if grep -q "statically linked" <<<"$file_out"; then pass "statically linked"; else fail "expected a static executable"; fi
      ;;
  esac

  mi_malloc=$(symbol_address "$symbols" mi_malloc)
  malloc=$(symbol_address "$symbols" malloc)
  case $variant in
    musl-mimalloc)
      if [[ -n "$mi_malloc" ]]; then pass "mimalloc is linked (mi_malloc @ $mi_malloc)"; else fail "mi_malloc symbol not found"; fi
      if [[ -n "$malloc" && "$malloc" == "$mi_malloc" ]]; then
        pass "malloc resolves to mi_malloc ($malloc)"
      else
        fail "malloc (@ ${malloc:-none}) does not resolve to mi_malloc (@ ${mi_malloc:-none})"
      fi
      ;;
    *)
      if [[ -z "$mi_malloc" ]]; then pass "mimalloc is not linked"; else fail "unexpected mi_malloc symbol"; fi
      ;;
  esac

  # Runtime check: mimalloc prints its options to stderr when MIMALLOC_VERBOSE=1.
  log=$(mktemp)
  start_server "$variant" "$log" "" MIMALLOC_VERBOSE=1
  curl -sf "$BASE_URL/allocation" >/dev/null
  stop_server
  if grep -q "mimalloc" "$log"; then
    [[ $variant == musl-mimalloc ]] && pass "mimalloc active at runtime" || fail "mimalloc output from a non-mimalloc build"
  else
    [[ $variant == musl-mimalloc ]] && fail "no mimalloc output at runtime (MIMALLOC_VERBOSE=1)" || pass "no mimalloc output at runtime"
  fi
  if [[ $variant == musl-mimalloc ]]; then
    sed -n '1,5p' "$log"
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
