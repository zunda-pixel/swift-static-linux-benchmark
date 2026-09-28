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

# Address of a symbol in the binary's symbol table, or empty.
symbol_address() {
  nm "$1" 2>/dev/null | awk -v s="$2" '$3 == s { print $1; exit }'
}

for variant in glibc musl musl-mimalloc; do
  bin=$(server_binary "$variant")
  echo "== $variant ($bin)"
  if [[ ! -x "$bin" ]]; then
    fail "binary missing"
    continue
  fi
  file "$bin"
  ldd "$bin" 2>&1 || true

  case $variant in
    glibc)
      if file "$bin" | grep -q "dynamically linked"; then pass "dynamically linked against glibc"; else fail "expected a dynamic executable"; fi
      if ldd "$bin" | grep -q "libswiftCore"; then fail "Swift runtime is linked dynamically"; else pass "Swift runtime is linked statically"; fi
      ;;
    musl | musl-mimalloc)
      if file "$bin" | grep -q "statically linked"; then pass "statically linked"; else fail "expected a static executable"; fi
      ;;
  esac

  mi_malloc=$(symbol_address "$bin" mi_malloc)
  malloc=$(symbol_address "$bin" malloc)
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
    body=$(curl -sf "$BASE_URL/$endpoint" | head -c 80) || { fail "/$endpoint request failed"; continue; }
    if [[ -n "$body" ]]; then pass "/$endpoint -> $body"; else fail "/$endpoint returned an empty body"; fi
  done
  stop_server
  rm -f "$log"
done

if ((failures > 0)); then
  echo "$failures verification check(s) failed" >&2
  exit 1
fi
echo "All verification checks passed"
