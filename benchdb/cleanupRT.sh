#!/bin/bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-redis-tarantool-stack}"
PROJECT_NAME="${PROJECT_NAME:-redis-tarantool-stack}"

echo "Останавливаю compose-проект, если он существует..."

if [ -d "$PROJECT_DIR" ] && [ -f "$PROJECT_DIR/docker-compose.yml" ]; then
    cd "$PROJECT_DIR"

    docker compose down -v --remove-orphans 2>/dev/null || true

    cd ..
fi

echo "Удаляю контейнеры по именам..."

docker rm -f redis-node 2>/dev/null || true
docker rm -f tarantool-node 2>/dev/null || true
docker rm -f tarantool-single-node 2>/dev/null || true

echo "Удаляю volumes..."

docker volume rm redis-tarantool-stack_redis-data 2>/dev/null || true
docker volume rm redis-tarantool-stack_tarantool-data 2>/dev/null || true
docker volume rm "${PROJECT_NAME}_redis-data" 2>/dev/null || true
docker volume rm "${PROJECT_NAME}_tarantool-data" 2>/dev/null || true

echo "Удаляю сети..."

docker network rm redis-tarantool-stack_db-net 2>/dev/null || true
docker network rm "${PROJECT_NAME}_db-net" 2>/dev/null || true

echo "Удаляю локальные образы, созданные для стенда..."

docker image rm -f local-tarantool-single:3 2>/dev/null || true
docker image rm -f redis-tarantool-stack-tarantool 2>/dev/null || true
docker image rm -f "${PROJECT_NAME}-tarantool" 2>/dev/null || true

echo "Удаляю каталог проекта..."

rm -rf "$PROJECT_DIR"

echo "Удаляю dangling resources Docker..."

docker container prune -f 2>/dev/null || true
docker volume prune -f 2>/dev/null || true
docker network prune -f 2>/dev/null || true
docker image prune -f 2>/dev/null || true

echo "Готово. Контейнеры, volumes, сети, локальные образы и каталог проекта удалены."