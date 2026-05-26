#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-deploy}"

PROJECT_DIR="${PROJECT_DIR:-postgres-stack}"
NETWORK_NAME="${NETWORK_NAME:-db-net}"

POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-postgres-node}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
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

prepare_files() {
    log "Preparing PostgreSQL files in $PROJECT_DIR"
    rm -rf "$PROJECT_DIR"
    mkdir -p "$PROJECT_DIR/postgres"

    cat > "$PROJECT_DIR/postgres/init.sql" <<EOF
CREATE TABLE IF NOT EXISTS "${POSTGRES_TABLE}" (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
EOF

    cat > "$PROJECT_DIR/docker-compose.yml" <<EOF
services:
  postgres:
    image: ${POSTGRES_IMAGE}
    container_name: ${POSTGRES_CONTAINER}
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    command:
      - postgres
      - "-c"
      - "max_connections=${POSTGRES_MAX_CONNECTIONS}"
    ports:
      - "${POSTGRES_PORT}:5432"
    volumes:
      - postgres-data:/var/lib/postgresql/data
      - ./postgres/init.sql:/docker-entrypoint-initdb.d/001-init.sql:ro
    networks:
      - ${NETWORK_NAME}
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

networks:
  ${NETWORK_NAME}:
    driver: bridge

volumes:
  postgres-data:
EOF
}

up() {
    log "Starting PostgreSQL"
    compose up -d --force-recreate
}

verify() {
    log "Checking PostgreSQL"
    for _ in {1..60}; do
        if docker exec "$POSTGRES_CONTAINER" pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
            echo "PostgreSQL is ready: localhost:${POSTGRES_PORT}"
            return 0
        fi
        sleep 1
    done
    compose logs postgres
    die "PostgreSQL did not become ready"
}

summary() {
    cat <<EOF

PostgreSQL deployed.
  conn: postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=disable
  table: ${POSTGRES_TABLE}
  container: ${POSTGRES_CONTAINER}
  memory: ${CONTAINER_MEMORY_LIMIT}
  disk read/write: ${DISK_READ_BPS}/${DISK_WRITE_BPS} on ${DISK_LIMIT_DEVICE}
EOF
}

case "$ACTION" in
    deploy)
        prepare_files
        up
        verify
        summary
        ;;
    write)
        prepare_files
        ;;
    up)
        up
        ;;
    verify)
        verify
        ;;
    logs)
        compose logs -f postgres
        ;;
    down)
        compose down -v --remove-orphans
        ;;
    *)
        echo "Usage: $0 [deploy|write|up|verify|logs|down]"
        exit 1
        ;;
esac
