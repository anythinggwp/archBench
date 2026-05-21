#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-redis-tarantool-stack}"
REMOVE_PROJECT_DIR="${REMOVE_PROJECT_DIR:-1}"
REMOVE_IMAGES="${REMOVE_IMAGES:-1}"

echo "Останавливаю compose-проект..."

if [[ -d "$PROJECT_DIR" && -f "$PROJECT_DIR/docker-compose.yml" ]]; then
    (
        cd "$PROJECT_DIR"
        docker compose down -v --remove-orphans 2>/dev/null || true
    )
fi

echo "Удаляю возможные контейнеры Redis..."

docker rm -f redis-node 2>/dev/null || true
docker rm -f redis-master 2>/dev/null || true
docker rm -f redis-replica-1 2>/dev/null || true
docker rm -f redis-replica-2 2>/dev/null || true
docker rm -f redis-replica-3 2>/dev/null || true
docker rm -f redis-shard-1 2>/dev/null || true
docker rm -f redis-shard-2 2>/dev/null || true
docker rm -f redis-shard-3 2>/dev/null || true
docker rm -f redis-shard-4 2>/dev/null || true
docker rm -f redis-s1-master 2>/dev/null || true
docker rm -f redis-s1-replica 2>/dev/null || true
docker rm -f redis-s2-master 2>/dev/null || true
docker rm -f redis-s2-replica 2>/dev/null || true

echo "Удаляю возможные контейнеры Tarantool..."

docker rm -f tarantool-single-node 2>/dev/null || true
docker rm -f tarantool-node 2>/dev/null || true
docker rm -f tarantool-master 2>/dev/null || true
docker rm -f tarantool-replica-1 2>/dev/null || true
docker rm -f tarantool-replica-2 2>/dev/null || true
docker rm -f tarantool-replica-3 2>/dev/null || true
docker rm -f tarantool-shard-1 2>/dev/null || true
docker rm -f tarantool-shard-2 2>/dev/null || true
docker rm -f tarantool-shard-3 2>/dev/null || true
docker rm -f tarantool-shard-4 2>/dev/null || true
docker rm -f tarantool-s1-r1 2>/dev/null || true
docker rm -f tarantool-s1-r2 2>/dev/null || true
docker rm -f tarantool-s2-r1 2>/dev/null || true
docker rm -f tarantool-s2-r2 2>/dev/null || true

echo "Удаляю возможные контейнеры PostgreSQL и YDB..."

docker rm -f postgres-node 2>/dev/null || true
docker rm -f ydb-node 2>/dev/null || true
docker rm -f ydb-local 2>/dev/null || true

echo "Удаляю возможные volumes проекта..."

docker volume rm -f \
  redis-tarantool-stack_redis-data \
  redis-tarantool-stack_redis-master-data \
  redis-tarantool-stack_redis-replica-1-data \
  redis-tarantool-stack_redis-replica-2-data \
  redis-tarantool-stack_redis-replica-3-data \
  redis-tarantool-stack_redis-shard-1-data \
  redis-tarantool-stack_redis-shard-2-data \
  redis-tarantool-stack_redis-shard-3-data \
  redis-tarantool-stack_redis-shard-4-data \
  redis-tarantool-stack_redis-s1-master-data \
  redis-tarantool-stack_redis-s1-replica-data \
  redis-tarantool-stack_redis-s2-master-data \
  redis-tarantool-stack_redis-s2-replica-data \
  redis-tarantool-stack_tarantool-data \
  redis-tarantool-stack_tarantool-master-data \
  redis-tarantool-stack_tarantool-replica-1-data \
  redis-tarantool-stack_tarantool-replica-2-data \
  redis-tarantool-stack_tarantool-replica-3-data \
  redis-tarantool-stack_tarantool-shard-1-data \
  redis-tarantool-stack_tarantool-shard-2-data \
  redis-tarantool-stack_tarantool-shard-3-data \
  redis-tarantool-stack_tarantool-shard-4-data \
  redis-tarantool-stack_tarantool-s1-r1-data \
  redis-tarantool-stack_tarantool-s1-r2-data \
  redis-tarantool-stack_tarantool-s2-r1-data \
  redis-tarantool-stack_tarantool-s2-r2-data \
  redis-tarantool-stack_postgres-data \
  redis-tarantool-stack_ydb-certs \
  redis-tarantool-stack_ydb-data \
  2>/dev/null || true

echo "Удаляю возможные сети проекта..."

docker network rm redis-tarantool-stack_db-net 2>/dev/null || true
docker network rm db-net 2>/dev/null || true

if [[ "$REMOVE_IMAGES" == "1" || "$REMOVE_IMAGES" == "true" || "$REMOVE_IMAGES" == "yes" ]]; then
    echo "Удаляю локальный образ Tarantool..."
    docker image rm -f local-tarantool-single:3 2>/dev/null || true
fi

if [[ "$REMOVE_PROJECT_DIR" == "1" || "$REMOVE_PROJECT_DIR" == "true" || "$REMOVE_PROJECT_DIR" == "yes" ]]; then
    echo "Удаляю каталог проекта..."
    rm -rf "$PROJECT_DIR"
fi

echo
echo "Очистка завершена."
echo
echo "Оставшиеся контейнеры, похожие на стенд:"
docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' \
  | grep -E 'redis|tarantool|postgres-node|ydb-node|ydb-local' || true

echo
echo "Оставшиеся volumes, похожие на стенд:"
docker volume ls --format '{{.Name}}' \
  | grep -E 'redis-tarantool-stack|redis|tarantool|postgres|ydb' || true