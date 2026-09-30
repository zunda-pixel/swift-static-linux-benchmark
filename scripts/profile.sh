#!/usr/bin/env bash
# Profiles each variant under a fixed load with perf, to explain throughput and p99 differences.
#
# For every variant and endpoint, the server is loaded with oha for DURATION seconds twice:
#   1. `perf stat`: CPU time, context switches, page faults, and scheduler / syscall tracepoints
#      (futex, epoll_wait, read/write, mmap/munmap/madvise, ...), later normalized per request.
#   2. `perf record`: flat CPU profile (no call graphs), reported by shared object and symbol.
#   3. `perf record -e syscalls:sys_enter_futex,sched:sched_switch --call-graph dwarf` for
#      CALLER_DURATION seconds: who calls futex and where threads block (callers.txt).
#
# Needs perf and permission to use it (run as a user that can sudo). Output goes to
# $RESULTS_DIR/profile/<variant>/<endpoint>/.
#
# Configuration (environment variables):
#   VARIANTS     default: "glibc glibc-noble-2.39 glibc-noble-2.39-jemalloc musl-sdk"
#   ENDPOINTS    default: "plaintext json allocation"
#   CONCURRENCY  default: 50
#   WARMUP       seconds, default: 5
#   DURATION     seconds per perf pass, default: 20
#   CALLER_DURATION  seconds for the call graph pass, default: 10 (0 skips it)
#   SERVER_CPUS / CLIENT_CPUS   taskset CPU lists; default splits the CPUs in half
#   PERF         default: perf
set -euo pipefail

source "$(dirname "$0")/lib.sh"
trap stop_server EXIT

read -r -a VARIANTS <<<"${VARIANTS:-glibc glibc-noble-2.39 glibc-noble-2.39-jemalloc musl-sdk}"
read -r -a ENDPOINTS <<<"${ENDPOINTS:-plaintext json allocation}"
CONCURRENCY=${CONCURRENCY:-50}
WARMUP=${WARMUP:-5}
DURATION=${DURATION:-20}
CALLER_DURATION=${CALLER_DURATION:-10}
PERF=${PERF:-perf}
OHA=${OHA:-oha}
# Ubuntu's libc.so.6 only exports public symbols; debuginfod lets perf report name internal
# functions such as _int_malloc (if perf was built with debuginfod support).
export DEBUGINFOD_URLS=${DEBUGINFOD_URLS:-https://debuginfod.ubuntu.com}
OUT=${RESULTS_DIR:-$ROOT/results}/profile

NPROC=$(nproc)
HALF=$((NPROC / 2))
SERVER_CPUS=${SERVER_CPUS:-0-$((HALF - 1))}
CLIENT_CPUS=${CLIENT_CPUS:-$HALF-$((NPROC - 1))}

# Counters and tracepoints of interest. Unsupported ones (e.g. hardware counters in some VMs)
# are dropped, since a single unknown event makes `perf stat` fail.
CANDIDATE_EVENTS=(
  task-clock context-switches cpu-migrations page-faults cycles instructions
  sched:sched_switch sched:sched_wakeup
  syscalls:sys_enter_futex syscalls:sys_enter_epoll_wait syscalls:sys_enter_epoll_pwait
  syscalls:sys_enter_read syscalls:sys_enter_write syscalls:sys_enter_writev
  syscalls:sys_enter_readv syscalls:sys_enter_recvfrom syscalls:sys_enter_sendto
  syscalls:sys_enter_sendmsg syscalls:sys_enter_recvmsg
  syscalls:sys_enter_mmap syscalls:sys_enter_munmap syscalls:sys_enter_madvise
  syscalls:sys_enter_mprotect syscalls:sys_enter_brk
)
EVENTS=()
for event in "${CANDIDATE_EVENTS[@]}"; do
  if sudo "$PERF" stat -e "$event" -- true >/dev/null 2>&1; then
    EVENTS+=("$event")
  else
    echo "note: perf event $event is not available; skipping"
  fi
done
EVENT_LIST=$(IFS=,; echo "${EVENTS[*]}")

client() {
  taskset -c "$CLIENT_CPUS" "$OHA" "$@"
}

# swift-demangle is only in the Swift toolchain, so fall back to the toolchain image.
demangle() {
  if command -v swift >/dev/null 2>&1; then
    swift demangle --simplified
  else
    docker run --rm -i swift:6.4.0-resolute swift demangle --simplified
  fi
}

mkdir -p "$OUT"
cat >"$OUT/config.json" <<EOF
{
  "variants": "${VARIANTS[*]}",
  "endpoints": "${ENDPOINTS[*]}",
  "concurrency": $CONCURRENCY,
  "warmup_seconds": $WARMUP,
  "duration_seconds": $DURATION,
  "server_cpus": "$SERVER_CPUS",
  "client_cpus": "$CLIENT_CPUS",
  "perf_version": "$(sudo "$PERF" --version 2>&1)",
  "events": "$EVENT_LIST"
}
EOF

for variant in "${VARIANTS[@]}"; do
  echo "== $variant"
  mkdir -p "$OUT/$variant"
  start_server "$variant" "$OUT/$variant/server.log" "$SERVER_CPUS"

  for endpoint in "${ENDPOINTS[@]}"; do
    dir="$OUT/$variant/$endpoint"
    mkdir -p "$dir"
    url="$BASE_URL/$endpoint"
    client -c "$CONCURRENCY" -z "${WARMUP}s" --no-tui --output-format json "$url" >/dev/null

    # 1. Counters, over the same window as the load.
    sudo "$PERF" stat -x, -o "$dir/stat.csv" -e "$EVENT_LIST" -p "$SERVER_PID" -- sleep "$DURATION" &
    perf_pid=$!
    client -c "$CONCURRENCY" -z "${DURATION}s" --no-tui --output-format json "$url" >"$dir/oha-stat.json"
    wait "$perf_pid"

    # 2. Flat CPU profile.
    sudo "$PERF" record -q -F 999 -p "$SERVER_PID" -o "$dir/perf.data" -- sleep "$DURATION" &
    perf_pid=$!
    client -c "$CONCURRENCY" -z "${DURATION}s" --no-tui --output-format json "$url" >"$dir/oha-record.json"
    wait "$perf_pid"
    sudo chown "$(id -u):$(id -g)" "$dir/perf.data"

    "$PERF" report -i "$dir/perf.data" --stdio --no-children --sort dso --percent-limit 0.5 2>/dev/null >"$dir/dso.txt" || true
    "$PERF" report -i "$dir/perf.data" --stdio --no-children --sort dso,sym --percent-limit 0 2>/dev/null \
      | demangle >"$dir/symbols.txt" || true
    # 3. Callers of futex and of context switches (DWARF unwinding; the binaries keep debug info).
    if ((CALLER_DURATION > 0)); then
      sudo "$PERF" record -q -e syscalls:sys_enter_futex,sched:sched_switch --call-graph dwarf,16384 \
        -p "$SERVER_PID" -o "$dir/callers.data" -- sleep "$CALLER_DURATION" &
      perf_pid=$!
      client -c "$CONCURRENCY" -z "${CALLER_DURATION}s" --no-tui --output-format json "$url" >/dev/null
      wait "$perf_pid" || true
      sudo chown "$(id -u):$(id -g)" "$dir/callers.data" 2>/dev/null || true
      "$PERF" report -i "$dir/callers.data" --stdio --no-children --sort sym --percent-limit 2 \
        -g caller,2,callee,function,percent --max-stack 16 2>/dev/null | demangle >"$dir/callers.txt" || true
      rm -f "$dir/callers.data"
    fi
    echo "  $endpoint done"
  done

  stop_server
done
echo "Done. Profiles in $OUT"
