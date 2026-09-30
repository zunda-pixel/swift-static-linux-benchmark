# Shared helpers for starting and stopping benchmark servers. Source this file.

ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
BIN_DIR=${BIN_DIR:-$ROOT/bin}
PORT=${PORT:-8080}
BASE_URL="http://127.0.0.1:${PORT}"

server_binary() {
  echo "$BIN_DIR/$1/BenchmarkServer"
}

# Dynamic loader of a bundled glibc (glibc-noble-2.39*), or empty when the host glibc is used.
# Its name depends on the architecture (ld-linux-x86-64.so.2, ld-linux-aarch64.so.1).
bundled_loader() {
  local loader
  for loader in "$BIN_DIR/$1"/glibc/ld-linux-*.so.*; do
    [[ -x "$loader" ]] && { echo "$loader"; return; }
  done
}

# Directory of a bundled glibc, or empty when the host glibc is used.
bundled_glibc_dir() {
  local loader
  loader=$(bundled_loader "$1")
  [[ -n "$loader" ]] && dirname "$loader" || true
}

# Command line that starts the server binary. Shared libraries a variant ships in lib/ are
# found via LD_LIBRARY_PATH (currently none: every variant links the Swift runtime
# statically). A variant with a bundled glibc is started
# through that glibc's dynamic loader, so the bundled libc.so.6 is used instead of the host's.
server_command() {
  local bin loader
  bin=$(server_binary "$1")
  loader=$(bundled_loader "$1")
  if [[ -n "$loader" ]]; then
    echo "$loader --library-path $BIN_DIR/$1/lib:$(dirname "$loader") $bin"
  else
    echo "$bin"
  fi
}

# start_server <variant> <logfile> <cpu-list or ""> [VAR=value...]
# Sets SERVER_PID.
start_server() {
  local variant=$1 log=$2 cpus=${3:-}
  shift 3
  local cmd=(env PORT="$PORT" LD_LIBRARY_PATH="$BIN_DIR/$variant/lib" "$@")
  cmd+=($(server_command "$variant"))
  if [[ -n "$cpus" ]]; then
    cmd=(taskset -c "$cpus" "${cmd[@]}")
  fi
  "${cmd[@]}" >"$log" 2>&1 &
  SERVER_PID=$!

  for _ in $(seq 1 100); do
    if curl -sf "$BASE_URL/health" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "error: $variant server exited during startup" >&2
      cat "$log" >&2
      return 1
    fi
    sleep 0.1
  done
  echo "error: $variant server did not become healthy" >&2
  cat "$log" >&2
  return 1
}

stop_server() {
  [[ -n "${SERVER_PID:-}" ]] || return 0
  kill -TERM "$SERVER_PID" 2>/dev/null || true
  for _ in $(seq 1 50); do
    kill -0 "$SERVER_PID" 2>/dev/null || break
    sleep 0.1
  done
  kill -KILL "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=
}
