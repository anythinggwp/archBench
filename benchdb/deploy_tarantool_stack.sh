#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-deploy}"

PROJECT_DIR="${PROJECT_DIR:-tarantool-stack}"
NETWORK_NAME="${NETWORK_NAME:-db-net}"

TARANTOOL_BASE_IMAGE="${TARANTOOL_BASE_IMAGE:-tarantool/tarantool:3}"
TARANTOOL_IMAGE="${TARANTOOL_IMAGE:-local-tarantool-single:3}"
TARANTOOL_CONTAINER="${TARANTOOL_CONTAINER:-tarantool-single-node}"
TARANTOOL_PORT="${TARANTOOL_PORT:-3301}"
TARANTOOL_USER="${TARANTOOL_USER:-app}"
TARANTOOL_PASSWORD="${TARANTOOL_PASSWORD:-app_pass}"
TARANTOOL_SPACE="${TARANTOOL_SPACE:-kv}"
TARANTOOL_MEMTX_MEMORY="${TARANTOOL_MEMTX_MEMORY:-4294967296}"
TARANTOOL_WAL_MODE="${TARANTOOL_WAL_MODE:-none}"
TARANTOOL_CPU_LIMIT="${TARANTOOL_CPU_LIMIT:-0.5}"
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
    log "Preparing Tarantool files in $PROJECT_DIR"
    rm -rf "$PROJECT_DIR"
    mkdir -p "$PROJECT_DIR/tarantool"

    cat > "$PROJECT_DIR/tarantool/Dockerfile" <<EOF
FROM ${TARANTOOL_BASE_IMAGE}
COPY init.lua /opt/tarantool/init.lua
CMD ["tarantool", "/opt/tarantool/init.lua"]
EOF

    cat > "$PROJECT_DIR/tarantool/init.lua" <<'EOF'
local space_name = os.getenv('TARANTOOL_SPACE') or 'kv'
local app_user = os.getenv('TARANTOOL_USER') or 'app'
local app_password = os.getenv('TARANTOOL_PASSWORD') or 'app_pass'
local memtx_memory = tonumber(os.getenv('TARANTOOL_MEMTX_MEMORY') or tostring(4 * 1024 * 1024 * 1024))
local wal_mode = os.getenv('TARANTOOL_WAL_MODE') or 'none'

box.cfg({
    listen = '0.0.0.0:3301',
    memtx_memory = memtx_memory,
    wal_mode = wal_mode,
    memtx_dir = '/var/lib/tarantool',
    vinyl_dir = '/var/lib/tarantool',
})

local function grant_user(user, privilege, object_type, object_name)
    local ok, err = pcall(function()
        box.schema.user.grant(user, privilege, object_type, object_name, {
            if_not_exists = true,
        })
    end)

    if not ok and not tostring(err):match('Duplicate') and not tostring(err):match('already') then
        error(err)
    end
end

box.once('bootstrap_schema_v1', function()
    box.schema.user.create(app_user, {
        password = app_password,
        if_not_exists = true,
    })

    grant_user(app_user, 'read', 'universe', nil)
    grant_user(app_user, 'write', 'universe', nil)
    grant_user(app_user, 'execute', 'universe', nil)

    local kv = box.schema.space.create(space_name, {
        if_not_exists = true,
    })

    kv:format({
        {name = 'key', type = 'string'},
        {name = 'value', type = 'string'},
    })

    kv:create_index('primary', {
        type = 'HASH',
        parts = {
            {field = 1, type = 'string'},
        },
        if_not_exists = true,
    })
end)

rawset(_G, 'put', function(key, value)
    return box.space[space_name]:replace{key, value}
end)

rawset(_G, 'get', function(key)
    return box.space[space_name]:get{key}
end)

rawset(_G, 'truncate_kv', function()
    box.space[space_name]:truncate()
    return box.space[space_name]:len()
end)
EOF

    cat > "$PROJECT_DIR/docker-compose.yml" <<EOF
services:
  tarantool:
    build:
      context: ./tarantool
      dockerfile: Dockerfile
    image: ${TARANTOOL_IMAGE}
    container_name: ${TARANTOOL_CONTAINER}
    environment:
      TARANTOOL_USER: ${TARANTOOL_USER}
      TARANTOOL_PASSWORD: ${TARANTOOL_PASSWORD}
      TARANTOOL_SPACE: ${TARANTOOL_SPACE}
      TARANTOOL_MEMTX_MEMORY: "${TARANTOOL_MEMTX_MEMORY}"
      TARANTOOL_WAL_MODE: ${TARANTOOL_WAL_MODE}
    ports:
      - "${TARANTOOL_PORT}:3301"
    volumes:
      - tarantool-data:/var/lib/tarantool
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
          cpus: "${TARANTOOL_CPU_LIMIT}"
          memory: ${CONTAINER_MEMORY_LIMIT}

networks:
  ${NETWORK_NAME}:
    driver: bridge

volumes:
  tarantool-data:
EOF
}

build_image() {
    log "Building Tarantool image"
    compose build
}

up() {
    log "Starting Tarantool"
    compose up -d --force-recreate
}

verify() {
    log "Checking Tarantool"
    for _ in {1..60}; do
        if docker exec "$TARANTOOL_CONTAINER" tarantool -e "local net_box = require('net.box'); local c = net_box.connect('${TARANTOOL_USER}:${TARANTOOL_PASSWORD}@127.0.0.1:3301'); c:ping(); c:close()" >/dev/null 2>&1; then
            echo "Tarantool is ready: localhost:${TARANTOOL_PORT}"
            return 0
        fi
        sleep 1
    done
    compose logs tarantool
    die "Tarantool did not become ready"
}

summary() {
    cat <<EOF

Tarantool deployed.
  addr: localhost:${TARANTOOL_PORT}
  user: ${TARANTOOL_USER}
  password: ${TARANTOOL_PASSWORD}
  space: ${TARANTOOL_SPACE}
  container: ${TARANTOOL_CONTAINER}
  memory: ${CONTAINER_MEMORY_LIMIT}
  disk read/write: ${DISK_READ_BPS}/${DISK_WRITE_BPS} on ${DISK_LIMIT_DEVICE}
EOF
}

case "$ACTION" in
    deploy)
        prepare_files
        build_image
        up
        verify
        summary
        ;;
    write)
        prepare_files
        ;;
    build)
        build_image
        ;;
    up)
        up
        ;;
    verify)
        verify
        ;;
    logs)
        compose logs -f tarantool
        ;;
    down)
        compose down -v --remove-orphans
        ;;
    *)
        echo "Usage: $0 [deploy|write|build|up|verify|logs|down]"
        exit 1
        ;;
esac
