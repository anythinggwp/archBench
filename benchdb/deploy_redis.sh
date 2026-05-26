#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-deploy}"

PROJECT_DIR="${PROJECT_DIR:-redis-stack}"
NETWORK_NAME="${NETWORK_NAME:-db-net}"

REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"
REDIS_CONTAINER="${REDIS_CONTAINER:-redis-node}"
REDIS_MODE="${REDIS_MODE:-single}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_CLUSTER_BASE_PORT="${REDIS_CLUSTER_BASE_PORT:-7001}"
REDIS_CPU_LIMIT="${REDIS_CPU_LIMIT:-0.5}"
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
    log "Preparing Redis files in $PROJECT_DIR"
    rm -rf "$PROJECT_DIR"
    mkdir -p "$PROJECT_DIR/redis"

    case "$REDIS_MODE" in
        single|cluster)
            ;;
        *)
            die "Unknown REDIS_MODE=$REDIS_MODE. Use single or cluster."
            ;;
    esac

    if [[ "$REDIS_MODE" == "cluster" ]]; then
        prepare_cluster_files
        return 0
    fi

    cat > "$PROJECT_DIR/redis/redis.conf" <<EOF
bind 0.0.0.0
port 6379
protected-mode no
appendonly yes
appendfilename "appendonly.aof"
dir /data
save 60 1000
loglevel notice
EOF

    cat > "$PROJECT_DIR/docker-compose.yml" <<EOF
services:
  redis:
    image: ${REDIS_IMAGE}
    container_name: ${REDIS_CONTAINER}
    command: ["redis-server", "/usr/local/etc/redis/redis.conf"]
    ports:
      - "${REDIS_PORT}:6379"
    volumes:
      - ./redis/redis.conf:/usr/local/etc/redis/redis.conf:ro
      - redis-data:/data
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
          cpus: "${REDIS_CPU_LIMIT}"
          memory: ${CONTAINER_MEMORY_LIMIT}

networks:
  ${NETWORK_NAME}:
    driver: bridge

volumes:
  redis-data:
EOF
}

prepare_cluster_files() {
    local i

    for i in 1 2 3 4 5 6; do
        local port=$((REDIS_CLUSTER_BASE_PORT + i - 1))
        mkdir -p "$PROJECT_DIR/redis/cluster-${i}"

        cat > "$PROJECT_DIR/redis/cluster-${i}/redis.conf" <<EOF
bind 0.0.0.0
port ${port}
protected-mode no
cluster-enabled yes
cluster-config-file nodes-${port}.conf
cluster-node-timeout 5000
cluster-announce-ip 127.0.0.1
cluster-announce-port ${port}
cluster-announce-bus-port $((port + 10000))
appendonly yes
appendfilename "appendonly.aof"
dir /data
save 60 1000
loglevel notice
EOF
    done

    cat > "$PROJECT_DIR/docker-compose.yml" <<EOF
services:
EOF

    for i in 1 2 3 4 5 6; do
        local port=$((REDIS_CLUSTER_BASE_PORT + i - 1))

        cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
  redis-cluster-${i}:
    image: ${REDIS_IMAGE}
    container_name: redis-cluster-${i}
    command: ["redis-server", "/usr/local/etc/redis/redis.conf"]
    network_mode: host
    volumes:
      - ./redis/cluster-${i}/redis.conf:/usr/local/etc/redis/redis.conf:ro
      - redis-cluster-${i}-data:/data
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
          cpus: "${REDIS_CPU_LIMIT}"
          memory: ${CONTAINER_MEMORY_LIMIT}

EOF
    done

    cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
volumes:
  redis-cluster-1-data:
  redis-cluster-2-data:
  redis-cluster-3-data:
  redis-cluster-4-data:
  redis-cluster-5-data:
  redis-cluster-6-data:
EOF
}

up() {
    log "Starting Redis"
    compose up -d --force-recreate
}

init_cluster() {
    if [[ "$REDIS_MODE" != "cluster" ]]; then
        return 0
    fi

    log "Initializing Redis Cluster: 3 master + 3 replica"

    for i in 1 2 3 4 5 6; do
        local port=$((REDIS_CLUSTER_BASE_PORT + i - 1))
        for _ in {1..60}; do
            if docker exec "redis-cluster-${i}" redis-cli -p "$port" ping 2>/dev/null | grep -q PONG; then
                break
            fi
            sleep 1
        done
    done

    local nodes=""
    for i in 1 2 3 4 5 6; do
        local port=$((REDIS_CLUSTER_BASE_PORT + i - 1))
        nodes="${nodes} 127.0.0.1:${port}"
    done

    docker exec redis-cluster-1 sh -c "yes yes | redis-cli --cluster create${nodes} --cluster-replicas 1"
}

verify() {
    log "Checking Redis"
    if [[ "$REDIS_MODE" == "cluster" ]]; then
        for _ in {1..60}; do
            if docker exec redis-cluster-1 redis-cli -c -p "$REDIS_CLUSTER_BASE_PORT" cluster info 2>/dev/null | grep -q "cluster_state:ok"; then
                echo "Redis Cluster is ready: 127.0.0.1:${REDIS_CLUSTER_BASE_PORT}..$((REDIS_CLUSTER_BASE_PORT + 5))"
                return 0
            fi
            sleep 1
        done
        compose logs
        die "Redis Cluster did not become ready"
    fi

    for _ in {1..60}; do
        if docker exec "$REDIS_CONTAINER" redis-cli ping 2>/dev/null | grep -q PONG; then
            echo "Redis is ready: localhost:${REDIS_PORT}"
            return 0
        fi
        sleep 1
    done
    compose logs redis
    die "Redis did not become ready"
}

summary() {
    cat <<EOF

Redis deployed.
  mode: ${REDIS_MODE}
  addr: $(if [[ "$REDIS_MODE" == "cluster" ]]; then echo "127.0.0.1:${REDIS_CLUSTER_BASE_PORT}..$((REDIS_CLUSTER_BASE_PORT + 5))"; else echo "localhost:${REDIS_PORT}"; fi)
  container: $(if [[ "$REDIS_MODE" == "cluster" ]]; then echo "redis-cluster-1..redis-cluster-6"; else echo "${REDIS_CONTAINER}"; fi)
  memory: ${CONTAINER_MEMORY_LIMIT}
  cpu: ${REDIS_CPU_LIMIT}
  disk read/write: ${DISK_READ_BPS}/${DISK_WRITE_BPS} on ${DISK_LIMIT_DEVICE}
EOF
}

case "$ACTION" in
    deploy)
        prepare_files
        up
        init_cluster
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
    init-cluster)
        init_cluster
        ;;
    logs)
        compose logs -f redis
        ;;
    down)
        compose down -v --remove-orphans
        ;;
    *)
        echo "Usage: $0 [deploy|write|up|init-cluster|verify|logs|down]"
        exit 1
        ;;
esac
