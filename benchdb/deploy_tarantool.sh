#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Standalone Tarantool vshard deploy script
# ============================================================
#
# This script generates a Tarantool 3.x YAML-configured vshard cluster.
# The topology follows the official vshard layout:
#   one or more stateless routers + N storage replica sets,
#   each with M storage instances.
#
# Default:
#   SHARDS=2
#   REPLICAS_PER_SHARD=2
#
# Useful env:
#   SHARDS=2|3|4
#   REPLICAS_PER_SHARD=2|3
#   ROUTERS=1|2|3
#   PROJECT_DIR=tarantool-vshard-stack
#   TARANTOOL_USER=app
#   TARANTOOL_PASSWORD=app_pass
#   TARANTOOL_REPLICATION_USER=replicator
#   TARANTOOL_REPLICATION_PASSWORD=replicator_pass
#   TARANTOOL_SHARDING_USER=storage
#   TARANTOOL_SHARDING_PASSWORD=storage_pass
#   TARANTOOL_SPACE=kv
#   TARANTOOL_WAL_MODE=write|fsync
#   TARANTOOL_MEMTX_MEMORY=4294967296
#   TARANTOOL_VSHARD_BUCKET_COUNT=3000
#   TARANTOOL_VSHARD_VERSION=0.1.40
#   TARANTOOL_CRUD_VERSION=1.7.4
#   TARANTOOL_BALANCER=auto|0|1
#   TARANTOOL_BALANCER_PORT=3301
#   TARANTOOL_ROUTER_HOST_BASE_PORT=3302 with balancer, 3301 without it
#   TARANTOOL_STORAGE_BASE_PORT=next free port after router host ports
#   TARANTOOL_ROUTER_CPU_LIMIT=2.0
#   TARANTOOL_BALANCER_CPU_LIMIT=1.0
#   TARANTOOL_STORAGE_CPU_LIMIT=1.0
#   KEEP_DATA=0|1
#
# Examples:
#   SHARDS=2 REPLICAS_PER_SHARD=2 ./deploy_tarantool.sh deploy
#   ROUTERS=3 SHARDS=4 REPLICAS_PER_SHARD=2 TARANTOOL_ROUTER_CPU_LIMIT=2.0 ./deploy_tarantool.sh deploy
# ============================================================

PROJECT_DIR="${PROJECT_DIR:-tarantool-vshard-stack}"

SHARDS="${SHARDS:-2}"
REPLICAS_PER_SHARD="${REPLICAS_PER_SHARD:-2}"
ROUTERS="${ROUTERS:-1}"

TARANTOOL_BASE_IMAGE="${TARANTOOL_BASE_IMAGE:-tarantool/tarantool:3}"
TARANTOOL_IMAGE="${TARANTOOL_IMAGE:-local-tarantool-vshard:3}"
TARANTOOL_VSHARD_VERSION="${TARANTOOL_VSHARD_VERSION:-0.1.40}"
TARANTOOL_CRUD_VERSION="${TARANTOOL_CRUD_VERSION:-1.7.4}"

TARANTOOL_USER="${TARANTOOL_USER:-app}"
TARANTOOL_PASSWORD="${TARANTOOL_PASSWORD:-app_pass}"
TARANTOOL_REPLICATION_USER="${TARANTOOL_REPLICATION_USER:-replicator}"
TARANTOOL_REPLICATION_PASSWORD="${TARANTOOL_REPLICATION_PASSWORD:-replicator_pass}"
TARANTOOL_SHARDING_USER="${TARANTOOL_SHARDING_USER:-storage}"
TARANTOOL_SHARDING_PASSWORD="${TARANTOOL_SHARDING_PASSWORD:-storage_pass}"
TARANTOOL_SPACE="${TARANTOOL_SPACE:-kv}"
TARANTOOL_WAL_MODE="${TARANTOOL_WAL_MODE:-write}"
TARANTOOL_MEMTX_MEMORY="${TARANTOOL_MEMTX_MEMORY:-4294967296}"
TARANTOOL_VSHARD_BUCKET_COUNT="${TARANTOOL_VSHARD_BUCKET_COUNT:-3000}"

TARANTOOL_ROUTER_PORT="${TARANTOOL_ROUTER_PORT:-3301}"
TARANTOOL_BALANCER="${TARANTOOL_BALANCER:-auto}"
TARANTOOL_BALANCER_IMAGE="${TARANTOOL_BALANCER_IMAGE:-haproxy:2.9-alpine}"
TARANTOOL_BALANCER_PORT="${TARANTOOL_BALANCER_PORT:-${TARANTOOL_ROUTER_PORT}}"
TARANTOOL_BALANCER_ALGORITHM="${TARANTOOL_BALANCER_ALGORITHM:-leastconn}"

case "$TARANTOOL_BALANCER" in
    auto)
        case "$ROUTERS" in
            2|3|4|5|6|7|8|9|10|11|12|13|14|15|16)
                BALANCER_ENABLED=1
                ;;
            *)
                BALANCER_ENABLED=0
                ;;
        esac
        ;;
    1|true|yes|on|y|Y)
        BALANCER_ENABLED=1
        ;;
    *)
        BALANCER_ENABLED=0
        ;;
esac

if [[ -z "${TARANTOOL_ROUTER_HOST_BASE_PORT+x}" ]]; then
    if [[ "$BALANCER_ENABLED" == "1" ]]; then
        TARANTOOL_ROUTER_HOST_BASE_PORT=$((TARANTOOL_BALANCER_PORT + 1))
    else
        TARANTOOL_ROUTER_HOST_BASE_PORT="${TARANTOOL_ROUTER_PORT}"
    fi
fi

if [[ -z "${TARANTOOL_STORAGE_BASE_PORT+x}" ]]; then
    case "$ROUTERS" in
        1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16)
            TARANTOOL_STORAGE_BASE_PORT=$((TARANTOOL_ROUTER_HOST_BASE_PORT + ROUTERS))
            ;;
        *)
            TARANTOOL_STORAGE_BASE_PORT=3302
            ;;
    esac
fi

TARANTOOL_CPU_LIMIT="${TARANTOOL_CPU_LIMIT:-1.0}"
TARANTOOL_ROUTER_CPU_LIMIT="${TARANTOOL_ROUTER_CPU_LIMIT:-2.0}"
TARANTOOL_BALANCER_CPU_LIMIT="${TARANTOOL_BALANCER_CPU_LIMIT:-1.0}"
TARANTOOL_STORAGE_CPU_LIMIT="${TARANTOOL_STORAGE_CPU_LIMIT:-${TARANTOOL_CPU_LIMIT}}"
TARANTOOL_MEMORY_LIMIT="${TARANTOOL_MEMORY_LIMIT:-5G}"
TARANTOOL_BALANCER_MEMORY_LIMIT="${TARANTOOL_BALANCER_MEMORY_LIMIT:-512M}"

NETWORK_NAME="${NETWORK_NAME:-db-net}"
KEEP_DATA="${KEEP_DATA:-0}"
BUILD_NO_CACHE="${BUILD_NO_CACHE:-0}"

BALANCER_CONTAINER="tarantool-vshard-router-lb"
ROUTER_CONTAINER="tarantool-vshard-router"
ROUTER_INSTANCE="router-a-001"

log() {
    echo
    echo "==> $*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

is_true() {
    case "${1:-}" in
        1|true|yes|on|y|Y) return 0 ;;
        *) return 1 ;;
    esac
}

balancer_enabled() {
    [[ "$BALANCER_ENABLED" == "1" ]]
}

validate() {
    case "$ROUTERS" in
        1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16)
            ;;
        *)
            die "ROUTERS must be 1..16, got: $ROUTERS"
            ;;
    esac

    case "$SHARDS" in
        1|2|3|4|5|6|7|8)
            ;;
        *)
            die "SHARDS must be 1..8, got: $SHARDS"
            ;;
    esac

    case "$REPLICAS_PER_SHARD" in
        2|3|4|5)
            ;;
        *)
            die "REPLICAS_PER_SHARD must be 2..5 for a documented vshard replica set, got: $REPLICAS_PER_SHARD"
            ;;
    esac

    case "$TARANTOOL_BALANCER" in
        auto|0|1|true|false|yes|no|on|off|y|Y|n|N)
            ;;
        *)
            die "TARANTOOL_BALANCER must be auto, 0 or 1, got: $TARANTOOL_BALANCER"
            ;;
    esac

    case "$TARANTOOL_BALANCER_ALGORITHM" in
        leastconn|roundrobin)
            ;;
        *)
            die "TARANTOOL_BALANCER_ALGORITHM must be leastconn or roundrobin, got: $TARANTOOL_BALANCER_ALGORITHM"
            ;;
    esac

    case "$TARANTOOL_WAL_MODE" in
        write|fsync)
            ;;
        none)
            die "TARANTOOL_WAL_MODE=none is not valid for replicated vshard storage; use write or fsync"
            ;;
        *)
            die "TARANTOOL_WAL_MODE must be write or fsync, got: $TARANTOOL_WAL_MODE"
            ;;
    esac

    local router_port_end
    local storage_port_end

    router_port_end=$((TARANTOOL_ROUTER_HOST_BASE_PORT + ROUTERS - 1))
    storage_port_end=$((TARANTOOL_STORAGE_BASE_PORT + SHARDS * REPLICAS_PER_SHARD - 1))

    if ((TARANTOOL_ROUTER_HOST_BASE_PORT <= storage_port_end && TARANTOOL_STORAGE_BASE_PORT <= router_port_end)); then
        die "router port range ${TARANTOOL_ROUTER_HOST_BASE_PORT}-${router_port_end} overlaps storage port range ${TARANTOOL_STORAGE_BASE_PORT}-${storage_port_end}"
    fi

    if balancer_enabled; then
        if ((TARANTOOL_BALANCER_PORT >= TARANTOOL_ROUTER_HOST_BASE_PORT && TARANTOOL_BALANCER_PORT <= router_port_end)); then
            die "balancer port ${TARANTOOL_BALANCER_PORT} overlaps router port range ${TARANTOOL_ROUTER_HOST_BASE_PORT}-${router_port_end}"
        fi

        if ((TARANTOOL_BALANCER_PORT >= TARANTOOL_STORAGE_BASE_PORT && TARANTOOL_BALANCER_PORT <= storage_port_end)); then
            die "balancer port ${TARANTOOL_BALANCER_PORT} overlaps storage port range ${TARANTOOL_STORAGE_BASE_PORT}-${storage_port_end}"
        fi
    fi
}

compose() {
    docker compose -f "$PROJECT_DIR/docker-compose.yml" "$@"
}

yaml_quote() {
    local value="$1"
    value="${value//\'/\'\'}"
    printf "'%s'" "$value"
}

rs_uuid_for_shard() {
    local shard="$1"
    printf '11111111-1111-4111-8111-%012d' "$shard"
}

instance_index() {
    local shard="$1"
    local replica="$2"
    echo $(((shard - 1) * REPLICAS_PER_SHARD + replica))
}

instance_uuid_for_storage() {
    local shard="$1"
    local replica="$2"
    printf '22222222-2222-4222-8222-%012d' "$(instance_index "$shard" "$replica")"
}

router_replicaset() {
    local router="$1"
    if [[ "$router" == "1" ]]; then
        echo "router-a"
    else
        printf 'router-%d' "$router"
    fi
}

router_instance() {
    local router="$1"
    if [[ "$router" == "1" ]]; then
        echo "$ROUTER_INSTANCE"
    else
        printf 'router-%d-001' "$router"
    fi
}

router_container() {
    local router="$1"
    if [[ "$router" == "1" ]]; then
        echo "$ROUTER_CONTAINER"
    else
        printf 'tarantool-vshard-router-%d' "$router"
    fi
}

router_host_port() {
    local router="$1"
    echo $((TARANTOOL_ROUTER_HOST_BASE_PORT + router - 1))
}

router_host_ports_csv() {
    local router
    local sep=""

    for router in $(seq 1 "$ROUTERS"); do
        printf '%s127.0.0.1:%s' "$sep" "$(router_host_port "$router")"
        sep=","
    done

    echo
}

client_host_addr() {
    if balancer_enabled; then
        printf '127.0.0.1:%s\n' "$TARANTOOL_BALANCER_PORT"
    else
        printf '127.0.0.1:%s\n' "$(router_host_port 1)"
    fi
}

client_container_uri() {
    if balancer_enabled; then
        printf '%s:%s@%s:3301\n' "$TARANTOOL_USER" "$TARANTOOL_PASSWORD" "$BALANCER_CONTAINER"
    else
        printf '%s:%s@127.0.0.1:3301\n' "$TARANTOOL_USER" "$TARANTOOL_PASSWORD"
    fi
}

router_uuid() {
    local router="${1:-1}"
    printf '33333333-3333-4333-8333-%012d' "$router"
}

router_rs_uuid() {
    local router="${1:-1}"
    printf '44444444-4444-4444-8444-%012d' "$router"
}

storage_instance() {
    local shard="$1"
    local replica="$2"
    printf 'storage-s%d-r%d' "$shard" "$replica"
}

storage_container() {
    local shard="$1"
    local replica="$2"
    printf 'tarantool-vshard-storage-%d-%d' "$shard" "$replica"
}

storage_host_port() {
    local shard="$1"
    local replica="$2"
    echo $((TARANTOOL_STORAGE_BASE_PORT + $(instance_index "$shard" "$replica") - 1))
}

prepare_dirs() {
    log "Preparing project dir: $PROJECT_DIR"
    mkdir -p "$PROJECT_DIR/tarantool"
    mkdir -p "$PROJECT_DIR/haproxy"
}

write_config_yaml() {
    log "Writing config.yaml"

    local app_password
    local replication_password
    local sharding_password

    app_password="$(yaml_quote "$TARANTOOL_PASSWORD")"
    replication_password="$(yaml_quote "$TARANTOOL_REPLICATION_PASSWORD")"
    sharding_password="$(yaml_quote "$TARANTOOL_SHARDING_PASSWORD")"

    cat > "$PROJECT_DIR/tarantool/config.yaml" <<EOF
credentials:
  users:
    ${TARANTOOL_REPLICATION_USER}:
      password: ${replication_password}
      roles: [replication]
    ${TARANTOOL_SHARDING_USER}:
      password: ${sharding_password}
      roles: [sharding]
    ${TARANTOOL_USER}:
      password: ${app_password}
      roles: [super]

iproto:
  advertise:
    peer:
      login: ${TARANTOOL_REPLICATION_USER}
      password: ${replication_password}
    sharding:
      login: ${TARANTOOL_SHARDING_USER}
      password: ${sharding_password}

process:
  work_dir: /var/lib/tarantool

memtx:
  memory: ${TARANTOOL_MEMTX_MEMORY}

wal:
  mode: ${TARANTOOL_WAL_MODE}
  dir: /var/lib/tarantool

snapshot:
  dir: /var/lib/tarantool

vinyl:
  dir: /var/lib/tarantool

sharding:
  bucket_count: ${TARANTOOL_VSHARD_BUCKET_COUNT}

groups:
  storages:
    app:
      file: /opt/tarantool/storage.lua
    sharding:
      roles: [storage]
    replication:
      failover: manual
    replicasets:
EOF

    local shard
    local replica

    for shard in $(seq 1 "$SHARDS"); do
        cat >> "$PROJECT_DIR/tarantool/config.yaml" <<EOF
      storage-s${shard}:
        leader: $(storage_instance "$shard" 1)
        database:
          replicaset_uuid: '$(rs_uuid_for_shard "$shard")'
        instances:
EOF

        for replica in $(seq 1 "$REPLICAS_PER_SHARD"); do
            local instance
            local container

            instance="$(storage_instance "$shard" "$replica")"
            container="$(storage_container "$shard" "$replica")"

            cat >> "$PROJECT_DIR/tarantool/config.yaml" <<EOF
          ${instance}:
            database:
              instance_uuid: '$(instance_uuid_for_storage "$shard" "$replica")'
            iproto:
              listen:
              - uri: '0.0.0.0:3301'
              advertise:
                peer:
                  uri: '${container}:3301'
                sharding:
                  uri: '${container}:3301'
                client: '${container}:3301'
EOF
        done
    done

    cat >> "$PROJECT_DIR/tarantool/config.yaml" <<EOF
  routers:
    app:
      file: /opt/tarantool/router.lua
    sharding:
      roles: [router]
    replicasets:
EOF

    local router
    for router in $(seq 1 "$ROUTERS"); do
        cat >> "$PROJECT_DIR/tarantool/config.yaml" <<EOF
      $(router_replicaset "$router"):
        database:
          replicaset_uuid: '$(router_rs_uuid "$router")'
        instances:
          $(router_instance "$router"):
            database:
              instance_uuid: '$(router_uuid "$router")'
            iproto:
              listen:
              - uri: '0.0.0.0:3301'
              advertise:
                client: '$(router_container "$router"):3301'
EOF
    done
}

write_storage_lua() {
    log "Writing storage.lua"

    cat > "$PROJECT_DIR/tarantool/storage.lua" <<'EOF'
local vshard = require('vshard')
local crud = require('crud')
rawset(_G, 'vshard', vshard)

local space_name = os.getenv('TARANTOOL_SPACE') or 'kv'
local sharding_user = os.getenv('TARANTOOL_SHARDING_USER') or 'storage'

local function ensure_space_grants()
    box.schema.user.grant(sharding_user, 'read,write', 'space', space_name, {
        if_not_exists = true
    })
end

local function ensure_function_grants()
    local functions = {
        'put_storage',
        'get_storage',
        'truncate_storage',
    }

    for _, func_name in ipairs(functions) do
        box.schema.func.create(func_name, {
            if_not_exists = true
        })

        box.schema.user.grant(sharding_user, 'execute', 'function', func_name, {
            if_not_exists = true
        })
    end
end

local function ensure_schema()
    if box.info.ro then
        return
    end

    local kv = box.schema.space.create(space_name, {
        if_not_exists = true
    })

    kv:format({
        {name = 'key', type = 'string'},
        {name = 'bucket_id', type = 'unsigned'},
        {name = 'value', type = 'string'}
    })

    kv:create_index('primary', {
        type = 'HASH',
        parts = {
            {field = 'key', type = 'string'}
        },
        if_not_exists = true
    })

    kv:create_index('bucket_id', {
        type = 'TREE',
        parts = {
            {field = 'bucket_id', type = 'unsigned'}
        },
        unique = false,
        if_not_exists = true
    })

    ensure_space_grants()
    ensure_function_grants()
end

box.watch('box.status', ensure_schema)
crud.init_storage({async = true})

rawset(_G, 'put_storage', function(bucket_id, key, value)
    local tuple = box.space[space_name]:replace{key, bucket_id, value}
    return {tuple[1], tuple[3]}
end)

rawset(_G, 'get_storage', function(bucket_id, key)
    local tuple = box.space[space_name]:get{key}
    if tuple == nil then
        return nil
    end
    return {tuple[1], tuple[3]}
end)

rawset(_G, 'truncate_storage', function()
    if box.info.ro then
        error('truncate_storage must be called on a writable storage leader')
    end

    box.space[space_name]:truncate()
    return box.space[space_name]:len()
end)
EOF
}

write_router_lua() {
    log "Writing router.lua"

    cat > "$PROJECT_DIR/tarantool/router.lua" <<'EOF'
local vshard = require('vshard')
local crud = require('crud')
rawset(_G, 'vshard', vshard)

local space_name = os.getenv('TARANTOOL_SPACE') or 'kv'

crud.init_router()

local function bucket_id_for_key(key)
    return vshard.router.bucket_id_mpcrc32(tostring(key))
end

local function call_vshard(bucket_id, mode, func_name, args)
    local result, err = vshard.router.call(bucket_id, mode, func_name, args)
    if err ~= nil then
        if type(err) == 'table' and err.message ~= nil then
            error(err.message)
        end
        error(tostring(err))
    end
    return result
end

rawset(_G, 'put', function(key, value)
    local bucket_id = bucket_id_for_key(key)

    return call_vshard(
        bucket_id,
        'write',
        'put_storage',
        {bucket_id, key, value}
    )
end)

rawset(_G, 'get', function(key)
    local bucket_id = bucket_id_for_key(key)

    return call_vshard(
        bucket_id,
        'read',
        'get_storage',
        {bucket_id, key}
    )
end)

rawset(_G, 'truncate_kv', function()
    local result = {}
    local replicasets, err = vshard.router.routeall()

    if err ~= nil then
        if type(err) == 'table' and err.message ~= nil then
            error(err.message)
        end
        error(tostring(err))
    end

    for _, replicaset in pairs(replicasets) do
        local truncate_result, truncate_err = replicaset:callrw('truncate_storage', {}, {timeout = 10})

        if truncate_err ~= nil then
            if type(truncate_err) == 'table' and truncate_err.message ~= nil then
                error(truncate_err.message)
            end
            error(tostring(truncate_err))
        end

        if truncate_result == nil then
            truncate_result = true
        end

        table.insert(result, truncate_result)
    end

    return result
end)

rawset(_G, 'crud_put', function(key, value)
    local result, err = crud.replace(space_name, {key, box.NULL, value})
    if err ~= nil then
        if type(err) == 'table' and err.message ~= nil then
            error(err.message)
        end
        error(tostring(err))
    end
    return result
end)

rawset(_G, 'crud_get', function(key)
    local result, err = crud.get(space_name, {key})
    if err ~= nil then
        if type(err) == 'table' and err.message ~= nil then
            error(err.message)
        end
        error(tostring(err))
    end
    return result
end)

rawset(_G, 'crud_truncate_kv', function()
    local result, err = crud.truncate(space_name, {timeout = 10})
    if err ~= nil then
        if type(err) == 'table' and err.message ~= nil then
            error(err.message)
        end
        error(tostring(err))
    end
    return result
end)

rawset(_G, 'router_info', function()
    return vshard.router.info({with_services = true})
end)

rawset(_G, 'router_bucket_count', function()
    return vshard.router.bucket_count()
end)
EOF
}

write_start_sh() {
    log "Writing start.sh"

    cat > "$PROJECT_DIR/tarantool/start.sh" <<'EOF'
#!/bin/sh
set -eu

: "${TT_INSTANCE_NAME:?TT_INSTANCE_NAME is required}"

exec tarantool --name "$TT_INSTANCE_NAME" --config "${TT_CONFIG:-/opt/tarantool/config.yaml}"
EOF

    chmod +x "$PROJECT_DIR/tarantool/start.sh"
}

write_dockerfile() {
    log "Writing Dockerfile"

    cat > "$PROJECT_DIR/tarantool/Dockerfile" <<EOF
FROM ${TARANTOOL_BASE_IMAGE}

RUN set -eux; \\
    apt-get update; \\
    apt-get install -y --no-install-recommends \\
        ca-certificates \\
        cmake \\
        g++ \\
        gcc \\
        git \\
        make \\
        unzip; \\
    rm -rf /var/lib/apt/lists/*; \\
    tt rocks install vshard ${TARANTOOL_VSHARD_VERSION}-1; \\
    tt rocks install crud ${TARANTOOL_CRUD_VERSION}-1; \\
    env -u TT_APP_NAME -u TT_INSTANCE_NAME -u TT_CONFIG -u TT_CONFIG_ETCD_ENDPOINTS \\
        tarantool -e "local vshard = require('vshard'); local crud = require('crud'); print('vshard installed', vshard._VERSION); print('crud installed', crud._VERSION)"

COPY config.yaml /opt/tarantool/config.yaml
COPY storage.lua /opt/tarantool/storage.lua
COPY router.lua /opt/tarantool/router.lua
COPY start.sh /usr/local/bin/start-tarantool-vshard

RUN chmod +x /usr/local/bin/start-tarantool-vshard

ENTRYPOINT ["/usr/local/bin/start-tarantool-vshard"]
EOF
}

write_haproxy_cfg() {
    if ! balancer_enabled; then
        return 0
    fi

    log "Writing haproxy.cfg"

    cat > "$PROJECT_DIR/haproxy/haproxy.cfg" <<EOF
global
    log stdout format raw local0
    maxconn 65535

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 3s
    timeout client 60s
    timeout server 60s

frontend tarantool_router_frontend
    bind *:3301
    default_backend tarantool_router_backend

backend tarantool_router_backend
    balance ${TARANTOOL_BALANCER_ALGORITHM}
    option tcp-check
    default-server inter 2s fall 3 rise 2
EOF

    local router
    for router in $(seq 1 "$ROUTERS"); do
        cat >> "$PROJECT_DIR/haproxy/haproxy.cfg" <<EOF
    server router${router} $(router_container "$router"):3301 check
EOF
    done
}

write_router_service() {
    local router="$1"
    local container
    local instance
    local host_port
    local shard
    local replica

    container="$(router_container "$router")"
    instance="$(router_instance "$router")"
    host_port="$(router_host_port "$router")"

    cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
  ${container}:
    build:
      context: ./tarantool
      dockerfile: Dockerfile
    image: ${TARANTOOL_IMAGE}
    container_name: ${container}
    depends_on:
EOF

    for shard in $(seq 1 "$SHARDS"); do
        for replica in $(seq 1 "$REPLICAS_PER_SHARD"); do
            cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
      - $(storage_container "$shard" "$replica")
EOF
        done
    done

    cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
    environment:
      TT_INSTANCE_NAME: ${instance}
      TT_CONFIG: /opt/tarantool/config.yaml
      TARANTOOL_SPACE: ${TARANTOOL_SPACE}
      TARANTOOL_SHARDING_USER: ${TARANTOOL_SHARDING_USER}
    ports:
      - "${host_port}:3301"
    volumes:
      - ${container}-data:/var/lib/tarantool
    networks:
      - ${NETWORK_NAME}
    restart: unless-stopped
    healthcheck:
      test:
        - CMD-SHELL
        - "unset TT_APP_NAME TT_INSTANCE_NAME TT_CONFIG TT_CONFIG_ETCD_ENDPOINTS; tarantool -e 'local socket = require(\"socket\"); local s = socket.tcp_connect(\"127.0.0.1\", 3301, 1); if s then s:close(); os.exit(0) end os.exit(1)'"
      interval: 10s
      timeout: 3s
      retries: 12
      start_period: 10s
    deploy:
      resources:
        limits:
          cpus: "${TARANTOOL_ROUTER_CPU_LIMIT}"
          memory: ${TARANTOOL_MEMORY_LIMIT}

EOF
}

write_balancer_service() {
    if ! balancer_enabled; then
        return 0
    fi

    local router

    cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
  ${BALANCER_CONTAINER}:
    image: ${TARANTOOL_BALANCER_IMAGE}
    container_name: ${BALANCER_CONTAINER}
    depends_on:
EOF

    for router in $(seq 1 "$ROUTERS"); do
        cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
      - $(router_container "$router")
EOF
    done

    cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
    ports:
      - "${TARANTOOL_BALANCER_PORT}:3301"
    volumes:
      - ./haproxy/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    networks:
      - ${NETWORK_NAME}
    restart: unless-stopped
    healthcheck:
      test:
        - CMD-SHELL
        - "echo | nc -w 1 127.0.0.1 3301 >/dev/null 2>&1"
      interval: 10s
      timeout: 3s
      retries: 12
      start_period: 5s
    deploy:
      resources:
        limits:
          cpus: "${TARANTOOL_BALANCER_CPU_LIMIT}"
          memory: ${TARANTOOL_BALANCER_MEMORY_LIMIT}

EOF
}

write_compose() {
    log "Writing docker-compose.yml"

    cat > "$PROJECT_DIR/docker-compose.yml" <<EOF
services:
EOF

    local router
    local shard
    local replica

    for router in $(seq 1 "$ROUTERS"); do
        write_router_service "$router"
    done

    write_balancer_service

    for shard in $(seq 1 "$SHARDS"); do
        for replica in $(seq 1 "$REPLICAS_PER_SHARD"); do
            local container
            local instance
            local host_port

            container="$(storage_container "$shard" "$replica")"
            instance="$(storage_instance "$shard" "$replica")"
            host_port="$(storage_host_port "$shard" "$replica")"

            cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
  ${container}:
    build:
      context: ./tarantool
      dockerfile: Dockerfile
    image: ${TARANTOOL_IMAGE}
    container_name: ${container}
    environment:
      TT_INSTANCE_NAME: ${instance}
      TT_CONFIG: /opt/tarantool/config.yaml
      TARANTOOL_SPACE: ${TARANTOOL_SPACE}
      TARANTOOL_SHARDING_USER: ${TARANTOOL_SHARDING_USER}
    ports:
      - "${host_port}:3301"
    volumes:
      - ${container}-data:/var/lib/tarantool
    networks:
      - ${NETWORK_NAME}
    restart: unless-stopped
    healthcheck:
      test:
        - CMD-SHELL
        - "unset TT_APP_NAME TT_INSTANCE_NAME TT_CONFIG TT_CONFIG_ETCD_ENDPOINTS; tarantool -e 'local socket = require(\"socket\"); local s = socket.tcp_connect(\"127.0.0.1\", 3301, 1); if s then s:close(); os.exit(0) end os.exit(1)'"
      interval: 10s
      timeout: 3s
      retries: 12
      start_period: 10s
    deploy:
      resources:
        limits:
          cpus: "${TARANTOOL_STORAGE_CPU_LIMIT}"
          memory: ${TARANTOOL_MEMORY_LIMIT}

EOF
        done
    done

    cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
networks:
  ${NETWORK_NAME}:
    driver: bridge

volumes:
EOF

    local router
    for router in $(seq 1 "$ROUTERS"); do
        cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
  $(router_container "$router")-data:
EOF
    done

    for shard in $(seq 1 "$SHARDS"); do
        for replica in $(seq 1 "$REPLICAS_PER_SHARD"); do
            cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
  $(storage_container "$shard" "$replica")-data:
EOF
        done
    done
}

write_files() {
    prepare_dirs
    write_config_yaml
    write_storage_lua
    write_router_lua
    write_start_sh
    write_dockerfile
    write_haproxy_cfg
    write_compose
}

down() {
    if [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then
        log "Stopping compose project"

        if is_true "$KEEP_DATA"; then
            compose down --remove-orphans || true
        else
            compose down -v --remove-orphans || true
        fi
    fi

    docker rm -f "$BALANCER_CONTAINER" 2>/dev/null || true

    local router
    for router in $(seq 1 16); do
        docker rm -f "$(router_container "$router")" 2>/dev/null || true
    done

    docker rm -f tarantool-vshard-storage-1 2>/dev/null || true
    docker rm -f tarantool-vshard-storage-2 2>/dev/null || true

    local shard
    local replica
    for shard in $(seq 1 "$SHARDS"); do
        for replica in $(seq 1 "$REPLICAS_PER_SHARD"); do
            docker rm -f "$(storage_container "$shard" "$replica")" 2>/dev/null || true
        done
    done
}

build() {
    log "Building image"

    if is_true "$BUILD_NO_CACHE"; then
        compose build --no-cache
    else
        compose build
    fi
}

up() {
    log "Starting cluster"
    compose up -d --force-recreate
}

wait_container() {
    local container="$1"

    for _ in $(seq 1 60); do
        if docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -q true; then
            echo "Container is running: $container"
            return 0
        fi

        sleep 1
    done

    echo "Container did not start: $container"
    docker logs "$container" || true
    return 1
}

wait_tarantool() {
    local container="$1"
    local uri="$2"

    for _ in $(seq 1 90); do
        if docker exec "$container" sh -c "
            unset TT_APP_NAME TT_INSTANCE_NAME TT_CONFIG TT_CONFIG_ETCD_ENDPOINTS
            tarantool -e '
                local net_box = require(\"net.box\")
                local c = net_box.connect(\"${uri}\", {wait_connected = false})

                if c:wait_connected(1) then
                    c:close()
                    os.exit(0)
                end

                os.exit(1)
            '
        " >/dev/null 2>&1; then
            echo "Tarantool is ready: $container"
            return 0
        fi

        sleep 1
    done

    echo "Tarantool did not become ready: $container"
    docker logs "$container" --tail=160 || true
    return 1
}

bootstrap_vshard() {
    log "Bootstrapping vshard buckets"

    for _ in $(seq 1 60); do
        if docker exec "$ROUTER_CONTAINER" sh -c "
            unset TT_APP_NAME TT_INSTANCE_NAME TT_CONFIG TT_CONFIG_ETCD_ENDPOINTS
            tarantool -e '
                local net_box = require(\"net.box\")
                local c = net_box.connect(\"$(client_container_uri)\")
                assert(c:wait_connected(5))
                c:eval([[
                    local vshard = require(\"vshard\")
                    local ok, err = vshard.router.bootstrap({
                        timeout = 10,
                        if_not_bootstrapped = true
                    })
                    if not ok and err ~= nil then
                        if type(err) == \"table\" and err.message ~= nil then
                            error(err.message)
                        end
                        error(tostring(err))
                    end
                    if vshard.router.discovery_wakeup ~= nil then
                        vshard.router.discovery_wakeup()
                    end
                    return ok
                ]])
                c:close()
            '
        " >/dev/null 2>&1; then
            echo "vshard bootstrap completed or already done."
            return 0
        fi

        sleep 1
    done

    echo "vshard bootstrap failed"
    docker logs "$ROUTER_CONTAINER" --tail=160 || true
    return 1
}

wait_router_green() {
    local container="${1:-$ROUTER_CONTAINER}"

    log "Checking router info: $container"

    local attempt
    for attempt in $(seq 1 60); do
        if docker exec "$container" sh -c "
            unset TT_APP_NAME TT_INSTANCE_NAME TT_CONFIG TT_CONFIG_ETCD_ENDPOINTS
            tarantool -e '
                local net_box = require(\"net.box\")
                local json = require(\"json\")

                local c = net_box.connect(\"$(client_container_uri)\")
                assert(c:wait_connected(5))

                local state = c:eval([[
                    local vshard = require(\"vshard\")

                    if vshard.router.discovery_wakeup ~= nil then
                        vshard.router.discovery_wakeup()
                    end

                    local info = vshard.router.info({with_services = true})
                    return {
                        bucket_count = vshard.router.bucket_count(),
                        info = info,
                    }
                ]])

                local info = state.info

                assert(info.status == 0, \"vshard router status is not green\")
                assert(#info.alerts == 0, \"vshard router has alerts\")
                assert(info.bucket.available_rw == ${TARANTOOL_VSHARD_BUCKET_COUNT}, \"not all buckets are rw-available\")
                assert(info.bucket.unknown == 0, \"vshard router still has unknown buckets\")

                print(json.encode(state))
                c:close()
            '
        " >/tmp/tarantool-router-info.json 2>/tmp/tarantool-router-info.err; then
            cat /tmp/tarantool-router-info.json
            return 0
        fi

        sleep 1
    done

    echo "vshard router did not become green"
    cat /tmp/tarantool-router-info.err 2>/dev/null || true
    cat /tmp/tarantool-router-info.json 2>/dev/null || true
    docker logs "$container" --tail=160 || true
    return 1
}

verify_storage() {
    local shard="$1"
    local replica="$2"
    local container
    local expected_rs_uuid
    local expected_instance_uuid
    local expected_ro

    container="$(storage_container "$shard" "$replica")"
    expected_rs_uuid="$(rs_uuid_for_shard "$shard")"
    expected_instance_uuid="$(instance_uuid_for_storage "$shard" "$replica")"

    if [[ "$replica" == "1" ]]; then
        expected_ro="false"
    else
        expected_ro="true"
    fi

    docker exec "$container" sh -c "
        unset TT_APP_NAME TT_INSTANCE_NAME TT_CONFIG TT_CONFIG_ETCD_ENDPOINTS
        tarantool -e '
            local net_box = require(\"net.box\")
            local json = require(\"json\")

            local c = net_box.connect(\"${TARANTOOL_USER}:${TARANTOOL_PASSWORD}@${container}:3301\")
            assert(c:wait_connected(5))

            local state = c:eval([[
                local vshard = require(\"vshard\")
                local space = box.space[\"${TARANTOOL_SPACE}\"]
                local sharded = vshard.storage.sharded_spaces()
                return {
                    uuid = box.info.uuid,
                    replicaset_uuid = box.info.replicaset.uuid,
                    ro = box.info.ro,
                    storage_status = vshard.storage.info({with_services = true}).status,
                    has_vshard_func = box.func[\"vshard.storage.rebalancer_request_state\"] ~= nil,
                    has_space = space ~= nil,
                    has_bucket_index = space ~= nil and space.index.bucket_id ~= nil,
                    is_sharded_space = next(sharded) ~= nil,
                }
            ]])

            print(json.encode(state))
            assert(state.uuid == \"${expected_instance_uuid}\", \"unexpected instance uuid\")
            assert(state.replicaset_uuid == \"${expected_rs_uuid}\", \"unexpected replicaset uuid\")
            assert(tostring(state.ro) == \"${expected_ro}\", \"unexpected read-only mode\")
            assert(state.storage_status == 0, \"vshard storage status is not green\")
            assert(state.has_vshard_func == true, \"vshard storage function not found\")
            assert(state.has_space == true, \"benchmark space not found\")
            assert(state.has_bucket_index == true, \"bucket_id index not found\")
            assert(state.is_sharded_space == true, \"space is not detected as sharded\")

            c:close()
        '
    "
}

verify() {
    log "Verifying containers"

    local router
    for router in $(seq 1 "$ROUTERS"); do
        wait_container "$(router_container "$router")"
    done

    if balancer_enabled; then
        wait_container "$BALANCER_CONTAINER"
    fi

    local shard
    local replica
    for shard in $(seq 1 "$SHARDS"); do
        for replica in $(seq 1 "$REPLICAS_PER_SHARD"); do
            wait_container "$(storage_container "$shard" "$replica")"
        done
    done

    log "Verifying Tarantool connections"

    for router in $(seq 1 "$ROUTERS"); do
        local router_container_name
        router_container_name="$(router_container "$router")"
        wait_tarantool "$router_container_name" "${TARANTOOL_USER}:${TARANTOOL_PASSWORD}@127.0.0.1:3301"
    done

    for shard in $(seq 1 "$SHARDS"); do
        for replica in $(seq 1 "$REPLICAS_PER_SHARD"); do
            local container
            container="$(storage_container "$shard" "$replica")"
            wait_tarantool "$container" "${TARANTOOL_USER}:${TARANTOOL_PASSWORD}@${container}:3301"
        done
    done

    bootstrap_vshard

    for router in $(seq 1 "$ROUTERS"); do
        wait_router_green "$(router_container "$router")"
    done

    if balancer_enabled; then
        log "Verifying router proxy endpoint"
        wait_tarantool "$ROUTER_CONTAINER" "$(client_container_uri)"
    fi

    log "Checking storage nodes"

    for shard in $(seq 1 "$SHARDS"); do
        for replica in $(seq 1 "$REPLICAS_PER_SHARD"); do
            verify_storage "$shard" "$replica"
        done
    done
}

test_cluster() {
    verify

    log "Testing put/get through router"

    docker exec "$ROUTER_CONTAINER" sh -c "
        unset TT_APP_NAME TT_INSTANCE_NAME TT_CONFIG TT_CONFIG_ETCD_ENDPOINTS
        tarantool -e '
            local net_box = require(\"net.box\")
            local json = require(\"json\")

            local c = net_box.connect(\"${TARANTOOL_USER}:${TARANTOOL_PASSWORD}@127.0.0.1:3301\")
            assert(c:wait_connected(5))

            c:call(\"truncate_kv\", {})

            local put_result = c:call(\"put\", {\"key1\", \"value1\"})
            local get_result = c:call(\"get\", {\"key1\"})

            print(\"put=\" .. json.encode(put_result))
            print(\"get=\" .. json.encode(get_result))

            assert(get_result[1] == \"key1\", \"unexpected key\")
            assert(get_result[2] == \"value1\", \"unexpected value\")

            c:close()
        '
    "

    log "Testing CRUD put/get through router"

    docker exec "$ROUTER_CONTAINER" sh -c "
        unset TT_APP_NAME TT_INSTANCE_NAME TT_CONFIG TT_CONFIG_ETCD_ENDPOINTS
        tarantool -e '
            local net_box = require(\"net.box\")
            local json = require(\"json\")

            local c = net_box.connect(\"${TARANTOOL_USER}:${TARANTOOL_PASSWORD}@127.0.0.1:3301\")
            assert(c:wait_connected(5))

            c:call(\"crud_truncate_kv\", {})

            local put_result = c:call(\"crud_put\", {\"crud_key1\", \"crud_value1\"})
            local get_result = c:call(\"crud_get\", {\"crud_key1\"})

            print(\"crud_put=\" .. json.encode(put_result))
            print(\"crud_get=\" .. json.encode(get_result))

            assert(get_result.rows[1][1] == \"crud_key1\", \"unexpected CRUD key\")
            assert(get_result.rows[1][3] == \"crud_value1\", \"unexpected CRUD value\")

            c:close()
        '
    "

    log "Testing CRUD read through all routers"

    local router
    for router in $(seq 1 "$ROUTERS"); do
        local router_container_name
        router_container_name="$(router_container "$router")"

        docker exec "$router_container_name" sh -c "
            unset TT_APP_NAME TT_INSTANCE_NAME TT_CONFIG TT_CONFIG_ETCD_ENDPOINTS
            tarantool -e '
                local net_box = require(\"net.box\")
                local json = require(\"json\")

                local c = net_box.connect(\"${TARANTOOL_USER}:${TARANTOOL_PASSWORD}@127.0.0.1:3301\")
                assert(c:wait_connected(5))

                local get_result = c:call(\"crud_get\", {\"crud_key1\"})
                print(\"$(router_container "$router") crud_get=\" .. json.encode(get_result))

                assert(get_result.rows[1][1] == \"crud_key1\", \"unexpected CRUD key\")
                assert(get_result.rows[1][3] == \"crud_value1\", \"unexpected CRUD value\")

                c:close()
            '
        "
    done

    echo "Tarantool vshard and CRUD put/get tests passed."
}

logs() {
    if [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then
        compose ps || true
    fi

    if balancer_enabled; then
        echo
        docker logs "$BALANCER_CONTAINER" --tail=160 || true
    fi

    local router
    for router in $(seq 1 "$ROUTERS"); do
        echo
        docker logs "$(router_container "$router")" --tail=160 || true
    done

    local shard
    local replica
    for shard in $(seq 1 "$SHARDS"); do
        for replica in $(seq 1 "$REPLICAS_PER_SHARD"); do
            echo
            docker logs "$(storage_container "$shard" "$replica")" --tail=160 || true
        done
    done
}

deploy() {
    validate

    if ! is_true "$KEEP_DATA"; then
        down
    fi

    write_files
    build
    up
    verify

    print_summary
}

clean() {
    KEEP_DATA=0 down
    rm -rf "$PROJECT_DIR"
}

print_summary() {
    log "Summary"

    compose ps

    cat <<EOF

Tarantool vshard cluster is ready.

Project:
  ${PROJECT_DIR}

Client endpoint:
  addr:     $(client_host_addr)
  proxy:    $(balancer_enabled && echo "enabled (${BALANCER_CONTAINER}, ${TARANTOOL_BALANCER_ALGORITHM})" || echo "disabled")
  user:     ${TARANTOOL_USER}
  password: ${TARANTOOL_PASSWORD}

Routers:
  host addrs: $(router_host_ports_csv)
  cpu each: ${TARANTOOL_ROUTER_CPU_LIMIT}
EOF

    local router
    for router in $(seq 1 "$ROUTERS"); do
        cat <<EOF
  router ${router}: localhost:$(router_host_port "$router"), container: $(router_container "$router"), instance: $(router_instance "$router")
EOF
    done

    cat <<EOF
Storage:
EOF

    local shard
    local replica
    for shard in $(seq 1 "$SHARDS"); do
        cat <<EOF
  shard ${shard}: replicaset storage-s${shard}, leader $(storage_instance "$shard" 1), uuid $(rs_uuid_for_shard "$shard")
EOF
        for replica in $(seq 1 "$REPLICAS_PER_SHARD"); do
            cat <<EOF
    replica ${replica}: localhost:$(storage_host_port "$shard" "$replica"), container: $(storage_container "$shard" "$replica"), cpu: ${TARANTOOL_STORAGE_CPU_LIMIT}
EOF
        done
    done

    cat <<EOF

Commands:
  ./$(basename "$0") test
  ./$(basename "$0") logs
  ./$(basename "$0") down
  ./$(basename "$0") clean

Connect router:
  docker exec -it ${ROUTER_CONTAINER} tt connect 127.0.0.1:3301 -u ${TARANTOOL_USER} -p ${TARANTOOL_PASSWORD}

Run benchmark through client endpoint:
  TARANTOOL_MODE=crud TARANTOOL_ADDR=$(client_host_addr) TARGET=tarantool ./scripts/run_benchmarks.sh

Connect storage leader of shard 1:
  docker exec -it $(storage_container 1 1) tt connect $(storage_container 1 1):3301 -u ${TARANTOOL_USER} -p ${TARANTOOL_PASSWORD}
EOF
}

usage() {
    cat <<EOF
Usage:
  $0 deploy      Generate files, build, start and verify
  $0 write       Generate files only
  $0 build       Build image
  $0 up          Start containers
  $0 verify      Verify cluster
  $0 test        Verify and run put/get test
  $0 logs        Show logs
  $0 down        Stop containers, remove volumes unless KEEP_DATA=1
  $0 clean       Stop containers and remove generated project dir

Examples:
  SHARDS=2 REPLICAS_PER_SHARD=2 $0 deploy
  ROUTERS=3 SHARDS=4 REPLICAS_PER_SHARD=2 TARANTOOL_ROUTER_CPU_LIMIT=4.0 $0 deploy
  KEEP_DATA=1 $0 down
EOF
}

cmd="${1:-deploy}"

case "$cmd" in
    deploy)
        deploy
        ;;
    write)
        validate
        write_files
        ;;
    build)
        validate
        build
        ;;
    up)
        validate
        up
        ;;
    verify)
        validate
        verify
        ;;
    test)
        validate
        test_cluster
        ;;
    logs)
        validate
        logs
        ;;
    down)
        validate
        down
        ;;
    clean)
        validate
        clean
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        echo "Unknown command: $cmd" >&2
        usage >&2
        exit 1
        ;;
esac
