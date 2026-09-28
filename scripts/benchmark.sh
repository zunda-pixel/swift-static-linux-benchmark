#!/usr/bin/env bash
# Runs the benchmark matrix: repetitions x variants x endpoints x concurrencies.
#
# All variants run on the same machine within one invocation. The variant order is
# rotated on every repetition so drift over time (thermal, noisy neighbours) does not
# consistently favour one variant.
#
# Configuration (environment variables):
#   VARIANTS       default: "glibc musl musl-mimalloc"
#   ENDPOINTS      default: "plaintext json allocation parallel-allocation"
#   CONCURRENCIES  default: "1 10 25 50 100"
#   REPS           default: 5
#   WARMUP         seconds, default: 10 (once per endpoint after server start)
#   DURATION       seconds per measurement, default: 30
#   SERVER_CPUS / CLIENT_CPUS   taskset CPU lists; default splits the CPUs in half
#   OHA            path to oha, default: oha
#   RESULTS_DIR    default: ./results
set -euo pipefail

source "$(dirname "$0")/lib.sh"
trap stop_server EXIT

read -r -a VARIANTS <<<"${VARIANTS:-glibc musl musl-mimalloc}"
read -r -a ENDPOINTS <<<"${ENDPOINTS:-plaintext json allocation parallel-allocation}"
read -r -a CONCURRENCIES <<<"${CONCURRENCIES:-1 10 25 50 100}"
REPS=${REPS:-5}
WARMUP=${WARMUP:-10}
DURATION=${DURATION:-30}
OHA=${OHA:-oha}
RESULTS_DIR=${RESULTS_DIR:-$ROOT/results}

NPROC=$(nproc)
if ((NPROC >= 2)); then
  HALF=$((NPROC / 2))
  SERVER_CPUS=${SERVER_CPUS:-0-$((HALF - 1))}
  CLIENT_CPUS=${CLIENT_CPUS:-$HALF-$((NPROC - 1))}
else
  SERVER_CPUS=${SERVER_CPUS:-}
  CLIENT_CPUS=${CLIENT_CPUS:-}
fi

client() {
  if [[ -n "$CLIENT_CPUS" ]]; then
    taskset -c "$CLIENT_CPUS" "$OHA" "$@"
  else
    "$OHA" "$@"
  fi
}

mkdir -p "$RESULTS_DIR"
cat >"$RESULTS_DIR/config.json" <<EOF
{
  "variants": "${VARIANTS[*]}",
  "endpoints": "${ENDPOINTS[*]}",
  "concurrencies": "${CONCURRENCIES[*]}",
  "reps": $REPS,
  "warmup_seconds": $WARMUP,
  "duration_seconds": $DURATION,
  "server_cpus": "$SERVER_CPUS",
  "client_cpus": "$CLIENT_CPUS"
}
EOF
RUNS_LOG="$RESULTS_DIR/runs.jsonl"
: >"$RUNS_LOG"

total=$((REPS * ${#VARIANTS[@]} * ${#ENDPOINTS[@]} * ${#CONCURRENCIES[@]}))
estimate=$((REPS * ${#VARIANTS[@]} * ${#ENDPOINTS[@]} * (WARMUP + ${#CONCURRENCIES[@]} * DURATION)))
echo "Running $total measurements (~$((estimate / 60)) min). server CPUs: ${SERVER_CPUS:-all}, client CPUs: ${CLIENT_CPUS:-all}"

n=0
for ((rep = 1; rep <= REPS; rep++)); do
  order=()
  for ((i = 0; i < ${#VARIANTS[@]}; i++)); do
    order+=("${VARIANTS[$(((i + rep - 1) % ${#VARIANTS[@]}))]}")
  done
  echo "== rep $rep/$REPS: ${order[*]}"

  position=0
  for variant in "${order[@]}"; do
    position=$((position + 1))
    mkdir -p "$RESULTS_DIR/$variant"
    start_server "$variant" "$RESULTS_DIR/$variant/server-rep$rep.log" "$SERVER_CPUS"

    for endpoint in "${ENDPOINTS[@]}"; do
      url="$BASE_URL/$endpoint"
      client -c 50 -z "${WARMUP}s" --no-tui --output-format json "$url" >/dev/null

      for c in "${CONCURRENCIES[@]}"; do
        n=$((n + 1))
        dir="$RESULTS_DIR/$variant/$endpoint/c$c"
        mkdir -p "$dir"

        python3 "$ROOT/scripts/sample_proc.py" "$SERVER_PID" "$dir/rep$rep.proc.json" &
        sampler=$!
        started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        client -c "$c" -z "${DURATION}s" --no-tui --output-format json "$url" >"$dir/rep$rep.json"
        kill -TERM "$sampler"
        wait "$sampler" || true

        rps=$(python3 -c 'import json,sys; print(round(json.load(open(sys.argv[1]))["summary"]["requestsPerSec"]))' "$dir/rep$rep.json")
        printf '  [%d/%d] %-14s %-20s c=%-4s %8s req/s\n' "$n" "$total" "$variant" "$endpoint" "$c" "$rps"
        printf '{"rep":%d,"position":%d,"variant":"%s","endpoint":"%s","concurrency":%d,"started_at":"%s"}\n' \
          "$rep" "$position" "$variant" "$endpoint" "$c" "$started" >>"$RUNS_LOG"
      done
    done

    stop_server
  done
done
echo "Done. Results in $RESULTS_DIR"
