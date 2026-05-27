#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-deploy}"

PROJECT_DIR="${PROJECT_DIR:-postgres-citus-stack}"
NETWORK_NAME="${NETWORK_NAME:-db-net}"

CITUS_IMAGE="${CITUS_IMAGE:-citusdata/citus:12.1}"
CITUS_COORDINATOR_CONTAINER="${CITUS_COORDINATOR_CONTAINER:-citus-coordinator}"
CITUS_WORKERS="${CITUS_WORKERS:-2}"
CITUS_PORT="${CITUS_PORT:-5433}"
CITUS_SHARD_COUNT="${CITUS_SHARD_COUNT:-32}"

POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"
POSTGRES_TABLE="${POSTGRES_TABLE:-kv}"
POSTGRES_MAX_CONNECTIONS="${POSTGRES_MAX_CONNECTIONS:-1000}"
POSTGRES_CPU_LIMIT="${POSTGRES_CPU_LIMIT:-0.5}"

CONTAINER_MEMORY_LIMIT="${CONTAINER_MEMORY_LIMIT:-1G}"
DISK_LIMIT_DEVICE="${DISK_LIMIT_DEVICE:-/dev/sda}"
DISK_READ_BPS="${DISK_READ_BPS:-50mb}"
DISK_WRITE_BPS="${DISK_WRITE_BPS:-40mb}"

log() {
    echo
    echo "==> $*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

compose() {
    docker compose -f "$PROJECT_DIR/docker-compose.yml" "$@"
}

down_existing() {
    if [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then
        log "Stopping old PostgreSQL Citus stack"
        compose down -v --remove-orphans 2>/dev/null || true
    fi

    docker rm -f "$CITUS_COORDINATOR_CONTAINER" 2>/dev/null || true

    local worker
    for worker in $(seq 1 "$CITUS_WORKERS" 2>/dev/null || echo 1); do
        docker rm -f "citus-worker-${worker}" 2>/dev/null || true
    done

    local project_name
    project_name="$(basename "$PROJECT_DIR")"

    docker volume rm -f "${project_name}_citus-coordinator-data" 2>/dev/null || true
    docker volume rm -f "benchdb_citus-coordinator-data" 2>/dev/null || true

    for worker in $(seq 1 "$CITUS_WORKERS" 2>/dev/null || echo 1); do
        docker volume rm -f "${project_name}_citus-worker-${worker}-data" 2>/dev/null || true
        docker volume rm -f "benchdb_citus-worker-${worker}-data" 2>/dev/null || true
    done
}

validate() {
    case "$CITUS_WORKERS" in
        ''|*[!0-9]*)
            die "CITUS_WORKERS must be a positive integer, got: $CITUS_WORKERS"
            ;;
    esac

    if ((CITUS_WORKERS < 1)); then
        die "CITUS_WORKERS must be greater than zero, got: $CITUS_WORKERS"
    fi

    case "$CITUS_SHARD_COUNT" in
        ''|*[!0-9]*)
            die "CITUS_SHARD_COUNT must be a positive integer, got: $CITUS_SHARD_COUNT"
            ;;
    esac

    if ((CITUS_SHARD_COUNT < CITUS_WORKERS)); then
        die "CITUS_SHARD_COUNT must be >= CITUS_WORKERS, got shards=$CITUS_SHARD_COUNT workers=$CITUS_WORKERS"
    fi
}

append_limits() {
    cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
    restart: unless-stopped
    mem_limit: ${CONTAINER_MEMORY_LIMIT}
    blkio_config:
      device_read_bps:
        - path: ${DISK_LIMIT_DEVICE}
          rate: ${DISK_READ_BPS}
      device_write_bps:
        - path: ${DISK_LIMIT_DEVICE}
          rate: ${DISK_WRITE_BPS}
    deploy:
      resources:
        limits:
          cpus: "${POSTGRES_CPU_LIMIT}"
          memory: ${CONTAINER_MEMORY_LIMIT}

EOF
}

prepare_files() {
    validate

    log "Preparing PostgreSQL Citus files in $PROJECT_DIR"
    rm -rf "$PROJECT_DIR"
    mkdir -p "$PROJECT_DIR"

    cat > "$PROJECT_DIR/docker-compose.yml" <<EOF
services:
  citus-coordinator:
    image: ${CITUS_IMAGE}
    container_name: ${CITUS_COORDINATOR_CONTAINER}
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    command:
      - postgres
      - "-c"
      - "max_connections=${POSTGRES_MAX_CONNECTIONS}"
    ports:
      - "${CITUS_PORT}:5432"
    volumes:
      - citus-coordinator-data:/var/lib/postgresql/data
    networks:
      - ${NETWORK_NAME}
EOF
    append_limits

    local worker
    for worker in $(seq 1 "$CITUS_WORKERS"); do
        cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
  citus-worker-${worker}:
    image: ${CITUS_IMAGE}
    container_name: citus-worker-${worker}
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    command:
      - postgres
      - "-c"
      - "max_connections=${POSTGRES_MAX_CONNECTIONS}"
    volumes:
      - citus-worker-${worker}-data:/var/lib/postgresql/data
    networks:
      - ${NETWORK_NAME}
EOF
        append_limits
    done

    cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
networks:
  ${NETWORK_NAME}:
    driver: bridge

volumes:
  citus-coordinator-data:
EOF

    for worker in $(seq 1 "$CITUS_WORKERS"); do
        cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
  citus-worker-${worker}-data:
EOF
    done
}

up() {
    log "Starting PostgreSQL Citus"
    compose up -d --force-recreate
}

wait_postgres() {
    local container="$1"
    local database="${2:-$POSTGRES_DB}"

    for _ in {1..90}; do
        if docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$container" \
            psql -U "$POSTGRES_USER" -d "$database" -Atc "SELECT 1;" 2>/dev/null | grep -qx 1; then
            return 0
        fi
        sleep 1
    done

    return 1
}

psql_exec() {
    local container="$1"
    local sql="$2"

    psql_exec_db "$container" "$POSTGRES_DB" "$sql"
}

psql_exec_db() {
    local container="$1"
    local database="$2"
    local sql="$3"
    local output

    for _ in {1..60}; do
        if output="$(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$container" \
            psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$database" -c "$sql" 2>&1)"; then
            echo "$output"
            return 0
        fi

        if echo "$output" | grep -Eiq 'starting up|shutting down|the database system is not yet accepting connections|could not connect'; then
            sleep 2
            continue
        fi

        echo "$output" >&2
        return 1
    done

    echo "$output" >&2
    return 1
}

sql_literal() {
    local value="$1"
    value="${value//\'/\'\'}"
    printf "'%s'" "$value"
}

ensure_database() {
    local container="$1"

    wait_postgres "$container" "postgres" || die "$container postgres database did not become ready"

    if docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$container" \
        psql -U "$POSTGRES_USER" -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname = $(sql_literal "$POSTGRES_DB");" 2>/dev/null | grep -qx 1; then
        return 0
    fi

    psql_exec_db "$container" "postgres" "CREATE DATABASE \"${POSTGRES_DB}\";"
}

ensure_citus_extension() {
    local container="$1"

    ensure_database "$container"
    wait_postgres "$container" || die "$container did not become ready"

    if docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$container" \
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT 1 FROM pg_extension WHERE extname = 'citus';" 2>/dev/null | grep -qx 1; then
        return 0
    fi

    if docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$container" \
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT 1 FROM pg_extension WHERE extname = 'citus_columnar';" 2>/dev/null | grep -qx 1; then
        log "Dropping orphan citus_columnar extension in $container"
        psql_exec "$container" "DROP EXTENSION citus_columnar CASCADE;"
    fi

    psql_exec "$container" "CREATE EXTENSION IF NOT EXISTS citus;"
}

configure_citus_nodes() {
    local worker

    ensure_citus_extension "$CITUS_COORDINATOR_CONTAINER"
    psql_exec "$CITUS_COORDINATOR_CONTAINER" "SELECT citus_set_coordinator_host('${CITUS_COORDINATOR_CONTAINER}');"

    for worker in $(seq 1 "$CITUS_WORKERS"); do
        ensure_citus_extension "citus-worker-${worker}"
        psql_exec "$CITUS_COORDINATOR_CONTAINER" \
            "SELECT citus_add_node('citus-worker-${worker}', 5432) WHERE NOT EXISTS (SELECT 1 FROM pg_dist_node WHERE nodename = 'citus-worker-${worker}' AND nodeport = 5432);"
    done
}

init_citus() {
    validate

    log "Initializing Citus coordinator and workers"

    wait_postgres "$CITUS_COORDINATOR_CONTAINER" || die "Coordinator did not become ready"

    local worker
    for worker in $(seq 1 "$CITUS_WORKERS"); do
        wait_postgres "citus-worker-${worker}" || die "Worker ${worker} did not become ready"
    done

    configure_citus_nodes

    psql_exec "$CITUS_COORDINATOR_CONTAINER" \
        "CREATE TABLE IF NOT EXISTS \"${POSTGRES_TABLE}\" (key TEXT PRIMARY KEY, value TEXT NOT NULL);"

    psql_exec "$CITUS_COORDINATOR_CONTAINER" \
        "SET citus.shard_count = ${CITUS_SHARD_COUNT}; DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_dist_partition WHERE logicalrelid = '\"${POSTGRES_TABLE}\"'::regclass) THEN PERFORM create_distributed_table('\"${POSTGRES_TABLE}\"', 'key'); END IF; END \$\$;"
}

verify() {
    log "Checking PostgreSQL Citus"

    wait_postgres "$CITUS_COORDINATOR_CONTAINER" || {
        compose logs citus-coordinator
        die "Coordinator did not become ready"
    }

    local state
    state="$(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$CITUS_COORDINATOR_CONTAINER" \
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT count(*) FROM pg_dist_node WHERE isactive AND nodename LIKE 'citus-worker-%';" 2>/dev/null || true)"

    if [[ "$state" != "$CITUS_WORKERS" ]]; then
        compose logs
        die "Expected $CITUS_WORKERS active Citus workers, got: ${state:-empty}"
    fi

    local distributed
    distributed="$(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$CITUS_COORDINATOR_CONTAINER" \
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT count(*) FROM pg_dist_partition WHERE logicalrelid = '\"${POSTGRES_TABLE}\"'::regclass;" 2>/dev/null || true)"

    if [[ "$distributed" != "1" ]]; then
        die "Table ${POSTGRES_TABLE} is not distributed. Recreate Citus with ./deploy_postgres_citus.sh down && ./deploy_postgres_citus.sh deploy"
    fi

    local worker_placements
    worker_placements="$(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$CITUS_COORDINATOR_CONTAINER" \
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT count(DISTINCT n.nodename) FROM pg_dist_shard s JOIN pg_dist_placement p USING (shardid) JOIN pg_dist_node n ON n.groupid = p.groupid WHERE s.logicalrelid = '\"${POSTGRES_TABLE}\"'::regclass AND n.nodename LIKE 'citus-worker-%';" 2>/dev/null || true)"

    if [[ "$worker_placements" != "$CITUS_WORKERS" ]]; then
        die "Table ${POSTGRES_TABLE} placements are not spread across all workers: expected $CITUS_WORKERS, got ${worker_placements:-empty}"
    fi

    echo "PostgreSQL Citus is ready: localhost:${CITUS_PORT}"
}

summary() {
    cat <<EOF

PostgreSQL Citus deployed.
  conn: postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:${CITUS_PORT}/${POSTGRES_DB}?sslmode=disable
  coordinator: ${CITUS_COORDINATOR_CONTAINER}
  workers: ${CITUS_WORKERS}
  shards: ${CITUS_SHARD_COUNT}
  table: ${POSTGRES_TABLE}
  memory each: ${CONTAINER_MEMORY_LIMIT}
  cpu each: ${POSTGRES_CPU_LIMIT}
  disk read/write: ${DISK_READ_BPS}/${DISK_WRITE_BPS} on ${DISK_LIMIT_DEVICE}
EOF
}

distribution() {
    log "Citus nodes"
    docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$CITUS_COORDINATOR_CONTAINER" \
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
        "SELECT nodeid, nodename, nodeport, isactive FROM pg_dist_node ORDER BY nodeid;"

    log "Shard placements for ${POSTGRES_TABLE}"
    docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$CITUS_COORDINATOR_CONTAINER" \
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
        "SELECT n.nodename, count(*) AS shard_placements FROM pg_dist_shard s JOIN pg_dist_placement p USING (shardid) JOIN pg_dist_node n ON n.groupid = p.groupid WHERE s.logicalrelid = '\"${POSTGRES_TABLE}\"'::regclass GROUP BY n.nodename ORDER BY n.nodename;"

    log "Distributed table metadata"
    docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$CITUS_COORDINATOR_CONTAINER" \
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
        "SELECT logicalrelid::regclass AS table_name, partmethod, repmodel FROM pg_dist_partition WHERE logicalrelid = '\"${POSTGRES_TABLE}\"'::regclass; SELECT count(*) AS shard_count FROM pg_dist_shard WHERE logicalrelid = '\"${POSTGRES_TABLE}\"'::regclass;"

    log "Worker shard table activity"
    docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$CITUS_COORDINATOR_CONTAINER" \
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
        "SELECT * FROM run_command_on_workers('SELECT current_database() AS db, sum(n_live_tup) AS live_rows, sum(seq_scan + idx_scan) AS scans, sum(n_tup_ins) AS inserted, sum(n_tup_upd) AS updated FROM pg_stat_user_tables WHERE relname LIKE ''${POSTGRES_TABLE}_%''');"
}

verify_tpcc_distribution() {
    log "Checking TPC-C table distribution"

    local distributed_count
    distributed_count="$(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$CITUS_COORDINATOR_CONTAINER" \
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT count(*) FROM pg_dist_partition WHERE logicalrelid IN ('warehouse'::regclass, 'district'::regclass, 'customer'::regclass, 'history'::regclass, 'new_order'::regclass, 'orders'::regclass, 'order_line'::regclass, 'stock'::regclass, 'item'::regclass);" 2>/dev/null || true)"

    if [[ "$distributed_count" == "0" || -z "$distributed_count" ]]; then
        die "No TPC-C tables are distributed in database ${POSTGRES_DB}. Check that go-tpc prepare created tables in this database."
    fi

    echo "TPC-C distributed tables found: ${distributed_count}"
}

distribute_tpcc_tables() {
    log "Distributing go-tpc TPC-C tables by warehouse"

    configure_citus_nodes

    psql_exec "$CITUS_COORDINATOR_CONTAINER" "
SET citus.shard_count = ${CITUS_SHARD_COUNT};
DO \$\$
DECLARE
    spec text[];
    table_reg regclass;
    specs text[][] := ARRAY[
        ARRAY['warehouse', 'w_id'],
        ARRAY['district', 'd_w_id'],
        ARRAY['customer', 'c_w_id'],
        ARRAY['history', 'h_w_id'],
        ARRAY['new_order', 'no_w_id'],
        ARRAY['orders', 'o_w_id'],
        ARRAY['order_line', 'ol_w_id'],
        ARRAY['stock', 's_w_id']
    ];
BEGIN
    table_reg := to_regclass('public.item');
    IF table_reg IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pg_dist_partition WHERE logicalrelid = table_reg) THEN
        PERFORM create_reference_table('item');
    END IF;

    FOREACH spec SLICE 1 IN ARRAY specs LOOP
        table_reg := to_regclass(format('public.%I', spec[1]));

        IF table_reg IS NOT NULL
           AND NOT EXISTS (
               SELECT 1
               FROM pg_dist_partition
               WHERE logicalrelid = table_reg
           ) THEN
            EXECUTE format('SELECT create_distributed_table(%L, %L)', spec[1], spec[2]);
        END IF;
    END LOOP;
END
\$\$;"
}

case "$ACTION" in
    deploy)
        down_existing
        prepare_files
        up
        init_citus
        verify
        summary
        ;;
    write)
        prepare_files
        ;;
    up)
        up
        ;;
    init)
        init_citus
        ;;
    verify)
        verify
        ;;
    distribution)
        distribution
        ;;
    distribute-tpcc|tpcc-distribute)
        distribute_tpcc_tables
        verify_tpcc_distribution
        ;;
    logs)
        compose logs -f
        ;;
    down)
        compose down -v --remove-orphans
        ;;
    *)
        echo "Usage: $0 [deploy|write|up|init|verify|distribution|distribute-tpcc|logs|down]"
        exit 1
        ;;
esac
