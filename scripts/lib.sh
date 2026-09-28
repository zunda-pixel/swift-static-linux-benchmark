# Shared helpers for starting and stopping benchmark servers. Source this file.

ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
BIN_DIR=${BIN_DIR:-$ROOT/bin}
PORT=${PORT:-8080}
BASE_URL="http://127.0.0.1:${PORT}"

server_binary() {
  echo "$BIN_DIR/$1/BenchmarkServer"
}

# start_server <variant> <logfile> <cpu-list or ""> [VAR=value...]
# Sets SERVER_PID.
start_server() {
  local variant=$1 log=$2 cpus=${3:-}
  shift 3
  local bin
  bin=$(server_binary "$variant")
  local cmd=(env PORT="$PORT" "$@" "$bin")
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
