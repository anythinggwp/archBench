#!/usr/bin/env bash
set -euo pipefail

# Runner for Redis/Tarantool/YDB/PostgreSQL benchmark scenarios.
# It executes scenarios sequentially and saves one CSV plus one log per scenario.
#
# Usage examples:
#   ./scripts/run_benchmarks.sh
#   SCENARIO_GROUP=smoke ./scripts/run_benchmarks.sh
#   SCENARIO_GROUP=full REDIS_ADDR=redis-node:6379 TARANTOOL_ADDR=tarantool-node:3301 ./scripts/run_benchmarks.sh
#
# Useful environment variables:
#   DBBENCH_BIN           path to benchmark binary; default: ./dbbench
#   RESULTS_DIR           output directory; default: results/<timestamp>
#   SCENARIO_GROUP        smoke | standard | full | read | write | scaling; default: standard
#   TARGET                redis | tarantool | ydb | postgres | all or comma-list; default: all
#   REDIS_ADDR            Redis address; default: 127.0.0.1:6379
#   REDIS_PASSWORD        Redis password; default: empty
#   REDIS_DB              Redis DB number; default: 0
#   TARANTOOL_ADDR        Tarantool address; default: 127.0.0.1:3301
#   TARANTOOL_USER        Tarantool user; default: app
#   TARANTOOL_PASSWORD    Tarantool password; default: empty
#   TARANTOOL_SPACE       Tarantool space; default: kv
#   TARANTOOL_NO_DDL      1 to add --tarantool-no-ddl; default: 1
#   YDB_CONNECTION_STRING  YDB connection string; default: grpc://localhost:2136/local
#   YDB_TABLE              YDB table; default: kv
#   YDB_NO_DDL             1 to add --ydb-no-ddl; default: 0
#   YDB_MAX_OPEN_CONNS     YDB max open connections; default: 0 = use concurrency
#   POSTGRES_CONN          PostgreSQL connection string; default: postgres://postgres:postgres@127.0.0.1:5432/postgres?sslmode=disable
#   POSTGRES_TABLE         PostgreSQL table; default: kv
#   POSTGRES_NO_DDL        1 to add --postgres-no-ddl; default: 0
#   POSTGRES_MAX_CONNS     PostgreSQL pool max conns; default: 0 = use concurrency
#   RUN_DELAY             pause between generated benchmark runs; default: 1s
#   TIMEOUT               connection/request timeout; default: 5s

DBBENCH_BIN="${DBBENCH_BIN:-./dbbench}"
RESULTS_DIR="${RESULTS_DIR:-results/$(date +%Y%m%d-%H%M%S)}"
SCENARIO_GROUP="${SCENARIO_GROUP:-standard}"
TARGET="${TARGET:-all}"

REDIS_ADDR="${REDIS_ADDR:-127.0.0.1:6379}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"
REDIS_DB="${REDIS_DB:-0}"

TARANTOOL_ADDR="${TARANTOOL_ADDR:-127.0.0.1:3301}"
TARANTOOL_USER="${TARANTOOL_USER:-app}"
TARANTOOL_PASSWORD="${TARANTOOL_PASSWORD:-app_pass}"
TARANTOOL_SPACE="${TARANTOOL_SPACE:-kv}"
TARANTOOL_NO_DDL="${TARANTOOL_NO_DDL:-1}"

YDB_CONNECTION_STRING="${YDB_CONNECTION_STRING:-grpc://localhost:2136/local}"
YDB_TABLE="${YDB_TABLE:-kv}"
YDB_NO_DDL="${YDB_NO_DDL:-0}"
YDB_MAX_OPEN_CONNS="${YDB_MAX_OPEN_CONNS:-0}"

POSTGRES_CONN="${POSTGRES_CONN:-postgres://postgres:postgres@127.0.0.1:5432/postgres?sslmode=disable}"
POSTGRES_TABLE="${POSTGRES_TABLE:-kv}"
POSTGRES_NO_DDL="${POSTGRES_NO_DDL:-0}"
POSTGRES_MAX_CONNS="${POSTGRES_MAX_CONNS:-0}"
POSTGRES_USER="${POSTGRES_USER:-bench}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-bench_password}"

RUN_DELAY="${RUN_DELAY:-1s}"
TIMEOUT="${TIMEOUT:-5s}"
CLEANUP_BETWEEN_RUNS="${CLEANUP_BETWEEN_RUNS:-1}"

mkdir -p "$RESULTS_DIR"

if [[ ! -x "$DBBENCH_BIN" ]]; then
  echo "Binary '$DBBENCH_BIN' was not found or is not executable." >&2
  echo "Build it first:" >&2
  echo "  go build -o dbbench ." >&2
  exit 1
fi

common_flags=(
  --target "$TARGET"
  --summary
  --run-delay "$RUN_DELAY"
  --timeout "$TIMEOUT"
  --redis-addr "$REDIS_ADDR"
  --redis-password "$REDIS_PASSWORD"
  --redis-db "$REDIS_DB"
  --tarantool-addr "$TARANTOOL_ADDR"
  --tarantool-user "$TARANTOOL_USER"
  --tarantool-password "$TARANTOOL_PASSWORD"
  --tarantool-space "$TARANTOOL_SPACE"
  --ydb-connection-string "$YDB_CONNECTION_STRING"
  --ydb-table "$YDB_TABLE"
  --ydb-max-open-conns "$YDB_MAX_OPEN_CONNS"
  --postgres-conn "$POSTGRES_CONN"
  --postgres-table "$POSTGRES_TABLE"
  --postgres-max-conns "$POSTGRES_MAX_CONNS"
)

if [[ "$TARANTOOL_NO_DDL" == "1" || "$TARANTOOL_NO_DDL" == "true" || "$TARANTOOL_NO_DDL" == "yes" ]]; then
  common_flags+=(--tarantool-no-ddl)
fi

if [[ "$YDB_NO_DDL" == "1" || "$YDB_NO_DDL" == "true" || "$YDB_NO_DDL" == "yes" ]]; then
  common_flags+=(--ydb-no-ddl)
fi

if [[ "$POSTGRES_NO_DDL" == "1" || "$POSTGRES_NO_DDL" == "true" || "$POSTGRES_NO_DDL" == "yes" ]]; then
  common_flags+=(--postgres-no-ddl)
fi

if [[ "$CLEANUP_BETWEEN_RUNS" == "1" || "$CLEANUP_BETWEEN_RUNS" == "true" || "$CLEANUP_BETWEEN_RUNS" == "yes" ]]; then
  common_flags+=(--cleanup-between-runs)
fi

run_scenario() {
  local name="$1"
  shift

  local output_file="$RESULTS_DIR/${name}.csv"
  local log_file="$RESULTS_DIR/${name}.log"

  echo
  echo "================================================================"
  echo "Scenario: $name"
  echo "CSV:      $output_file"
  echo "Log:      $log_file"
  echo "================================================================"

  "$DBBENCH_BIN" bench \
    "${common_flags[@]}" \
    --output-file "$output_file" \
    --file-format csv \
    "$@" \
    2>&1 | tee "$log_file"
}

write_manifest() {
  cat > "$RESULTS_DIR/manifest.txt" <<EOF_MANIFEST
created_at=$(date --iso-8601=seconds 2>/dev/null || date)
scenario_group=$SCENARIO_GROUP
target=$TARGET
redis_addr=$REDIS_ADDR
redis_db=$REDIS_DB
tarantool_addr=$TARANTOOL_ADDR
tarantool_user=$TARANTOOL_USER
tarantool_space=$TARANTOOL_SPACE
tarantool_no_ddl=$TARANTOOL_NO_DDL
ydb_connection_string=$YDB_CONNECTION_STRING
ydb_table=$YDB_TABLE
ydb_no_ddl=$YDB_NO_DDL
ydb_max_open_conns=$YDB_MAX_OPEN_CONNS
postgres_conn=$POSTGRES_CONN
postgres_table=$POSTGRES_TABLE
postgres_no_ddl=$POSTGRES_NO_DDL
postgres_max_conns=$POSTGRES_MAX_CONNS
run_delay=$RUN_DELAY
timeout=$TIMEOUT
binary=$DBBENCH_BIN
cleanup_between_runs=$CLEANUP_BETWEEN_RUNS
EOF_MANIFEST
}

run_smoke() {
  run_scenario "00_smoke_all_set_get" \
    --operation all \
    --requests 1000 \
    --concurrency 4 \
    --value-size 128 \
    --runs 1
}

run_standard() {
  run_scenario "01_baseline_all_set_get" \
    --operation all \
    --requests 100000 \
    --concurrency 32 \
    --value-size 128 \
    --runs 5

  run_scenario "02_concurrency_scaling" \
    --operation all \
    --requests 100000 \
    --concurrency-list 1,2,4,8,16,32,64,128,256,512,1024 \
    --value-size 128 \
    --runs 3

  run_scenario "03_value_size_scaling" \
    --operation all \
    --requests 50000 \
    --concurrency 32 \
    --value-size-list 32,128,512,1024,4096 \
    --runs 3
}

run_scaling() {
  run_scenario "02_concurrency_scaling" \
    --operation all \
    --requests 100000 \
    --concurrency-list 1,2,4,8,16,32,64,128 \
    --value-size 128 \
    --runs 3

  run_scenario "03_value_size_scaling" \
    --operation all \
    --requests 50000 \
    --concurrency 32 \
    --value-size-list 32,128,512,1024,4096,8192 \
    --runs 3

  run_scenario "04_request_count_scaling" \
    --operation all \
    --requests-list 10000,50000,100000,250000 \
    --concurrency 32 \
    --value-size 128 \
    --runs 3
}

run_read() {
  run_scenario "05_read_get_concurrency" \
    --operation get \
    --requests 100000 \
    --concurrency-list 1,2,4,8,16,32,64,128 \
    --value-size 128 \
    --runs 5

  run_scenario "06_read_get_value_size" \
    --operation get \
    --requests 50000 \
    --concurrency 32 \
    --value-size-list 32,128,512,1024,4096 \
    --runs 3
}

run_write() {
  run_scenario "07_write_set_concurrency" \
    --operation set \
    --requests 100000 \
    --concurrency-list 1,2,4,8,16,32,64,128 \
    --value-size 128 \
    --runs 5

  run_scenario "08_write_set_value_size" \
    --operation set \
    --requests 50000 \
    --concurrency 32 \
    --value-size-list 32,128,512,1024,4096 \
    --runs 3
}

run_real_size(){

  run_scenario "02_concurrency_scaling_all" \
    --operation all \
    --requests 100000 \
    --concurrency-list 1,2,4,8,16,32,64,128 \
    --value-size 17408 \
    --runs 3
}

run_full() {
  run_smoke
  run_standard
  run_scaling
  run_read
  run_write
}

write_manifest

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
  real)
    run_smoke
    run_real_size
    ;;
  full)
    run_full
    ;;
  *)
    echo "Unknown SCENARIO_GROUP='$SCENARIO_GROUP'. Use: smoke, standard, scaling, read, write, full." >&2
    exit 1
    ;;
esac

cat <<EOF_DONE

Done.
Results directory:
  $RESULTS_DIR

Files:
  manifest.txt                 run configuration
  *.csv                        raw rows + summary rows
  *.log                        terminal output per scenario

Tip: summary rows are in CSV records where record_type=summary.
EOF_DONE
