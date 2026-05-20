#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Redis/Tarantool benchmark scenario runner
# ============================================================
#
# Usage:
#
#   ./scripts/run_benchmarks.sh
#
# Example:
#
#   SCENARIO_GROUP=standard \
#   REDIS_ADDR=127.0.0.1:6379 \
#   TARANTOOL_ADDR=127.0.0.1:3301 \
#   TARANTOOL_USER=app \
#   TARANTOOL_PASSWORD=app \
#   TARANTOOL_NO_DDL=1 \
#   ./scripts/run_benchmarks.sh
#
# Available scenario groups:
#
#   smoke
#   standard
#   scaling
#   read
#   write
#   full
#
# ============================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DBBENCH_BIN="${DBBENCH_BIN:-./benchdb}"

SCENARIO_GROUP="${SCENARIO_GROUP:-standard}"

REDIS_ADDR="${REDIS_ADDR:-127.0.0.1:6379}"
REDIS_USERNAME="${REDIS_USERNAME:-}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"
REDIS_DB="${REDIS_DB:-0}"

TARANTOOL_ADDR="${TARANTOOL_ADDR:-127.0.0.1:3301}"
TARANTOOL_USER="${TARANTOOL_USER:-app}"
TARANTOOL_PASSWORD="${TARANTOOL_PASSWORD:-app_pass}"
TARANTOOL_SPACE="${TARANTOOL_SPACE:-kv}"
TARANTOOL_NO_DDL="${TARANTOOL_NO_DDL:-1}"

RUNS="${RUNS:-3}"
RUN_DELAY="${RUN_DELAY:-1s}"

RESULTS_DIR="${RESULTS_DIR:-results/$(date '+%Y%m%d-%H%M%S')}"

mkdir -p "$RESULTS_DIR"

if [[ ! -x "$DBBENCH_BIN" ]]; then
  echo "Binary not found or not executable: $DBBENCH_BIN"
  echo "Build it first:"
  echo "  go mod tidy"
  echo "  go build -o dbbench ."
  exit 1
fi

TARANTOOL_DDL_FLAG=""
if [[ "$TARANTOOL_NO_DDL" == "1" || "$TARANTOOL_NO_DDL" == "true" || "$TARANTOOL_NO_DDL" == "yes" ]]; then
  TARANTOOL_DDL_FLAG="--tarantool-no-ddl"
fi

COMMON_FLAGS=(
  "--redis-addr" "$REDIS_ADDR"
  "--redis-db" "$REDIS_DB"

  "--tarantool-addr" "$TARANTOOL_ADDR"
  "--tarantool-user" "$TARANTOOL_USER"
  "--tarantool-password" "$TARANTOOL_PASSWORD"
  "--tarantool-space" "$TARANTOOL_SPACE"

  "--runs" "$RUNS"
  "--run-delay" "$RUN_DELAY"
  "--summary"
  "--file-format" "csv"
)

if [[ -n "$REDIS_USERNAME" ]]; then
  COMMON_FLAGS+=("--redis-username" "$REDIS_USERNAME")
fi

if [[ -n "$REDIS_PASSWORD" ]]; then
  COMMON_FLAGS+=("--redis-password" "$REDIS_PASSWORD")
fi

if [[ -n "$TARANTOOL_DDL_FLAG" ]]; then
  COMMON_FLAGS+=("$TARANTOOL_DDL_FLAG")
fi

write_manifest() {
  cat > "$RESULTS_DIR/manifest.txt" <<EOF
Redis/Tarantool benchmark run

Started at:        $(date '+%Y-%m-%d %H:%M:%S')
Scenario group:    $SCENARIO_GROUP

Benchmark binary:  $DBBENCH_BIN

Redis address:     $REDIS_ADDR
Redis username:    ${REDIS_USERNAME:-<empty>}
Redis DB:          $REDIS_DB

Tarantool address: $TARANTOOL_ADDR
Tarantool user:    $TARANTOOL_USER
Tarantool space:   $TARANTOOL_SPACE
Tarantool no DDL:  $TARANTOOL_NO_DDL

Runs:              $RUNS
Run delay:         $RUN_DELAY

Results dir:       $RESULTS_DIR
EOF
}

run_scenario() {
  local name="$1"
  shift

  local output_file="$RESULTS_DIR/${name}.csv"
  local log_file="$RESULTS_DIR/${name}.log"

  echo
  echo "============================================================"
  echo "Running scenario: $name"
  echo "Output: $output_file"
  echo "Log:    $log_file"
  echo "============================================================"

  {
    echo "Scenario: $name"
    echo "Started:  $(date '+%Y-%m-%d %H:%M:%S')"
    echo
    echo "Command:"
    printf '  %q' "$DBBENCH_BIN" bench "${COMMON_FLAGS[@]}" "--output-file" "$output_file" "$@"
    echo
    echo
  } > "$log_file"

  "$DBBENCH_BIN" bench \
    "${COMMON_FLAGS[@]}" \
    "--output-file" "$output_file" \
    "$@" 2>&1 | tee -a "$log_file"

  {
    echo
    echo "Finished: $(date '+%Y-%m-%d %H:%M:%S')"
  } >> "$log_file"
}

run_smoke() {
  run_scenario "00_smoke_all_set_get" \
    --target all \
    --operation all \
    --requests 1000 \
    --concurrency 8 \
    --value-size 128 \
    --runs 1 \
    --tarantool-no-ddl
}

run_standard() {
  run_scenario "01_baseline_all_set_get" \
    --target all \
    --operation all \
    --requests 100000 \
    --concurrency 64 \
    --value-size 128 \
    --tarantool-no-ddl

  run_scenario "02_concurrency_scaling" \
    --target all \
    --operation all \
    --requests 100000 \
    --concurrency-list 1,8,16,32,64 \
    --value-size 128

  run_scenario "03_value_size_scaling" \
    --target all \
    --operation all \
    --requests 100000 \
    --concurrency 64 \
    --value-size-list 64,128,512,1024,4096
}

run_scaling() {
  run_scenario "10_concurrency_scaling_extended" \
    --target all \
    --operation all \
    --requests 100000 \
    --concurrency-list 1,2,4,8,16,32,64,128 \
    --value-size 128

  run_scenario "11_requests_scaling" \
    --target all \
    --operation all \
    --requests-list 10000,50000,100000,250000,500000 \
    --concurrency 64 \
    --value-size 128

  run_scenario "12_value_size_scaling_extended" \
    --target all \
    --operation all \
    --requests 100000 \
    --concurrency 64 \
    --value-size-list 16,64,128,512,1024,4096,16384
}

run_read() {
  run_scenario "20_read_baseline_get" \
    --target all \
    --operation get \
    --requests 100000 \
    --concurrency 64 \
    --value-size 128

  run_scenario "21_read_concurrency_scaling" \
    --target all \
    --operation get \
    --requests 100000 \
    --concurrency-list 1,8,16,32,64,128 \
    --value-size 128

  run_scenario "22_read_value_size_scaling" \
    --target all \
    --operation get \
    --requests 100000 \
    --concurrency 64 \
    --value-size-list 64,128,512,1024,4096
}

run_write() {
  run_scenario "30_write_baseline_set" \
    --target all \
    --operation set \
    --requests 100000 \
    --concurrency 64 \
    --value-size 128

  run_scenario "31_write_concurrency_scaling" \
    --target all \
    --operation set \
    --requests 100000 \
    --concurrency-list 1,8,16,32,64,128 \
    --value-size 128

  run_scenario "32_write_value_size_scaling" \
    --target all \
    --operation set \
    --requests 100000 \
    --concurrency 64 \
    --value-size-list 64,128,512,1024,4096
}

write_manifest

echo "Results directory: $RESULTS_DIR"
echo "Scenario group:    $SCENARIO_GROUP"

case "$SCENARIO_GROUP" in
  smoke)
    run_smoke
    ;;

  standard)
    run_smoke
    run_standard
    ;;

  scaling)
    run_smoke
    run_scaling
    ;;

  read)
    run_smoke
    run_read
    ;;

  write)
    run_smoke
    run_write
    ;;

  full)
    run_smoke
    run_standard
    run_scaling
    run_read
    run_write
    ;;

  *)
    echo "Unknown SCENARIO_GROUP: $SCENARIO_GROUP"
    echo "Allowed values: smoke, standard, scaling, read, write, full"
    exit 1
    ;;
esac

echo
echo "All scenarios finished."
echo "Results saved to: $RESULTS_DIR"