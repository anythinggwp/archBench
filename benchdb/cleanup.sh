#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-redis-tarantool-stack}"
REMOVE_PROJECT_DIR="${REMOVE_PROJECT_DIR:-1}"
REMOVE_IMAGES="${REMOVE_IMAGES:-1}"

# По умолчанию официальные образы postgres/ydb не удаляются.
# Если нужно удалить и их:
#   REMOVE_DB_IMAGES=1 ./cleanup.sh
REMOVE_DB_IMAGES="${REMOVE_DB_IMAGES:-0}"

# Имена контейнеров по умолчанию из deploy.sh
REDIS_CONTAINER="${REDIS_CONTAINER:-redis-node}"
TARANTOOL_CONTAINER="${TARANTOOL_CONTAINER:-tarantool-single-node}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-postgres-node}"
YDB_CONTAINER="${YDB_CONTAINER:-ydb-node}"

TARANTOOL_IMAGE="${TARANTOOL_IMAGE:-local-tarantool-single:3}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"
YDB_IMAGE="${YDB_IMAGE:-ydbplatform/local-ydb:latest}"

# Docker Compose обычно формирует prefix volumes/networks из имени каталога проекта.
# Например:
#   redis-tarantool-stack_postgres-data
# Если PROJECT_DIR=db-stand, prefix будет:
#   db-stand_postgres-data
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$(basename "$PROJECT_DIR")}"

is_true() {
    case "${1:-}" in
        1|true|yes|on|y|Y) return 0 ;;
        *) return 1 ;;
    esac
}

remove_container() {
    local name="$1"
    docker rm -f "$name" 2>/dev/null || true
}

remove_volume() {
    local name="$1"
    docker volume rm -f "$name" 2>/dev/null || true
}

remove_network() {
    local name="$1"
    docker network rm "$name" 2>/dev/null || true
}

echo "Останавливаю compose-проект..."

if [[ -d "$PROJECT_DIR" && -f "$PROJECT_DIR/docker-compose.yml" ]]; then
    (
        cd "$PROJECT_DIR"
        docker compose down -v --remove-orphans 2>/dev/null || true
    )
fi

echo "Удаляю возможные контейнеры Redis..."

remove_container "$REDIS_CONTAINER"

remove_container redis-master
remove_container redis-replica-1
remove_container redis-replica-2
remove_container redis-replica-3

remove_container redis-shard-1
remove_container redis-shard-2
remove_container redis-shard-3
remove_container redis-shard-4

remove_container redis-s1-master
remove_container redis-s1-replica
remove_container redis-s2-master
remove_container redis-s2-replica

# Redis Cluster
remove_container redis-cluster-1
remove_container redis-cluster-2
remove_container redis-cluster-3
remove_container redis-cluster-4
remove_container redis-cluster-5
remove_container redis-cluster-6

echo "Удаляю возможные контейнеры Tarantool..."

remove_container "$TARANTOOL_CONTAINER"
remove_container tarantool-node

remove_container tarantool-master
remove_container tarantool-replica-1
remove_container tarantool-replica-2
remove_container tarantool-replica-3

remove_container tarantool-shard-1
remove_container tarantool-shard-2
remove_container tarantool-shard-3
remove_container tarantool-shard-4

remove_container tarantool-s1-r1
remove_container tarantool-s1-r2
remove_container tarantool-s2-r1
remove_container tarantool-s2-r2

echo "Удаляю возможные контейнеры PostgreSQL..."

remove_container "$POSTGRES_CONTAINER"
remove_container postgres-node
remove_container postgres

echo "Удаляю возможные контейнеры YDB..."

remove_container "$YDB_CONTAINER"
remove_container ydb-node
remove_container ydb-local
remove_container ydb

echo "Удаляю volumes Redis..."

for prefix in "$COMPOSE_PROJECT_NAME" "redis-tarantool-stack"; do
    remove_volume "${prefix}_redis-data"

    remove_volume "${prefix}_redis-master-data"
    remove_volume "${prefix}_redis-replica-1-data"
    remove_volume "${prefix}_redis-replica-2-data"
    remove_volume "${prefix}_redis-replica-3-data"

    remove_volume "${prefix}_redis-shard-1-data"
    remove_volume "${prefix}_redis-shard-2-data"
    remove_volume "${prefix}_redis-shard-3-data"
    remove_volume "${prefix}_redis-shard-4-data"

    remove_volume "${prefix}_redis-s1-master-data"
    remove_volume "${prefix}_redis-s1-replica-data"
    remove_volume "${prefix}_redis-s2-master-data"
    remove_volume "${prefix}_redis-s2-replica-data"

    remove_volume "${prefix}_redis-cluster-1-data"
    remove_volume "${prefix}_redis-cluster-2-data"
    remove_volume "${prefix}_redis-cluster-3-data"
    remove_volume "${prefix}_redis-cluster-4-data"
    remove_volume "${prefix}_redis-cluster-5-data"
    remove_volume "${prefix}_redis-cluster-6-data"
done

echo "Удаляю volumes Tarantool..."

for prefix in "$COMPOSE_PROJECT_NAME" "redis-tarantool-stack"; do
    remove_volume "${prefix}_tarantool-data"

    remove_volume "${prefix}_tarantool-master-data"
    remove_volume "${prefix}_tarantool-replica-1-data"
    remove_volume "${prefix}_tarantool-replica-2-data"
    remove_volume "${prefix}_tarantool-replica-3-data"

    remove_volume "${prefix}_tarantool-shard-1-data"
    remove_volume "${prefix}_tarantool-shard-2-data"
    remove_volume "${prefix}_tarantool-shard-3-data"
    remove_volume "${prefix}_tarantool-shard-4-data"

    remove_volume "${prefix}_tarantool-s1-r1-data"
    remove_volume "${prefix}_tarantool-s1-r2-data"
    remove_volume "${prefix}_tarantool-s2-r1-data"
    remove_volume "${prefix}_tarantool-s2-r2-data"
done

echo "Удаляю volumes PostgreSQL..."

for prefix in "$COMPOSE_PROJECT_NAME" "redis-tarantool-stack"; do
    remove_volume "${prefix}_postgres-data"
    remove_volume "${prefix}_postgresql-data"
    remove_volume "${prefix}_pg-data"
done

echo "Удаляю volumes YDB..."

for prefix in "$COMPOSE_PROJECT_NAME" "redis-tarantool-stack"; do
    remove_volume "${prefix}_ydb-data"
    remove_volume "${prefix}_ydb-certs"
    remove_volume "${prefix}_ydb-logs"
    remove_volume "${prefix}_ydb-init"
done

echo "Удаляю возможные сети проекта..."

remove_network "${COMPOSE_PROJECT_NAME}_db-net"
remove_network "redis-tarantool-stack_db-net"
remove_network "db-net"

if is_true "$REMOVE_IMAGES"; then
    echo "Удаляю локальный образ Tarantool..."
    docker image rm -f "$TARANTOOL_IMAGE" 2>/dev/null || true
fi

if is_true "$REMOVE_DB_IMAGES"; then
    echo "Удаляю образы PostgreSQL и YDB..."
    docker image rm -f "$POSTGRES_IMAGE" 2>/dev/null || true
    docker image rm -f "$YDB_IMAGE" 2>/dev/null || true
fi

if is_true "$REMOVE_PROJECT_DIR"; then
    echo "Удаляю каталог проекта..."
    rm -rf "$PROJECT_DIR"
fi

echo
echo "Очистка завершена."
echo
echo "Оставшиеся контейнеры, похожие на стенд:"

docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' \
  | grep -E 'redis|tarantool|postgres|ydb' || true

echo
echo "Оставшиеся volumes, похожие на стенд:"

docker volume ls --format '{{.Name}}' \
  | grep -E "${COMPOSE_PROJECT_NAME}|redis-tarantool-stack|redis|tarantool|postgres|postgresql|pg-data|ydb" || true

echo
echo "Оставшиеся сети, похожие на стенд:"

docker network ls --format '{{.Name}}' \
  | grep -E "${COMPOSE_PROJECT_NAME}|redis-tarantool-stack|db-net" || true