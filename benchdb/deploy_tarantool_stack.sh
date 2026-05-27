#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-deploy}"

PROJECT_DIR="${PROJECT_DIR:-tarantool-stack}"
NETWORK_NAME="${NETWORK_NAME:-db-net}"

TARANTOOL_MODE="${TARANTOOL_MODE:-single}"
TARANTOOL_BASE_IMAGE="${TARANTOOL_BASE_IMAGE:-tarantool/tarantool:3}"
TARANTOOL_IMAGE="${TARANTOOL_IMAGE:-local-tarantool-single:3}"
TARANTOOL_CONTAINER="${TARANTOOL_CONTAINER:-tarantool-single-node}"
TARANTOOL_PORT="${TARANTOOL_PORT:-3301}"
TARANTOOL_USER="${TARANTOOL_USER:-app}"
TARANTOOL_PASSWORD="${TARANTOOL_PASSWORD:-app_pass}"
TARANTOOL_SPACE="${TARANTOOL_SPACE:-kv}"
TARANTOOL_MEMTX_MEMORY="${TARANTOOL_MEMTX_MEMORY:-4294967296}"
TARANTOOL_WAL_MODE="${TARANTOOL_WAL_MODE:-none}"
TARANTOOL_READAHEAD="${TARANTOOL_READAHEAD:-104857600}"
TARANTOOL_NET_MSG_MAX="${TARANTOOL_NET_MSG_MAX:-1048576}"
TARANTOOL_CPU_LIMIT="${TARANTOOL_CPU_LIMIT:-0.5}"
TARANTOOL_VSHARD_IMAGE="${TARANTOOL_VSHARD_IMAGE:-local-tarantool-vshard:3}"
TARANTOOL_VSHARD_VERSION="${TARANTOOL_VSHARD_VERSION:-0.1.40}"
TARANTOOL_CRUD_VERSION="${TARANTOOL_CRUD_VERSION:-1.7.4}"
TARANTOOL_ROUTERS="${TARANTOOL_ROUTERS:-1}"
TARANTOOL_SHARDS="${TARANTOOL_SHARDS:-2}"
TARANTOOL_REPLICAS_PER_SHARD="${TARANTOOL_REPLICAS_PER_SHARD:-2}"
TARANTOOL_VSHARD_BUCKET_COUNT="${TARANTOOL_VSHARD_BUCKET_COUNT:-3000}"
TARANTOOL_STORAGE_BASE_PORT="${TARANTOOL_STORAGE_BASE_PORT:-3401}"
TARANTOOL_VSHARD_WAL_MODE="${TARANTOOL_VSHARD_WAL_MODE:-write}"
TARANTOOL_SHARDING_USER="${TARANTOOL_SHARDING_USER:-storage}"
TARANTOOL_SHARDING_PASSWORD="${TARANTOOL_SHARDING_PASSWORD:-storage_pass}"
TARANTOOL_REPLICATION_USER="${TARANTOOL_REPLICATION_USER:-replicator}"
TARANTOOL_REPLICATION_PASSWORD="${TARANTOOL_REPLICATION_PASSWORD:-replicator_pass}"
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

down_existing() {
    if [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then
        log "Stopping old Tarantool stack"
        compose down -v --remove-orphans 2>/dev/null || true
    fi

    docker rm -f "$TARANTOOL_CONTAINER" 2>/dev/null || true
    for ((i = 1; i <= TARANTOOL_ROUTERS; i++)); do
        docker rm -f "tarantool-vshard-router-$i" 2>/dev/null || true
    done
    for ((i = 1; i <= TARANTOOL_SHARDS; i++)); do
        docker rm -f "tarantool-vshard-storage-$i" 2>/dev/null || true
        for ((j = 1; j <= TARANTOOL_REPLICAS_PER_SHARD; j++)); do
            docker rm -f "tarantool-vshard-storage-$i-$j" 2>/dev/null || true
        done
    done

    local project_name
    project_name="$(basename "$PROJECT_DIR")"
    docker volume rm -f "${project_name}_tarantool-data" 2>/dev/null || true
    docker volume rm -f "benchdb_tarantool-data" 2>/dev/null || true
}

prepare_single_files() {
    log "Preparing Tarantool files in $PROJECT_DIR"
    rm -rf "$PROJECT_DIR"
    mkdir -p "$PROJECT_DIR/tarantool"

    cat > "$PROJECT_DIR/tarantool/Dockerfile" <<EOF
FROM ${TARANTOOL_BASE_IMAGE}
COPY init.lua /opt/tarantool/init.lua
ENTRYPOINT []
CMD ["sh", "-c", "unset TT_APP_NAME TT_INSTANCE_NAME TT_CONFIG TT_CONFIG_ETCD_ENDPOINTS; exec tarantool /opt/tarantool/init.lua"]
EOF

    cat > "$PROJECT_DIR/tarantool/init.lua" <<'EOF'
local space_name = os.getenv('TARANTOOL_SPACE') or 'kv'
local app_user = os.getenv('TARANTOOL_USER') or 'app'
local app_password = os.getenv('TARANTOOL_PASSWORD') or 'app_pass'
local memtx_memory = tonumber(os.getenv('TARANTOOL_MEMTX_MEMORY') or tostring(4 * 1024 * 1024 * 1024))
local wal_mode = os.getenv('TARANTOOL_WAL_MODE') or 'none'
local readahead = tonumber(os.getenv('TARANTOOL_READAHEAD') or tostring(100 * 1024 * 1024))
local net_msg_max = tonumber(os.getenv('TARANTOOL_NET_MSG_MAX') or tostring(1024 * 1024))

box.cfg({
    listen = '0.0.0.0:3301',
    memtx_memory = memtx_memory,
    wal_mode = wal_mode,
    readahead = readahead,
    net_msg_max = net_msg_max,
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

local function ensure_schema()
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
end

ensure_schema()

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
      TARANTOOL_READAHEAD: "${TARANTOOL_READAHEAD}"
      TARANTOOL_NET_MSG_MAX: "${TARANTOOL_NET_MSG_MAX}"
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

vshard_rs_uuid() {
    printf '11111111-1111-4111-8111-%012d' "$1"
}

vshard_instance_uuid() {
    printf '22222222-2222-4222-8222-%06d%06d' "$1" "$2"
}

vshard_router_rs_uuid() {
    printf '44444444-4444-4444-8444-%012d' "$1"
}

vshard_router_uuid() {
    printf '33333333-3333-4333-8333-%012d' "$1"
}

vshard_storage_service() {
    printf 'storage-%d-%d' "$1" "$2"
}

vshard_storage_container() {
    printf 'tarantool-vshard-storage-%d-%d' "$1" "$2"
}

vshard_storage_port() {
    local shard="$1"
    local replica="$2"
    echo $((TARANTOOL_STORAGE_BASE_PORT + (shard - 1) * TARANTOOL_REPLICAS_PER_SHARD + replica - 1))
}

vshard_replication_uri_for_node() {
    local shard="$1"
    local replica="$2"
    local master_service

    if [[ "$replica" -eq 1 ]]; then
        echo ""
        return 0
    fi

    master_service="$(vshard_storage_service "$shard" 1)"
    echo "${TARANTOOL_REPLICATION_USER}:${TARANTOOL_REPLICATION_PASSWORD}@${master_service}:3301"
}

append_limits() {
    cat <<EOF
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
EOF
}

write_vshard_cfg() {
    local cfg="$PROJECT_DIR/tarantool/vshard_cfg.lua"

    cat > "$cfg" <<EOF
return {
    bucket_count = ${TARANTOOL_VSHARD_BUCKET_COUNT},
    sharding = {
EOF

    for ((shard = 1; shard <= TARANTOOL_SHARDS; shard++)); do
        local rs_uuid
        rs_uuid="$(vshard_rs_uuid "$shard")"
        cat >> "$cfg" <<EOF
        ['${rs_uuid}'] = {
            replicas = {
EOF
        for ((replica = 1; replica <= TARANTOOL_REPLICAS_PER_SHARD; replica++)); do
            local instance_uuid service master_flag
            instance_uuid="$(vshard_instance_uuid "$shard" "$replica")"
            service="$(vshard_storage_service "$shard" "$replica")"
            master_flag="false"
            if [[ "$replica" -eq 1 ]]; then
                master_flag="true"
            fi
            cat >> "$cfg" <<EOF
                ['${instance_uuid}'] = {
                    uri = '${TARANTOOL_SHARDING_USER}:${TARANTOOL_SHARDING_PASSWORD}@${service}:3301',
                    name = '${service}',
                    master = ${master_flag},
                },
EOF
        done
        cat >> "$cfg" <<EOF
            },
        },
EOF
    done

    cat >> "$cfg" <<'EOF'
    },
}
EOF
}

prepare_vshard_files() {
    log "Preparing Tarantool vshard files in $PROJECT_DIR"
    rm -rf "$PROJECT_DIR"
    mkdir -p "$PROJECT_DIR/tarantool"

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
    env -u TT_APP_NAME -u TT_INSTANCE_NAME -u TT_CONFIG -u TT_CONFIG_ETCD_ENDPOINTS \\
        tarantool -e "local vshard = require('vshard'); print('vshard installed', vshard._VERSION)"

COPY router.lua /opt/tarantool/router.lua
COPY storage.lua /opt/tarantool/storage.lua
COPY vshard_cfg.lua /opt/tarantool/vshard_cfg.lua
ENTRYPOINT []
CMD ["sh", "-c", "unset TT_APP_NAME TT_INSTANCE_NAME TT_CONFIG TT_CONFIG_ETCD_ENDPOINTS; exec tarantool /opt/tarantool/\${TARANTOOL_ROLE}.lua"]
EOF

    write_vshard_cfg

    cat > "$PROJECT_DIR/tarantool/storage.lua" <<'EOF'
local vshard = require('vshard')
local cfg = require('vshard_cfg')

local space_name = os.getenv('TARANTOOL_SPACE') or 'kv'
local app_user = os.getenv('TARANTOOL_USER') or 'app'
local app_password = os.getenv('TARANTOOL_PASSWORD') or 'app_pass'
local sharding_user = os.getenv('TARANTOOL_SHARDING_USER') or 'storage'
local sharding_password = os.getenv('TARANTOOL_SHARDING_PASSWORD') or 'storage_pass'
local replication_user = os.getenv('TARANTOOL_REPLICATION_USER') or 'replicator'
local replication_password = os.getenv('TARANTOOL_REPLICATION_PASSWORD') or 'replicator_pass'
local replication = os.getenv('TARANTOOL_REPLICATION') or ''
local replica_index = tonumber(os.getenv('TARANTOOL_REPLICA_INDEX') or '1')
local instance_uuid = assert(os.getenv('TARANTOOL_INSTANCE_UUID'), 'TARANTOOL_INSTANCE_UUID is required')
local replicaset_uuid = assert(os.getenv('TARANTOOL_REPLICASET_UUID'), 'TARANTOOL_REPLICASET_UUID is required')
local memtx_memory = tonumber(os.getenv('TARANTOOL_MEMTX_MEMORY') or tostring(4 * 1024 * 1024 * 1024))
local wal_mode = os.getenv('TARANTOOL_WAL_MODE') or 'write'
local readahead = tonumber(os.getenv('TARANTOOL_READAHEAD') or tostring(100 * 1024 * 1024))
local net_msg_max = tonumber(os.getenv('TARANTOOL_NET_MSG_MAX') or tostring(1024 * 1024))

local function split_csv(value)
    local result = {}
    for item in string.gmatch(value, '([^,]+)') do
        table.insert(result, item)
    end
    return result
end

box.cfg({
    listen = '0.0.0.0:3301',
    instance_uuid = instance_uuid,
    replicaset_uuid = replicaset_uuid,
    memtx_memory = memtx_memory,
    wal_mode = wal_mode,
    readahead = readahead,
    net_msg_max = net_msg_max,
    replication = split_csv(replication),
    bootstrap_strategy = 'legacy',
    replication_timeout = 0.5,
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

local function grant_role(user, role)
    local ok, err = pcall(function()
        box.schema.user.grant(user, role, nil, nil, {
            if_not_exists = true,
        })
    end)

    if not ok and not tostring(err):match('Duplicate') and not tostring(err):match('already') then
        error(err)
    end
end

local function ensure_function_grants(user)
    local functions = {
        'put_storage',
        'get_storage',
        'truncate_storage',
    }

    for _, func_name in ipairs(functions) do
        box.schema.func.create(func_name, {
            if_not_exists = true,
        })
        grant_user(user, 'execute', 'function', func_name)
    end
end

if replica_index == 1 then
    box.schema.user.create(app_user, {
        password = app_password,
        if_not_exists = true,
    })
    grant_user(app_user, 'read', 'universe', nil)
    grant_user(app_user, 'write', 'universe', nil)
    grant_user(app_user, 'execute', 'universe', nil)

    box.schema.user.create(sharding_user, {
        password = sharding_password,
        if_not_exists = true,
    })

    box.schema.user.create(replication_user, {
        password = replication_password,
        if_not_exists = true,
    })
    grant_role(replication_user, 'replication')

    local kv = box.schema.space.create(space_name, {
        if_not_exists = true,
    })
    kv:format({
        {name = 'key', type = 'string'},
        {name = 'bucket_id', type = 'unsigned'},
        {name = 'value', type = 'string'},
    })
    kv:create_index('primary', {
        type = 'TREE',
        parts = {
            {field = 1, type = 'string'},
        },
        if_not_exists = true,
    })
    kv:create_index('bucket_id', {
        type = 'TREE',
        parts = {
            {field = 2, type = 'unsigned'},
        },
        unique = false,
        if_not_exists = true,
    })

    grant_user(sharding_user, 'read,write', 'space', space_name)
    ensure_function_grants(sharding_user)
else
    local fiber = require('fiber')
    for _ = 1, 120 do
        if box.space[space_name] ~= nil and box.space[space_name].index.bucket_id ~= nil and box.schema.user.exists(sharding_user) then
            break
        end
        fiber.sleep(0.5)
    end
    if box.space[space_name] == nil then
        error(('space %s was not replicated to replica'):format(space_name))
    end
end

vshard.storage.cfg(cfg, instance_uuid)

rawset(_G, 'put_storage', function(bucket_id, key, value)
    return box.space[space_name]:replace{key, bucket_id, value}
end)

rawset(_G, 'get_storage', function(bucket_id, key)
    return box.space[space_name]:get{key}
end)

rawset(_G, 'truncate_storage', function()
    box.space[space_name]:truncate()
    return box.space[space_name]:len()
end)
EOF

    cat > "$PROJECT_DIR/tarantool/router.lua" <<'EOF'
local fiber = require('fiber')
local vshard = require('vshard')
local cfg = require('vshard_cfg')

local app_user = os.getenv('TARANTOOL_USER') or 'app'
local app_password = os.getenv('TARANTOOL_PASSWORD') or 'app_pass'
local memtx_memory = tonumber(os.getenv('TARANTOOL_MEMTX_MEMORY') or tostring(4 * 1024 * 1024 * 1024))
local wal_mode = os.getenv('TARANTOOL_WAL_MODE') or 'none'
local readahead = tonumber(os.getenv('TARANTOOL_READAHEAD') or tostring(100 * 1024 * 1024))
local net_msg_max = tonumber(os.getenv('TARANTOOL_NET_MSG_MAX') or tostring(1024 * 1024))

box.cfg({
    listen = '0.0.0.0:3301',
    memtx_memory = memtx_memory,
    wal_mode = wal_mode,
    readahead = readahead,
    net_msg_max = net_msg_max,
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

box.schema.user.create(app_user, {
    password = app_password,
    if_not_exists = true,
})
grant_user(app_user, 'read', 'universe', nil)
grant_user(app_user, 'write', 'universe', nil)
grant_user(app_user, 'execute', 'universe', nil)

vshard.router.cfg(cfg)

local function bucket_id_for_key(key)
    return vshard.router.bucket_id_strcrc32(tostring(key))
end

rawset(_G, 'bucket_id_for_key', bucket_id_for_key)

rawset(_G, 'put', function(key, value)
    local bucket_id = bucket_id_for_key(key)
    return vshard.router.callrw(bucket_id, 'put_storage', {bucket_id, key, value})
end)

rawset(_G, 'get', function(key)
    local bucket_id = bucket_id_for_key(key)
    return vshard.router.callro(bucket_id, 'get_storage', {bucket_id, key})
end)

rawset(_G, 'truncate_kv', function()
    for _, replicaset in pairs(vshard.router.static.replicasets) do
        replicaset:callrw('truncate_storage', {})
    end
    return true
end)

rawset(_G, 'vshard_info', function()
    return vshard.router.info()
end)

fiber.create(function()
    fiber.name('vshard_bootstrapper')
    while true do
        local ok = pcall(function()
            vshard.router.bootstrap({timeout = 2, if_not_bootstrapped = true})
        end)
        if ok then
            return
        end
        fiber.sleep(1)
    end
end)
EOF

    cat > "$PROJECT_DIR/docker-compose.yml" <<EOF
services:
EOF

    for ((router = 1; router <= TARANTOOL_ROUTERS; router++)); do
        local host_port=$((TARANTOOL_PORT + router - 1))
        cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
  router-${router}:
    build:
      context: ./tarantool
      dockerfile: Dockerfile
    image: ${TARANTOOL_VSHARD_IMAGE}
    container_name: tarantool-vshard-router-${router}
    environment:
      TARANTOOL_ROLE: router
      TARANTOOL_USER: ${TARANTOOL_USER}
      TARANTOOL_PASSWORD: ${TARANTOOL_PASSWORD}
      TARANTOOL_MEMTX_MEMORY: "${TARANTOOL_MEMTX_MEMORY}"
      TARANTOOL_WAL_MODE: ${TARANTOOL_WAL_MODE}
      TARANTOOL_READAHEAD: "${TARANTOOL_READAHEAD}"
      TARANTOOL_NET_MSG_MAX: "${TARANTOOL_NET_MSG_MAX}"
    ports:
      - "${host_port}:3301"
    volumes:
      - router-${router}-data:/var/lib/tarantool
    networks:
      - ${NETWORK_NAME}
    depends_on:
EOF
        for ((shard = 1; shard <= TARANTOOL_SHARDS; shard++)); do
            for ((replica = 1; replica <= TARANTOOL_REPLICAS_PER_SHARD; replica++)); do
                local service
                service="$(vshard_storage_service "$shard" "$replica")"
                cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
      - ${service}
EOF
            done
        done
        append_limits >> "$PROJECT_DIR/docker-compose.yml"
    done

    for ((shard = 1; shard <= TARANTOOL_SHARDS; shard++)); do
        for ((replica = 1; replica <= TARANTOOL_REPLICAS_PER_SHARD; replica++)); do
            local host_port service container rs_uuid instance_uuid replication_uri
            host_port="$(vshard_storage_port "$shard" "$replica")"
            service="$(vshard_storage_service "$shard" "$replica")"
            container="$(vshard_storage_container "$shard" "$replica")"
            rs_uuid="$(vshard_rs_uuid "$shard")"
            instance_uuid="$(vshard_instance_uuid "$shard" "$replica")"
            replication_uri="$(vshard_replication_uri_for_node "$shard" "$replica")"
            cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
  ${service}:
    build:
      context: ./tarantool
      dockerfile: Dockerfile
    image: ${TARANTOOL_VSHARD_IMAGE}
    container_name: ${container}
    environment:
      TARANTOOL_ROLE: storage
      TARANTOOL_USER: ${TARANTOOL_USER}
      TARANTOOL_PASSWORD: ${TARANTOOL_PASSWORD}
      TARANTOOL_SPACE: ${TARANTOOL_SPACE}
      TARANTOOL_MEMTX_MEMORY: "${TARANTOOL_MEMTX_MEMORY}"
      TARANTOOL_WAL_MODE: ${TARANTOOL_VSHARD_WAL_MODE}
      TARANTOOL_READAHEAD: "${TARANTOOL_READAHEAD}"
      TARANTOOL_NET_MSG_MAX: "${TARANTOOL_NET_MSG_MAX}"
      TARANTOOL_SHARDING_USER: ${TARANTOOL_SHARDING_USER}
      TARANTOOL_SHARDING_PASSWORD: ${TARANTOOL_SHARDING_PASSWORD}
      TARANTOOL_REPLICATION_USER: ${TARANTOOL_REPLICATION_USER}
      TARANTOOL_REPLICATION_PASSWORD: ${TARANTOOL_REPLICATION_PASSWORD}
      TARANTOOL_REPLICATION: "${replication_uri}"
      TARANTOOL_REPLICASET_UUID: ${rs_uuid}
      TARANTOOL_INSTANCE_UUID: ${instance_uuid}
      TARANTOOL_REPLICA_INDEX: "${replica}"
    ports:
      - "${host_port}:3301"
    volumes:
      - ${service}-data:/var/lib/tarantool
    networks:
      - ${NETWORK_NAME}
EOF
            append_limits >> "$PROJECT_DIR/docker-compose.yml"
        done
    done

    cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF

networks:
  ${NETWORK_NAME}:
    driver: bridge

volumes:
EOF

    for ((router = 1; router <= TARANTOOL_ROUTERS; router++)); do
        cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
  router-${router}-data:
EOF
    done
    for ((shard = 1; shard <= TARANTOOL_SHARDS; shard++)); do
        for ((replica = 1; replica <= TARANTOOL_REPLICAS_PER_SHARD; replica++)); do
            local service
            service="$(vshard_storage_service "$shard" "$replica")"
            cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
  ${service}-data:
EOF
        done
    done
}

prepare_vshard_files_yaml() {
    log "Preparing Tarantool vshard files in $PROJECT_DIR"
    rm -rf "$PROJECT_DIR"
    mkdir -p "$PROJECT_DIR/tarantool"

    cat > "$PROJECT_DIR/tarantool/config.yaml" <<EOF
credentials:
  users:
    ${TARANTOOL_REPLICATION_USER}:
      password: ${TARANTOOL_REPLICATION_PASSWORD}
      roles: [replication]
    ${TARANTOOL_SHARDING_USER}:
      password: ${TARANTOOL_SHARDING_PASSWORD}
      roles: [sharding]
    ${TARANTOOL_USER}:
      password: ${TARANTOOL_PASSWORD}
      roles: [super]

iproto:
  advertise:
    peer:
      login: ${TARANTOOL_REPLICATION_USER}
      password: ${TARANTOOL_REPLICATION_PASSWORD}
    sharding:
      login: ${TARANTOOL_SHARDING_USER}
      password: ${TARANTOOL_SHARDING_PASSWORD}

process:
  work_dir: /var/lib/tarantool

memtx:
  memory: ${TARANTOOL_MEMTX_MEMORY}

wal:
  mode: ${TARANTOOL_VSHARD_WAL_MODE}
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

    for ((shard = 1; shard <= TARANTOOL_SHARDS; shard++)); do
        cat >> "$PROJECT_DIR/tarantool/config.yaml" <<EOF
      storage-s${shard}:
        leader: $(vshard_storage_service "$shard" 1)
        database:
          replicaset_uuid: '$(vshard_rs_uuid "$shard")'
        instances:
EOF
        for ((replica = 1; replica <= TARANTOOL_REPLICAS_PER_SHARD; replica++)); do
            local service
            service="$(vshard_storage_service "$shard" "$replica")"
            cat >> "$PROJECT_DIR/tarantool/config.yaml" <<EOF
          ${service}:
            database:
              instance_uuid: '$(vshard_instance_uuid "$shard" "$replica")'
            iproto:
              listen:
              - uri: '0.0.0.0:3301'
              advertise:
                peer:
                  uri: '${service}:3301'
                sharding:
                  uri: '${service}:3301'
                client: '${service}:3301'
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

    for ((router = 1; router <= TARANTOOL_ROUTERS; router++)); do
        cat >> "$PROJECT_DIR/tarantool/config.yaml" <<EOF
      router-r${router}:
        database:
          replicaset_uuid: '$(vshard_router_rs_uuid "$router")'
        instances:
          router-${router}:
            database:
              instance_uuid: '$(vshard_router_uuid "$router")'
            iproto:
              listen:
              - uri: '0.0.0.0:3301'
              advertise:
                client: 'router-${router}:3301'
EOF
    done

    cat > "$PROJECT_DIR/tarantool/storage.lua" <<'EOF'
local crud = require('crud')

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

    cat > "$PROJECT_DIR/tarantool/router.lua" <<'EOF'
local fiber = require('fiber')
local vshard = require('vshard')
local crud = require('crud')

local space_name = os.getenv('TARANTOOL_SPACE') or 'kv'

crud.init_router()

fiber.create(function()
    fiber.name('vshard_bootstrapper')
    while true do
        local ok = pcall(function()
            vshard.router.bootstrap({timeout = 2, if_not_bootstrapped = true})
            if vshard.router.discovery_wakeup ~= nil then
                vshard.router.discovery_wakeup()
            end
        end)
        if ok then
            return
        end
        fiber.sleep(1)
    end
end)

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
    return call_vshard(bucket_id, 'write', 'put_storage', {bucket_id, key, value})
end)

rawset(_G, 'get', function(key)
    local bucket_id = bucket_id_for_key(key)
    return call_vshard(bucket_id, 'read', 'get_storage', {bucket_id, key})
end)

rawset(_G, 'truncate_kv', function()
    local result = {}
    local replicasets, err = vshard.router.routeall()
    if err ~= nil then
        error(type(err) == 'table' and err.message or tostring(err))
    end

    for _, replicaset in pairs(replicasets) do
        local truncate_result, truncate_err = replicaset:callrw('truncate_storage', {}, {timeout = 10})
        if truncate_err ~= nil then
            error(type(truncate_err) == 'table' and truncate_err.message or tostring(truncate_err))
        end
        table.insert(result, truncate_result or true)
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

    cat > "$PROJECT_DIR/tarantool/start.sh" <<'EOF'
#!/bin/sh
set -eu

: "${TT_INSTANCE_NAME:?TT_INSTANCE_NAME is required}"

exec tarantool --name "$TT_INSTANCE_NAME" --config "${TT_CONFIG:-/opt/tarantool/config.yaml}"
EOF
    chmod +x "$PROJECT_DIR/tarantool/start.sh"

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

    cat > "$PROJECT_DIR/docker-compose.yml" <<EOF
services:
EOF

    for ((router = 1; router <= TARANTOOL_ROUTERS; router++)); do
        local host_port=$((TARANTOOL_PORT + router - 1))
        cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
  router-${router}:
    build:
      context: ./tarantool
      dockerfile: Dockerfile
    image: ${TARANTOOL_VSHARD_IMAGE}
    container_name: tarantool-vshard-router-${router}
    environment:
      TT_INSTANCE_NAME: router-${router}
      TT_CONFIG: /opt/tarantool/config.yaml
      TARANTOOL_SPACE: ${TARANTOOL_SPACE}
      TARANTOOL_SHARDING_USER: ${TARANTOOL_SHARDING_USER}
    ports:
      - "${host_port}:3301"
    volumes:
      - router-${router}-data:/var/lib/tarantool
    networks:
      - ${NETWORK_NAME}
    depends_on:
EOF
        for ((shard = 1; shard <= TARANTOOL_SHARDS; shard++)); do
            for ((replica = 1; replica <= TARANTOOL_REPLICAS_PER_SHARD; replica++)); do
                cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
      - $(vshard_storage_service "$shard" "$replica")
EOF
            done
        done
        append_limits >> "$PROJECT_DIR/docker-compose.yml"
    done

    for ((shard = 1; shard <= TARANTOOL_SHARDS; shard++)); do
        for ((replica = 1; replica <= TARANTOOL_REPLICAS_PER_SHARD; replica++)); do
            local host_port service container
            host_port="$(vshard_storage_port "$shard" "$replica")"
            service="$(vshard_storage_service "$shard" "$replica")"
            container="$(vshard_storage_container "$shard" "$replica")"
            cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
  ${service}:
    build:
      context: ./tarantool
      dockerfile: Dockerfile
    image: ${TARANTOOL_VSHARD_IMAGE}
    container_name: ${container}
    environment:
      TT_INSTANCE_NAME: ${service}
      TT_CONFIG: /opt/tarantool/config.yaml
      TARANTOOL_SPACE: ${TARANTOOL_SPACE}
      TARANTOOL_SHARDING_USER: ${TARANTOOL_SHARDING_USER}
    ports:
      - "${host_port}:3301"
    volumes:
      - ${service}-data:/var/lib/tarantool
    networks:
      - ${NETWORK_NAME}
EOF
            append_limits >> "$PROJECT_DIR/docker-compose.yml"
        done
    done

    cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF

networks:
  ${NETWORK_NAME}:
    driver: bridge

volumes:
EOF

    for ((router = 1; router <= TARANTOOL_ROUTERS; router++)); do
        cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
  router-${router}-data:
EOF
    done
    for ((shard = 1; shard <= TARANTOOL_SHARDS; shard++)); do
        for ((replica = 1; replica <= TARANTOOL_REPLICAS_PER_SHARD; replica++)); do
            cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
  $(vshard_storage_service "$shard" "$replica")-data:
EOF
        done
    done
}

prepare_files() {
    case "$TARANTOOL_MODE" in
        single)
            prepare_single_files
            ;;
        vshard)
            prepare_vshard_files_yaml
            ;;
        *)
            die "Unknown TARANTOOL_MODE=${TARANTOOL_MODE}. Use single or vshard"
            ;;
    esac
}

build_image() {
    log "Building Tarantool image"
    compose build --no-cache
}

up() {
    log "Starting Tarantool"
    compose up -d --force-recreate
}

verify_single() {
    log "Checking Tarantool"
    for _ in {1..60}; do
        if docker exec "$TARANTOOL_CONTAINER" tarantool -e "local net_box = require('net.box'); local c = net_box.connect('${TARANTOOL_USER}:${TARANTOOL_PASSWORD}@127.0.0.1:3301', {wait_connected = false}); if not c:wait_connected(2) then error(tostring(c.error)) end; c:ping(); c:close()" >/dev/null 2>&1; then
            echo "Tarantool is ready: localhost:${TARANTOOL_PORT}"
            return 0
        fi
        sleep 1
    done
    compose logs tarantool
    die "Tarantool did not become ready"
}

verify_vshard() {
    log "Checking Tarantool vshard"
    local router_container="tarantool-vshard-router-1"
    for _ in {1..90}; do
        if docker exec "$router_container" tarantool -e "local net_box = require('net.box'); local c = net_box.connect('${TARANTOOL_USER}:${TARANTOOL_PASSWORD}@127.0.0.1:3301', {wait_connected = false}); if not c:wait_connected(2) then error(tostring(c.error)) end; c:eval([[local vshard = require('vshard'); vshard.router.bootstrap({timeout = 2, if_not_bootstrapped = true}); if vshard.router.discovery_wakeup ~= nil then vshard.router.discovery_wakeup() end]]); c:call('put', {'healthcheck', 'ok'}); local row = c:call('get', {'healthcheck'}); assert(row and (row[2] == 'ok' or row[3] == 'ok')); c:close()" >/dev/null 2>&1; then
            echo "Tarantool vshard router is ready: localhost:${TARANTOOL_PORT}"
            return 0
        fi
        sleep 1
    done
    compose logs
    die "Tarantool vshard did not become ready"
}

verify() {
    case "$TARANTOOL_MODE" in
        single)
            verify_single
            ;;
        vshard)
            verify_vshard
            ;;
        *)
            die "Unknown TARANTOOL_MODE=${TARANTOOL_MODE}. Use single or vshard"
            ;;
    esac
}

summary_single() {
    cat <<EOF

Tarantool deployed.
  addr: localhost:${TARANTOOL_PORT}
  user: ${TARANTOOL_USER}
  password: ${TARANTOOL_PASSWORD}
  space: ${TARANTOOL_SPACE}
  container: ${TARANTOOL_CONTAINER}
  memory: ${CONTAINER_MEMORY_LIMIT}
  readahead: ${TARANTOOL_READAHEAD}
  net_msg_max: ${TARANTOOL_NET_MSG_MAX}
  disk read/write: ${DISK_READ_BPS}/${DISK_WRITE_BPS} on ${DISK_LIMIT_DEVICE}
EOF
}

summary_vshard() {
    cat <<EOF

Tarantool vshard deployed.
  router addr: localhost:${TARANTOOL_PORT}
  storage ports: localhost:${TARANTOOL_STORAGE_BASE_PORT}..$((TARANTOOL_STORAGE_BASE_PORT + TARANTOOL_SHARDS * TARANTOOL_REPLICAS_PER_SHARD - 1))
  user: ${TARANTOOL_USER}
  password: ${TARANTOOL_PASSWORD}
  space: ${TARANTOOL_SPACE}
  routers: ${TARANTOOL_ROUTERS}
  shards: ${TARANTOOL_SHARDS}
  replicas per shard: ${TARANTOOL_REPLICAS_PER_SHARD}
  bucket_count: ${TARANTOOL_VSHARD_BUCKET_COUNT}
  storage wal_mode: ${TARANTOOL_VSHARD_WAL_MODE}
  memory: ${CONTAINER_MEMORY_LIMIT}
  cpu: ${TARANTOOL_CPU_LIMIT}
  disk read/write: ${DISK_READ_BPS}/${DISK_WRITE_BPS} on ${DISK_LIMIT_DEVICE}
EOF
}

summary() {
    case "$TARANTOOL_MODE" in
        single)
            summary_single
            ;;
        vshard)
            summary_vshard
            ;;
        *)
            die "Unknown TARANTOOL_MODE=${TARANTOOL_MODE}. Use single or vshard"
            ;;
    esac
}

case "$ACTION" in
    deploy)
        down_existing
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
        if [[ "$TARANTOOL_MODE" == "single" ]]; then
            compose logs -f tarantool
        else
            compose logs -f
        fi
        ;;
    down)
        compose down -v --remove-orphans
        ;;
    *)
        echo "Usage: TARANTOOL_MODE=single|vshard $0 [deploy|write|build|up|verify|logs|down]"
        exit 1
        ;;
esac
