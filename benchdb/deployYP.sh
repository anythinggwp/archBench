#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-ydb-postgres-stack}"
COMPOSE_FILE="compose.yml"
ENV_FILE=".env"

usage() {
    cat <<EOF
Usage:
  $0 up        Создать конфиги и запустить YDB + PostgreSQL
  $0 down      Остановить контейнеры, данные сохранить
  $0 restart   Перезапустить контейнеры
  $0 status    Показать статус контейнеров
  $0 logs      Показать логи всех сервисов
  $0 logs ydb  Показать логи YDB
  $0 logs pg   Показать логи PostgreSQL
  $0 psql      Открыть psql внутри контейнера PostgreSQL
  $0 clean     Остановить и удалить контейнеры, volumes и локальные данные YDB

Environment:
  PROJECT_DIR=some-dir $0 up
EOF
}

require_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "Ошибка: docker не найден."
        exit 1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        echo "Ошибка: docker compose не найден. Нужен Docker Compose v2."
        exit 1
    fi
}

create_files() {
    mkdir -p "$PROJECT_DIR"
    cd "$PROJECT_DIR"

    mkdir -p data/ydb/ydb_data
    mkdir -p data/ydb/ydb_certs

    if [ ! -f "$ENV_FILE" ]; then
        cat > "$ENV_FILE" <<'EOF'
COMPOSE_PROJECT_NAME=ydb-postgres-stack

# PostgreSQL
POSTGRES_VERSION=18
POSTGRES_DB=benchdb
POSTGRES_USER=bench
POSTGRES_PASSWORD=bench_password
POSTGRES_PORT=5432
POSTGRES_SHM_SIZE=256mb

# YDB
YDB_VERSION=latest
YDB_GRPCS_PORT=2135
YDB_GRPC_PORT=2136
YDB_MON_PORT=8765
YDB_PDISK_SIZE=10GB
EOF
    fi

    cat > "$COMPOSE_FILE" <<'EOF'
services:
  postgres:
    image: postgres:${POSTGRES_VERSION:-18}
    container_name: postgres-node
    restart: unless-stopped
    shm_size: ${POSTGRES_SHM_SIZE:-256mb}
    environment:
      POSTGRES_DB: ${POSTGRES_DB:-benchdb}
      POSTGRES_USER: ${POSTGRES_USER:-bench}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-bench_password}
      PGDATA: /var/lib/postgresql/data/pgdata
    ports:
      - "${POSTGRES_PORT:-5432}:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \"$${POSTGRES_USER}\" -d \"$${POSTGRES_DB}\""]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 10s

  ydb:
    image: ydbplatform/local-ydb:${YDB_VERSION:-latest}
    platform: linux/amd64
    container_name: ydb-node
    hostname: localhost
    restart: unless-stopped
    environment:
      GRPC_TLS_PORT: "2135"
      GRPC_PORT: "2136"
      MON_PORT: "8765"
      YDB_PDISK_SIZE: ${YDB_PDISK_SIZE:-10GB}
    ports:
      - "${YDB_GRPCS_PORT:-2135}:2135"
      - "${YDB_GRPC_PORT:-2136}:2136"
      - "${YDB_MON_PORT:-8765}:8765"
    volumes:
      - ./data/ydb/ydb_certs:/ydb_certs
      - ./data/ydb/ydb_data:/ydb_data

volumes:
  postgres_data:
EOF
}

go_project_dir() {
    if [ ! -d "$PROJECT_DIR" ]; then
        echo "Ошибка: каталог $PROJECT_DIR не найден. Сначала выполни: $0 up"
        exit 1
    fi

    cd "$PROJECT_DIR"
}

case "${1:-up}" in
    up)
        require_docker
        create_files
        docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" pull
        docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d
        docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" ps

        echo
        echo "PostgreSQL:"
        echo "  host:     localhost"
        echo "  port:     ${POSTGRES_PORT:-5432}"
        echo "  database: смотри $PROJECT_DIR/.env"
        echo
        echo "YDB:"
        echo "  UI:       http://localhost:${YDB_MON_PORT:-8765}"
        echo "  gRPC:     grpc://localhost:${YDB_GRPC_PORT:-2136}"
        echo "  gRPC TLS: grpcs://localhost:${YDB_GRPCS_PORT:-2135}"
        ;;

    down)
        require_docker
        go_project_dir
        docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" down
        ;;

    restart)
        require_docker
        go_project_dir
        docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" restart
        docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" ps
        ;;

    status|ps)
        require_docker
        go_project_dir
        docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" ps
        ;;

    logs)
        require_docker
        go_project_dir

        case "${2:-all}" in
            ydb)
                docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" logs -f ydb
                ;;
            pg|postgres|postgresql)
                docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" logs -f postgres
                ;;
            all)
                docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" logs -f
                ;;
            *)
                echo "Неизвестный сервис: $2"
                echo "Используй: $0 logs, $0 logs ydb или $0 logs pg"
                exit 1
                ;;
        esac
        ;;

    psql)
        require_docker
        go_project_dir

        set -a
        # shellcheck disable=SC1090
        source "$ENV_FILE"
        set +a

        docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec \
            -e PGPASSWORD="$POSTGRES_PASSWORD" \
            postgres \
            psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"
        ;;

    clean)
        require_docker
        go_project_dir
        docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" down -v --remove-orphans
        rm -rf data/ydb/ydb_data data/ydb/ydb_certs
        mkdir -p data/ydb/ydb_data data/ydb/ydb_certs
        echo "Контейнеры, volumes PostgreSQL и локальные данные YDB удалены."
        ;;

    help|-h|--help)
        usage
        ;;

    *)
        usage
        exit 1
        ;;
esac