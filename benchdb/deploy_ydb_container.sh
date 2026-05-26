#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-deploy}"

PROJECT_DIR="${PROJECT_DIR:-ydb-stack}"
NETWORK_NAME="${NETWORK_NAME:-db-net}"

YDB_IMAGE="${YDB_IMAGE:-ydbplatform/local-ydb:latest}"
YDB_CONTAINER="${YDB_CONTAINER:-ydb-node}"
YDB_GRPC_TLS_PORT="${YDB_GRPC_TLS_PORT:-2135}"
YDB_GRPC_PORT="${YDB_GRPC_PORT:-2136}"
YDB_MON_PORT="${YDB_MON_PORT:-8765}"
YDB_KAFKA_PORT="${YDB_KAFKA_PORT:-9092}"
YDB_CPU_LIMIT="${YDB_CPU_LIMIT:-0.5}"
CONTAINER_MEMORY_LIMIT="${CONTAINER_MEMORY_LIMIT:-1G}"
DISK_LIMIT_DEVICE="${DISK_LIMIT_DEVICE:-/dev/sda}"
DISK_READ_BPS="${DISK_READ_BPS:-20mb}"
DISK_WRITE_BPS="${DISK_WRITE_BPS:-10mb}"

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
    log "Preparing YDB files in $PROJECT_DIR"
    rm -rf "$PROJECT_DIR"
    mkdir -p "$PROJECT_DIR"

    cat > "$PROJECT_DIR/docker-compose.yml" <<EOF
services:
  ydb:
    image: ${YDB_IMAGE}
    container_name: ${YDB_CONTAINER}
    hostname: localhost
    platform: linux/amd64
    environment:
      GRPC_TLS_PORT: "2135"
      GRPC_PORT: "2136"
      MON_PORT: "8765"
      YDB_KAFKA_PROXY_PORT: "9092"
    ports:
      - "${YDB_GRPC_TLS_PORT}:2135"
      - "${YDB_GRPC_PORT}:2136"
      - "${YDB_MON_PORT}:8765"
      - "${YDB_KAFKA_PORT}:9092"
    volumes:
      - ydb-certs:/ydb_certs
      - ydb-data:/ydb_data
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
          cpus: "${YDB_CPU_LIMIT}"
          memory: ${CONTAINER_MEMORY_LIMIT}

networks:
  ${NETWORK_NAME}:
    driver: bridge

volumes:
  ydb-certs:
  ydb-data:
EOF
}

up() {
    log "Starting YDB"
    compose up -d --force-recreate
}

verify() {
    log "Checking YDB ports"
    for _ in {1..90}; do
        if timeout 1 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/${YDB_GRPC_PORT}" 2>/dev/null; then
            echo "YDB is ready: grpc://localhost:${YDB_GRPC_PORT}/local"
            return 0
        fi
        sleep 1
    done
    compose logs ydb
    die "YDB did not open gRPC port"
}

summary() {
    cat <<EOF

YDB deployed.
  endpoint: grpc://localhost:${YDB_GRPC_PORT}/local
  web ui: http://localhost:${YDB_MON_PORT}
  container: ${YDB_CONTAINER}
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
        compose logs -f ydb
        ;;
    down)
        compose down -v --remove-orphans
        ;;
    *)
        echo "Usage: $0 [deploy|write|up|verify|logs|down]"
        exit 1
        ;;
esac
