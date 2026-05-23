#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Redis / Tarantool / YDB / PostgreSQL benchmark scenario runner
# ============================================================
#
# Examples:
#
#   ./scripts/run_benchmarks.sh
#
#   TARGET=redis \
#   REDIS_MODE=cluster \
#   REDIS_CLUSTER_ADDRS=127.0.0.1:7001,127.0.0.1:7002,127.0.0.1:7003,127.0.0.1:7004 \
#   SCENARIO_GROUP=scaling \
#   ./scripts/run_benchmarks.sh
#
# Scenario groups:
#
#   smoke
#   standard
#   scaling
#   read
#   write
#   full
#
# Main variables:
#
#   DBBENCH_BIN              path to benchmark binary; default: ./dbbench
#   SCENARIO_GROUP           smoke|standard|scaling|read|write|full; default: standard
#   TARGET                   redis|tarantool|ydb|postgres|all; default: all
#   RUNS                     repeated runs per test config; default: 3
#   RUN_DELAY                delay between runs; default: 1s
#   CLEANUP_BETWEEN_RUNS     1 to add --cleanup-between-runs; default: 0
#
# Redis variables:
#
#   REDIS_MODE               standalone|cluster; default: standalone
#   REDIS_ADDR               standalone Redis address; default: 127.0.0.1:6379
#   REDIS_CLUSTER_ADDRS      comma-separated Redis Cluster addresses
#   REDIS_PASSWORD           optional Redis password
#   REDIS_DB                 Redis DB for standalone mode; default: 0
#
# Tarantool variables:
#
#   TARANTOOL_ADDR           default: 127.0.0.1:3301
#   TARANTOOL_ADDRS          comma-separated router addresses; overrides TARANTOOL_ADDR when set
#   TARANTOOL_USER           default: app
#   TARANTOOL_PASSWORD       default: app_pass
#   TARANTOOL_SPACE          default: kv
#   TARANTOOL_MODE           direct, call, vshard or crud; default: direct
#   TARANTOOL_MAX_CONNS      client connections; 0 means benchmark concurrency
#   TARANTOOL_NO_DDL         1 to add --tarantool-no-ddl; default: 1
#
# YDB variables:
#
#   YDB_CONNECTION_STRING    default: grpc://localhost:2136/local
#   YDB_TABLE                default: kv
#   YDB_NO_DDL               1 to add --ydb-no-ddl if supported by binary; default: 0
#
# PostgreSQL variables:
#
#   POSTGRES_CONN            default: postgres://postgres:postgres@127.0.0.1:5432/postgres?sslmode=disable
#   POSTGRES_TABLE           default: kv
#   POSTGRES_NO_DDL          1 to add --postgres-no-ddl if supported by binary; default: 0
#
# ============================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DBBENCH_BIN="${DBBENCH_BIN:-./dbbench}"
SCENARIO_GROUP="${SCENARIO_GROUP:-standard}"
TARGET="${TARGET:-all}"

RUNS="${RUNS:-3}"
RUN_DELAY="${RUN_DELAY:-1s}"
CLEANUP_BETWEEN_RUNS="${CLEANUP_BETWEEN_RUNS:-1}"

RESULTS_DIR="${RESULTS_DIR:-results/$(date '+%Y%m%d-%H%M%S')}"

REDIS_MODE="${REDIS_MODE:-standalone}"
REDIS_ADDR="${REDIS_ADDR:-127.0.0.1:6379}"
REDIS_CLUSTER_ADDRS="${REDIS_CLUSTER_ADDRS:-127.0.0.1:7001,127.0.0.1:7002,127.0.0.1:7003}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"
REDIS_DB="${REDIS_DB:-0}"

TARANTOOL_ADDR="${TARANTOOL_ADDR:-127.0.0.1:3301}"
TARANTOOL_ADDRS="${TARANTOOL_ADDRS:-}"
TARANTOOL_USER="${TARANTOOL_USER:-app}"
TARANTOOL_PASSWORD="${TARANTOOL_PASSWORD:-app_pass}"
TARANTOOL_SPACE="${TARANTOOL_SPACE:-kv}"
TARANTOOL_MODE="${TARANTOOL_MODE:-direct}"
TARANTOOL_MAX_CONNS="${TARANTOOL_MAX_CONNS:-0}"
TARANTOOL_NO_DDL="${TARANTOOL_NO_DDL:-1}"

YDB_CONNECTION_STRING="${YDB_CONNECTION_STRING:-grpc://localhost:2136/local}"
YDB_TABLE="${YDB_TABLE:-kv}"
YDB_NO_DDL="${YDB_NO_DDL:-0}"

POSTGRES_CONN="${POSTGRES_CONN:-postgres://postgres:postgres@127.0.0.1:5432/postgres?sslmode=disable}"
POSTGRES_TABLE="${POSTGRES_TABLE:-kv}"
POSTGRES_NO_DDL="${POSTGRES_NO_DDL:-0}"

mkdir -p "$RESULTS_DIR"

is_true() {
  case "${1:-}" in
    1|true|yes|on|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

require_binary() {
  if [[ ! -x "$DBBENCH_BIN" ]]; then
    echo "Benchmark binary not found or not executable: $DBBENCH_BIN" >&2
    echo "Build it first:" >&2
    echo "  go mod tidy" >&2
    echo "  go build -o dbbench ." >&2
    exit 1
  fi
}

normalize_values() {
  REDIS_MODE="$(echo "$REDIS_MODE" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
  TARGET="$(echo "$TARGET" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
  SCENARIO_GROUP="$(echo "$SCENARIO_GROUP" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"

  case "$REDIS_MODE" in
    standalone|single|node)
      REDIS_MODE="standalone"
      ;;
    cluster|redis-cluster)
      REDIS_MODE="cluster"
      ;;
    *)
      echo "Unknown REDIS_MODE: $REDIS_MODE" >&2
      echo "Allowed values: standalone, cluster" >&2
      exit 1
      ;;
  esac
}

build_common_flags() {
  COMMON_FLAGS=(
    --redis-mode "$REDIS_MODE"
    --redis-addr "$REDIS_ADDR"
    --redis-cluster-addrs "$REDIS_CLUSTER_ADDRS"
    --redis-db "$REDIS_DB"

    --tarantool-addr "$TARANTOOL_ADDR"
    --tarantool-user "$TARANTOOL_USER"
    --tarantool-password "$TARANTOOL_PASSWORD"
    --tarantool-space "$TARANTOOL_SPACE"
    --tarantool-mode "$TARANTOOL_MODE"
    --tarantool-max-conns "$TARANTOOL_MAX_CONNS"

    --ydb-connection-string "$YDB_CONNECTION_STRING"
    --ydb-table "$YDB_TABLE"

    --postgres-conn "$POSTGRES_CONN"
    --postgres-table "$POSTGRES_TABLE"

    --runs "$RUNS"
    --run-delay "$RUN_DELAY"
    --summary
    --file-format csv
  )

  if [[ -n "$REDIS_PASSWORD" ]]; then
    COMMON_FLAGS+=(--redis-password "$REDIS_PASSWORD")
  fi

  if [[ -n "$TARANTOOL_ADDRS" ]]; then
    COMMON_FLAGS+=(--tarantool-addrs "$TARANTOOL_ADDRS")
  fi

  if is_true "$TARANTOOL_NO_DDL"; then
    COMMON_FLAGS+=(--tarantool-no-ddl)
  fi

  # These flags are optional and depend on your current dbbench version.
  # Enable only if your binary supports them.
  if is_true "$YDB_NO_DDL"; then
    COMMON_FLAGS+=(--ydb-no-ddl)
  fi

  if is_true "$POSTGRES_NO_DDL"; then
    COMMON_FLAGS+=(--postgres-no-ddl)
  fi

  if is_true "$CLEANUP_BETWEEN_RUNS"; then
    COMMON_FLAGS+=(--cleanup-between-runs)
  fi
}

write_manifest() {
  cat > "$RESULTS_DIR/manifest.txt" <<EOF_MANIFEST
Benchmark run

started_at=$(date '+%Y-%m-%d %H:%M:%S')
root_dir=$ROOT_DIR
benchmark_binary=$DBBENCH_BIN
scenario_group=$SCENARIO_GROUP
target=$TARGET
runs=$RUNS
run_delay=$RUN_DELAY
cleanup_between_runs=$CLEANUP_BETWEEN_RUNS

redis_mode=$REDIS_MODE
redis_addr=$REDIS_ADDR
redis_cluster_addrs=$REDIS_CLUSTER_ADDRS
redis_db=$REDIS_DB
redis_password_set=$([[ -n "$REDIS_PASSWORD" ]] && echo yes || echo no)

tarantool_addr=$TARANTOOL_ADDR
tarantool_addrs=$TARANTOOL_ADDRS
tarantool_user=$TARANTOOL_USER
tarantool_space=$TARANTOOL_SPACE
tarantool_mode=$TARANTOOL_MODE
tarantool_max_conns=$TARANTOOL_MAX_CONNS
tarantool_no_ddl=$TARANTOOL_NO_DDL

ydb_connection_string=$YDB_CONNECTION_STRING
ydb_table=$YDB_TABLE
ydb_no_ddl=$YDB_NO_DDL

postgres_conn=$POSTGRES_CONN
postgres_table=$POSTGRES_TABLE
postgres_no_ddl=$POSTGRES_NO_DDL

results_dir=$RESULTS_DIR
EOF_MANIFEST
}

run_scenario() {
  local name="$1"
  shift

  local output_file="$RESULTS_DIR/${name}.csv"
  local log_file="$RESULTS_DIR/${name}.log"

  echo
  echo "============================================================"
  echo "Running scenario: $name"
  echo "Target:          $TARGET"
  echo "Redis mode:      $REDIS_MODE"
  echo "Tarantool addrs: ${TARANTOOL_ADDRS:-$TARANTOOL_ADDR}"
  echo "Output:          $output_file"
  echo "Log:             $log_file"
  echo "============================================================"

  {
    echo "Scenario: $name"
    echo "Started:  $(date '+%Y-%m-%d %H:%M:%S')"
    echo
    echo "Command:"
    printf '  %q' "$DBBENCH_BIN" bench "${COMMON_FLAGS[@]}" --output-file "$output_file" "$@"
    echo
    echo
  } > "$log_file"

  "$DBBENCH_BIN" bench \
    "${COMMON_FLAGS[@]}" \
    --output-file "$output_file" \
    "$@" 2>&1 | tee -a "$log_file"

  {
    echo
    echo "Finished: $(date '+%Y-%m-%d %H:%M:%S')"
  } >> "$log_file"
}

run_smoke() {
  run_scenario "00_smoke_all_set_get" \
    --target "$TARGET" \
    --operation all \
    --requests 1000 \
    --concurrency 8 \
    --value-size 128 \
    --runs 1
}

run_standard() {
  run_scenario "01_baseline_all_set_get" \
    --target "$TARGET" \
    --operation all \
    --requests 100000 \
    --concurrency 64 \
    --value-size 128

  run_scenario "02_concurrency_scaling" \
    --target "$TARGET" \
    --operation all \
    --requests 100000 \
    --concurrency-list 1,2,4,8,16,32,64,128,256 \
    --value-size 128

  run_scenario "03_value_size_scaling" \
    --target "$TARGET" \
    --operation all \
    --requests 100000 \
    --concurrency 64 \
    --value-size-list 16,64,128,512,1024
}

run_scaling() {
  run_scenario "10_concurrency_scaling_extended" \
    --target "$TARGET" \
    --operation all \
    --requests 100000 \
    --concurrency-list 1,2,4,8,16,32,64,128,256,512,1024 \
    --value-size 128

  run_scenario "11_requests_scaling" \
    --target "$TARGET" \
    --operation all \
    --requests-list 10000,50000,100000,250000,500000 \
    --concurrency 64 \
    --value-size 128

  run_scenario "12_value_size_scaling_extended" \
    --target "$TARGET" \
    --operation all \
    --requests 100000 \
    --concurrency 64 \
    --value-size-list 16,64,128,512,1024,4096,16384
}

run_read() {
  run_scenario "20_read_baseline_get" \
    --target "$TARGET" \
    --operation get \
    --requests 100000 \
    --concurrency 64 \
    --value-size 128

  run_scenario "21_read_concurrency_scaling" \
    --target "$TARGET" \
    --operation get \
    --requests 100000 \
    --concurrency-list 1,2,4,8,16,32,64,128,256,512,1024 \
    --value-size 128

  run_scenario "22_read_value_size_scaling" \
    --target "$TARGET" \
    --operation get \
    --requests 100000 \
    --concurrency 64 \
    --value-size-list 64,128,512,1024,4096
}

run_write() {
  run_scenario "30_write_baseline_set" \
    --target "$TARGET" \
    --operation set \
    --requests 100000 \
    --concurrency 64 \
    --value-size 128

  run_scenario "31_write_concurrency_scaling" \
    --target "$TARGET" \
    --operation set \
    --requests 100000 \
    --concurrency-list 1,2,4,8,16,32,64,128,256,512,1024 \
    --value-size 128

  run_scenario "32_write_value_size_scaling" \
    --target "$TARGET" \
    --operation set \
    --requests 100000 \
    --concurrency 64 \
    --value-size-list 64,128,512,1024,4096
}

main() {
  normalize_values
  require_binary
  build_common_flags
  write_manifest

  echo "Results directory: $RESULTS_DIR"
  echo "Scenario group:    $SCENARIO_GROUP"
  echo "Target:            $TARGET"
  echo "Redis mode:        $REDIS_MODE"
  echo "Tarantool addrs:   ${TARANTOOL_ADDRS:-$TARANTOOL_ADDR}"

  if [[ "$REDIS_MODE" == "cluster" ]]; then
    echo "Redis cluster:     $REDIS_CLUSTER_ADDRS"
  fi

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
      echo "Unknown SCENARIO_GROUP: $SCENARIO_GROUP" >&2
      echo "Allowed values: smoke, standard, scaling, read, write, full" >&2
      exit 1
      ;;
  esac

  echo
  echo "All scenarios finished."
  echo "Results saved to: $RESULTS_DIR"
}

main "$@"
