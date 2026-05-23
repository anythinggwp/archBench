#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Universal deploy script for Redis, Tarantool, PostgreSQL, YDB
# ============================================================
#
# Defaults preserve the old behavior:
#   ./deploy.sh
# deploys Redis single-node + Tarantool single-node.
#
# Select services:
#   DEPLOY_TARGETS=redis ./deploy.sh
#   DEPLOY_TARGETS=tarantool ./deploy.sh
#   DEPLOY_TARGETS=postgres ./deploy.sh
#   DEPLOY_TARGETS=ydb ./deploy.sh
#   DEPLOY_TARGETS=redis,tarantool,postgres,ydb ./deploy.sh
#   DEPLOY_TARGETS=all ./deploy.sh
#
# Redis topology:
#   REDIS_TOPOLOGY=single
#   REDIS_TOPOLOGY=replication2
#   REDIS_TOPOLOGY=replication4
#   REDIS_TOPOLOGY=sharding2                 # manual/client-side sharding, 2 independent Redis nodes
#   REDIS_TOPOLOGY=sharding4                 # manual/client-side sharding, 4 independent Redis nodes
#   REDIS_TOPOLOGY=sharding_replication4     # manual sharding: 2 master + 2 replica
#
# Redis Cluster topology:
#   REDIS_TOPOLOGY=cluster_sharding3         # 3 master, 0 replica
#   REDIS_TOPOLOGY=cluster_sharding4         # 4 master, 0 replica
#   REDIS_TOPOLOGY=cluster_sharding_replication6 # 3 master + 3 replica
#
# Tarantool topology:
#   TARANTOOL_TOPOLOGY=single
#   TARANTOOL_TOPOLOGY=replication2
#   TARANTOOL_TOPOLOGY=replication4
#   TARANTOOL_TOPOLOGY=sharding2             # manual router by hash(key), 2 nodes
#   TARANTOOL_TOPOLOGY=sharding4             # manual router by hash(key), 4 nodes
#   TARANTOOL_TOPOLOGY=sharding_replication4 # manual router: 2 shards x 2 replicas
#
# Tarantool vshard topology:
#   TARANTOOL_TOPOLOGY=vshard2               # 1 router + 2 vshard storages
#   TARANTOOL_TOPOLOGY=vshard3               # 1 router + 3 vshard storages
#   TARANTOOL_TOPOLOGY=vshard4               # 1 router + 4 vshard storages
#   TARANTOOL_ROUTER_CPU_LIMIT=2.0           # vshard router CPU cap
#   TARANTOOL_STORAGE_CPU_LIMIT=1.0          # vshard storage CPU cap
#
# Prepared configs:
#   CONFIG_DIR=./configs ./deploy.sh
#
# Expected files in CONFIG_DIR:
#   ./configs/redis.conf
#   ./configs/tarantool/init.lua
#   ./configs/tarantool/start.sh
#   ./configs/tarantool/Dockerfile
#   ./configs/postgres/init.sql
#   ./configs/docker-compose.yml
#
# Or direct files:
#   REDIS_CONF_FILE=./my-redis.conf ./deploy.sh
#   TARANTOOL_INIT_FILE=./my-init.lua ./deploy.sh
#   POSTGRES_INIT_SQL_FILE=./my-init.sql ./deploy.sh
#   CUSTOM_COMPOSE_FILE=./docker-compose.yml ./deploy.sh
#
# PostgreSQL:
#   POSTGRES_MAX_CONNECTIONS=100 ./deploy.sh
#
# IMPORTANT:
# - sharding2/sharding4 for Redis are manual independent shards; benchmark must route keys itself.
# - cluster_* modes are real Redis Cluster; benchmark must use redis.ClusterClient.
# - Tarantool sharding2/sharding4 modes are simplified manual routing, not vshard.
# - Tarantool vshard2/vshard3/vshard4 modes use the Tarantool vshard module.
# ============================================================

PROJECT_DIR="${PROJECT_DIR:-redis-tarantool-stack}"
DEPLOY_TARGETS="${DEPLOY_TARGETS:-redis,tarantool}"

CONFIG_DIR="${CONFIG_DIR:-}"
CUSTOM_COMPOSE_FILE="${CUSTOM_COMPOSE_FILE:-}"

REDIS_CONF_FILE="${REDIS_CONF_FILE:-}"
TARANTOOL_INIT_FILE="${TARANTOOL_INIT_FILE:-}"
TARANTOOL_START_FILE="${TARANTOOL_START_FILE:-}"
TARANTOOL_DOCKERFILE="${TARANTOOL_DOCKERFILE:-}"
POSTGRES_INIT_SQL_FILE="${POSTGRES_INIT_SQL_FILE:-}"

CLEAN_PROJECT="${CLEAN_PROJECT:-1}"
REMOVE_VOLUMES="${REMOVE_VOLUMES:-1}"
REMOVE_IMAGES="${REMOVE_IMAGES:-1}"
BUILD_NO_CACHE="${BUILD_NO_CACHE:-1}"
START_CONTAINERS="${START_CONTAINERS:-1}"
VERIFY="${VERIFY:-1}"

NETWORK_NAME="${NETWORK_NAME:-db-net}"

REDIS_TOPOLOGY="${REDIS_TOPOLOGY:-single}"
TARANTOOL_TOPOLOGY="${TARANTOOL_TOPOLOGY:-single}"

REDIS_CONTAINER="${REDIS_CONTAINER:-redis-node}"
TARANTOOL_CONTAINER="${TARANTOOL_CONTAINER:-tarantool-single-node}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-postgres-node}"
YDB_CONTAINER="${YDB_CONTAINER:-ydb-node}"

REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"
TARANTOOL_IMAGE="${TARANTOOL_IMAGE:-local-tarantool-single:3}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"
YDB_IMAGE="${YDB_IMAGE:-ydbplatform/local-ydb:latest}"

REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_SHARD_BASE_PORT="${REDIS_SHARD_BASE_PORT:-7001}"
REDIS_CLUSTER_BASE_PORT="${REDIS_CLUSTER_BASE_PORT:-7001}"

TARANTOOL_PORT="${TARANTOOL_PORT:-3301}"

POSTGRES_PORT="${POSTGRES_PORT:-5432}"

YDB_GRPC_TLS_PORT="${YDB_GRPC_TLS_PORT:-2135}"
YDB_GRPC_PORT="${YDB_GRPC_PORT:-2136}"
YDB_MON_PORT="${YDB_MON_PORT:-8765}"
YDB_KAFKA_PORT="${YDB_KAFKA_PORT:-9092}"

REDIS_CPU_LIMIT="${REDIS_CPU_LIMIT:-1.0}"
REDIS_MEMORY_LIMIT="${REDIS_MEMORY_LIMIT:-5G}"

TARANTOOL_CPU_LIMIT="${TARANTOOL_CPU_LIMIT:-1.0}"
TARANTOOL_ROUTER_CPU_LIMIT="${TARANTOOL_ROUTER_CPU_LIMIT:-2.0}"
TARANTOOL_STORAGE_CPU_LIMIT="${TARANTOOL_STORAGE_CPU_LIMIT:-${TARANTOOL_CPU_LIMIT}}"
TARANTOOL_MEMORY_LIMIT="${TARANTOOL_MEMORY_LIMIT:-5G}"
TARANTOOL_MEMTX_MEMORY="${TARANTOOL_MEMTX_MEMORY:-4294967296}"
TARANTOOL_USER="${TARANTOOL_USER:-app}"
TARANTOOL_PASSWORD="${TARANTOOL_PASSWORD:-app_pass}"
TARANTOOL_SPACE="${TARANTOOL_SPACE:-kv}"
TARANTOOL_WAL_MODE="${TARANTOOL_WAL_MODE:-none}"
TARANTOOL_VSHARD_BUCKET_COUNT="${TARANTOOL_VSHARD_BUCKET_COUNT:-3000}"
TARANTOOL_VSHARD_VERSION="${TARANTOOL_VSHARD_VERSION:-0.1.40}"
TARANTOOL_REPLICATION_USER="${TARANTOOL_REPLICATION_USER:-replicator}"
TARANTOOL_REPLICATION_PASSWORD="${TARANTOOL_REPLICATION_PASSWORD:-replicator_pass}"

POSTGRES_CPU_LIMIT="${POSTGRES_CPU_LIMIT:-8.0}"
POSTGRES_MEMORY_LIMIT="${POSTGRES_MEMORY_LIMIT:-10G}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"
POSTGRES_TABLE="${POSTGRES_TABLE:-kv}"
POSTGRES_MAX_CONNECTIONS="${POSTGRES_MAX_CONNECTIONS:-100}"

YDB_CPU_LIMIT="${YDB_CPU_LIMIT:-8.0}"
YDB_MEMORY_LIMIT="${YDB_MEMORY_LIMIT:-10G}"

# ------------------------------------------------------------
# Common functions
# ------------------------------------------------------------

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

normalize_targets() {
    if [[ "$DEPLOY_TARGETS" == "all" ]]; then
        DEPLOY_TARGETS="redis,tarantool,postgres,ydb"
    fi

    DEPLOY_TARGETS="$(echo "$DEPLOY_TARGETS" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
}

normalize_topologies() {
    REDIS_TOPOLOGY="$(echo "$REDIS_TOPOLOGY" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
    TARANTOOL_TOPOLOGY="$(echo "$TARANTOOL_TOPOLOGY" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"

    # Backward compatibility: old "sharding" means sharding2.
    if [[ "$REDIS_TOPOLOGY" == "sharding" ]]; then
        REDIS_TOPOLOGY="sharding2"
    fi

    if [[ "$TARANTOOL_TOPOLOGY" == "sharding" ]]; then
        TARANTOOL_TOPOLOGY="sharding2"
    fi
}

enabled() {
    local service="$1"
    [[ ",$DEPLOY_TARGETS," == *",$service,"* ]]
}

validate_targets() {
    local IFS=","
    local target

    for target in $DEPLOY_TARGETS; do
        case "$target" in
            redis|tarantool|postgres|ydb)
                ;;
            *)
                die "Unknown DEPLOY_TARGETS item: $target"
                ;;
        esac
    done
}

validate_topologies() {
    case "$REDIS_TOPOLOGY" in
        single|replication2|replication4|sharding2|sharding4|sharding_replication4|cluster_sharding3|cluster_sharding4|cluster_sharding_replication6)
            ;;
        *)
            die "Unknown REDIS_TOPOLOGY: $REDIS_TOPOLOGY"
            ;;
    esac

    case "$TARANTOOL_TOPOLOGY" in
        single|replication2|replication4|sharding2|sharding4|sharding_replication4|vshard2|vshard3|vshard4)
            ;;
        *)
            die "Unknown TARANTOOL_TOPOLOGY: $TARANTOOL_TOPOLOGY"
            ;;
    esac
}

validate_postgres_config() {
    if ! enabled postgres; then
        return 0
    fi

    case "$POSTGRES_MAX_CONNECTIONS" in
        ''|*[!0-9]*)
            die "POSTGRES_MAX_CONNECTIONS must be a positive integer, got: $POSTGRES_MAX_CONNECTIONS"
            ;;
    esac

    if ((POSTGRES_MAX_CONNECTIONS < 1)); then
        die "POSTGRES_MAX_CONNECTIONS must be greater than zero, got: $POSTGRES_MAX_CONNECTIONS"
    fi
}

resolve_config_file() {
    local direct_file="$1"
    local config_dir_file="$2"

    if [[ -n "$direct_file" && -f "$direct_file" ]]; then
        echo "$direct_file"
        return 0
    fi

    if [[ -n "$CONFIG_DIR" && -f "$CONFIG_DIR/$config_dir_file" ]]; then
        echo "$CONFIG_DIR/$config_dir_file"
        return 0
    fi

    return 1
}

wait_tcp() {
    local host="$1"
    local port="$2"
    local name="$3"

    for _ in {1..60}; do
        if timeout 1 bash -c "cat < /dev/null > /dev/tcp/$host/$port" 2>/dev/null; then
            echo "$name is ready."
            return 0
        fi

        sleep 1
    done

    echo "$name is not ready or port is unavailable: $host:$port"
    return 1
}

redis_shard_count() {
    case "$REDIS_TOPOLOGY" in
        sharding2) echo 2 ;;
        sharding4) echo 4 ;;
        *) echo 0 ;;
    esac
}

redis_is_cluster_topology() {
    case "$REDIS_TOPOLOGY" in
        cluster_sharding3|cluster_sharding4|cluster_sharding_replication6)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

redis_cluster_node_count() {
    case "$REDIS_TOPOLOGY" in
        cluster_sharding3) echo 3 ;;
        cluster_sharding4) echo 4 ;;
        cluster_sharding_replication6) echo 6 ;;
        *) echo 0 ;;
    esac
}

redis_cluster_replicas() {
    case "$REDIS_TOPOLOGY" in
        cluster_sharding_replication6) echo 1 ;;
        *) echo 0 ;;
    esac
}

tarantool_shard_count() {
    case "$TARANTOOL_TOPOLOGY" in
        sharding2) echo 2 ;;
        sharding4) echo 4 ;;
        *) echo 0 ;;
    esac
}

tarantool_vshard_shard_count() {
    case "$TARANTOOL_TOPOLOGY" in
        vshard2) echo 2 ;;
        vshard3) echo 3 ;;
        vshard4) echo 4 ;;
        *) echo 0 ;;
    esac
}

tarantool_is_vshard_topology() {
    case "$TARANTOOL_TOPOLOGY" in
        vshard2|vshard3|vshard4) return 0 ;;
        *) return 1 ;;
    esac
}

compose_down_old() {
    if [[ -d "$PROJECT_DIR" && -f "$PROJECT_DIR/docker-compose.yml" ]]; then
        log "Stopping old compose project"

        (
            cd "$PROJECT_DIR"

            if is_true "$REMOVE_VOLUMES"; then
                docker compose down -v --remove-orphans 2>/dev/null || true
            else
                docker compose down --remove-orphans 2>/dev/null || true
            fi
        )
    fi
}

remove_old_containers() {
    log "Removing old containers"

    docker rm -f "$REDIS_CONTAINER" 2>/dev/null || true
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
    docker rm -f redis-cluster-1 2>/dev/null || true
    docker rm -f redis-cluster-2 2>/dev/null || true
    docker rm -f redis-cluster-3 2>/dev/null || true
    docker rm -f redis-cluster-4 2>/dev/null || true
    docker rm -f redis-cluster-5 2>/dev/null || true
    docker rm -f redis-cluster-6 2>/dev/null || true

    docker rm -f "$TARANTOOL_CONTAINER" 2>/dev/null || true
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
    docker rm -f tarantool-vshard-router 2>/dev/null || true
    docker rm -f tarantool-vshard-storage-1 2>/dev/null || true
    docker rm -f tarantool-vshard-storage-2 2>/dev/null || true
    docker rm -f tarantool-vshard-storage-3 2>/dev/null || true
    docker rm -f tarantool-vshard-storage-4 2>/dev/null || true

    docker rm -f "$POSTGRES_CONTAINER" 2>/dev/null || true
    docker rm -f "$YDB_CONTAINER" 2>/dev/null || true
    docker rm -f ydb-local 2>/dev/null || true
}

remove_old_images() {
    if ! is_true "$REMOVE_IMAGES"; then
        return 0
    fi

    log "Removing old local images"

    if enabled tarantool; then
        docker image rm -f "$TARANTOOL_IMAGE" 2>/dev/null || true
    fi
}

prepare_project_dir() {
    if is_true "$CLEAN_PROJECT"; then
        log "Removing old project directory"
        rm -rf "$PROJECT_DIR"
    fi

    log "Creating project structure"

    mkdir -p "$PROJECT_DIR"
    mkdir -p "$PROJECT_DIR/redis"
    mkdir -p "$PROJECT_DIR/tarantool"
    mkdir -p "$PROJECT_DIR/postgres"
    mkdir -p "$PROJECT_DIR/ydb"
}

# ------------------------------------------------------------
# Redis config
# ------------------------------------------------------------

write_redis_standalone_conf() {
    local path="$1"

    cat > "$path" <<EOF2
bind 0.0.0.0
port 6379

protected-mode no

appendonly yes
appendfilename "appendonly.aof"
dir /data

save 60 1000

loglevel notice
EOF2
}

write_redis_replica_conf() {
    local path="$1"
    local master_host="$2"

    cat > "$path" <<EOF2
bind 0.0.0.0
port 6379

protected-mode no

replicaof ${master_host} 6379

appendonly yes
appendfilename "appendonly.aof"
dir /data

save 60 1000

loglevel notice
EOF2
}

write_redis_cluster_conf() {
    local path="$1"
    local port="$2"

    cat > "$path" <<EOF2
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
EOF2
}

write_redis_config() {
    if ! enabled redis; then
        return 0
    fi

    log "Preparing Redis, topology=${REDIS_TOPOLOGY}"

    rm -rf "$PROJECT_DIR/redis"
    mkdir -p "$PROJECT_DIR/redis"

    local src=""

    case "$REDIS_TOPOLOGY" in
        single)
            if src="$(resolve_config_file "$REDIS_CONF_FILE" "redis.conf")"; then
                echo "Using prepared Redis config: $src"
                cp "$src" "$PROJECT_DIR/redis/redis.conf"
            else
                write_redis_standalone_conf "$PROJECT_DIR/redis/redis.conf"
            fi
            ;;

        replication2|replication4)
            write_redis_standalone_conf "$PROJECT_DIR/redis/master.conf"

            local replica_count=1
            if [[ "$REDIS_TOPOLOGY" == "replication4" ]]; then
                replica_count=3
            fi

            for i in $(seq 1 "$replica_count"); do
                write_redis_replica_conf "$PROJECT_DIR/redis/replica-${i}.conf" "redis-master"
            done
            ;;

        sharding2|sharding4)
            local shards
            shards="$(redis_shard_count)"

            for i in $(seq 1 "$shards"); do
                mkdir -p "$PROJECT_DIR/redis/shard-${i}"
                write_redis_standalone_conf "$PROJECT_DIR/redis/shard-${i}/redis.conf"
            done
            ;;

        sharding_replication4)
            for shard in 1 2; do
                mkdir -p "$PROJECT_DIR/redis/s${shard}-master"
                mkdir -p "$PROJECT_DIR/redis/s${shard}-replica"

                write_redis_standalone_conf "$PROJECT_DIR/redis/s${shard}-master/redis.conf"
                write_redis_replica_conf "$PROJECT_DIR/redis/s${shard}-replica/redis.conf" "redis-s${shard}-master"
            done
            ;;

        cluster_sharding3|cluster_sharding4|cluster_sharding_replication6)
            local nodes
            nodes="$(redis_cluster_node_count)"

            for i in $(seq 1 "$nodes"); do
                local port=$((REDIS_CLUSTER_BASE_PORT + i - 1))
                mkdir -p "$PROJECT_DIR/redis/cluster-${i}"
                write_redis_cluster_conf "$PROJECT_DIR/redis/cluster-${i}/redis.conf" "$port"
            done
            ;;
    esac
}

# ------------------------------------------------------------
# Tarantool config
# ------------------------------------------------------------

write_tarantool_vshard_cfg() {
    if ! enabled tarantool; then
        return 0
    fi

    if ! tarantool_is_vshard_topology; then
        cat > "$PROJECT_DIR/tarantool/vshard_cfg.lua" <<'EOF2'
return {
    bucket_count = 3000,
    sharding = {},
}
EOF2
        return 0
    fi

    local shards
    shards="$(tarantool_vshard_shard_count)"

    log "Generating Tarantool vshard config, shards=${shards}, bucket_count=${TARANTOOL_VSHARD_BUCKET_COUNT}"

    cat > "$PROJECT_DIR/tarantool/vshard_cfg.lua" <<EOF2
return {
    bucket_count = ${TARANTOOL_VSHARD_BUCKET_COUNT},
    sharding = {
EOF2

    for shard in $(seq 1 "$shards"); do
        local rs_uuid
        local instance_uuid
        rs_uuid=$(printf '11111111-1111-1111-1111-%012d' "$shard")
        instance_uuid=$(printf '22222222-2222-2222-2222-%012d' "$shard")

        cat >> "$PROJECT_DIR/tarantool/vshard_cfg.lua" <<EOF2
        ['${rs_uuid}'] = {
            replicas = {
                ['${instance_uuid}'] = {
                    uri = '${TARANTOOL_USER}:${TARANTOOL_PASSWORD}@tarantool-vshard-storage-${shard}:3301',
                    name = 'tarantool-vshard-storage-${shard}',
                    master = true,
                },
            },
        },
EOF2
    done

    cat >> "$PROJECT_DIR/tarantool/vshard_cfg.lua" <<'EOF2'
    },
}
EOF2
}

write_tarantool_files() {
    if ! enabled tarantool; then
        return 0
    fi

    log "Preparing Tarantool, topology=${TARANTOOL_TOPOLOGY}"

    rm -rf "$PROJECT_DIR/tarantool"
    mkdir -p "$PROJECT_DIR/tarantool"

    local src=""

    write_tarantool_vshard_cfg

    if src="$(resolve_config_file "$TARANTOOL_INIT_FILE" "tarantool/init.lua")"; then
        echo "Using prepared Tarantool init.lua: $src"
        cp "$src" "$PROJECT_DIR/tarantool/init.lua"
    else
        cat > "$PROJECT_DIR/tarantool/init.lua" <<'EOF2'
local fiber = require('fiber')
local net_box = require('net.box')

local node_name = os.getenv('TARANTOOL_NODE_NAME') or 'tarantool'
local topology = os.getenv('TARANTOOL_TOPOLOGY') or 'single'
local role = os.getenv('TARANTOOL_ROLE') or 'master'
local space_name = os.getenv('TARANTOOL_SPACE') or 'kv'

local app_user = os.getenv('TARANTOOL_USER') or 'app'
local app_password = os.getenv('TARANTOOL_PASSWORD') or 'app_pass'

local repl_user = os.getenv('TARANTOOL_REPLICATION_USER') or 'replicator'
local repl_password = os.getenv('TARANTOOL_REPLICATION_PASSWORD') or 'replicator_pass'

local memtx_memory = tonumber(os.getenv('TARANTOOL_MEMTX_MEMORY') or tostring(4 * 1024 * 1024 * 1024))
local wal_mode = os.getenv('TARANTOOL_WAL_MODE') or 'none'

local replication_raw = os.getenv('TARANTOOL_REPLICATION') or ''
local shard_uris_raw = os.getenv('TARANTOOL_SHARD_URIS') or ''
local read_only = os.getenv('TARANTOOL_READ_ONLY') == 'true'

local vshard_role = os.getenv('TARANTOOL_VSHARD_ROLE') or ''
local instance_uuid = os.getenv('TARANTOOL_INSTANCE_UUID') or ''
local replicaset_uuid = os.getenv('TARANTOOL_REPLICASET_UUID') or ''
local is_vshard = topology == 'vshard2' or topology == 'vshard3' or topology == 'vshard4'

local function split_csv(s)
    local result = {}

    for item in string.gmatch(s, '([^,]+)') do
        table.insert(result, item)
    end

    return result
end

local function grant_user(user, privilege, object_type, object_name)
    local ok, err = pcall(function()
        box.schema.user.grant(user, privilege, object_type, object_name, {
            if_not_exists = true
        })
    end)

    if not ok and not tostring(err):match('Duplicate') and not tostring(err):match('already') then
        error(err)
    end
end

local function ensure_app_user()
    box.schema.user.create(app_user, {
        password = app_password,
        if_not_exists = true
    })

    grant_user(app_user, 'read', 'universe', nil)
    grant_user(app_user, 'write', 'universe', nil)
    grant_user(app_user, 'execute', 'universe', nil)
end

local function ensure_replication_user_if_needed()
    if replication_raw == '' then
        return
    end

    box.schema.user.create(repl_user, {
        password = repl_password,
        if_not_exists = true
    })

    local ok, err = pcall(function()
        box.schema.user.grant(repl_user, 'replication')
    end)

    if not ok and not tostring(err):match('Duplicate') and not tostring(err):match('already') then
        error(err)
    end
end

local function create_plain_schema()
    local kv = box.schema.space.create(space_name, {
        if_not_exists = true
    })

    kv:format({
        {name = 'key', type = 'string'},
        {name = 'value', type = 'string'}
    })

    kv:create_index('primary', {
        type = 'HASH',
        parts = {
            {field = 1, type = 'string'}
        },
        if_not_exists = true
    })
end

local function create_vshard_storage_schema()
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
            {field = 1, type = 'string'}
        },
        if_not_exists = true
    })

    kv:create_index('bucket_id', {
        type = 'TREE',
        parts = {
            {field = 2, type = 'unsigned'}
        },
        unique = false,
        if_not_exists = true
    })
end

local shard_uris = {}
if shard_uris_raw ~= '' then
    shard_uris = split_csv(shard_uris_raw)
end

local cfg = {
    listen = '0.0.0.0:3301',

    memtx_memory = memtx_memory,
    wal_mode = wal_mode,

    memtx_dir = '/var/lib/tarantool',
    vinyl_dir = '/var/lib/tarantool',

    -- Start writable to allow bootstrap/schema creation.
    read_only = false,
}

if not is_vshard and replication_raw ~= '' then
    cfg.replication = split_csv(replication_raw)
    cfg.bootstrap_strategy = 'auto'
    cfg.replication_timeout = 1
end

local function hash_key(key)
    key = tostring(key)

    local h = 0

    for i = 1, #key do
        h = (h * 31 + string.byte(key, i)) % 2147483647
    end

    return h
end

local function storage_uri_for_key(key)
    if #shard_uris == 0 then
        return nil
    end

    local h = hash_key(key)
    local shard_index = (h % #shard_uris) + 1

    return shard_uris[shard_index]
end

local function remote_call(uri, fn, args)
    local c = net_box.connect(uri, {
        wait_connected = false
    })

    if not c:wait_connected(5) then
        error('Cannot connect to ' .. uri .. ': ' .. tostring(c.error))
    end

    local result = c:call(fn, args)
    c:close()

    return result
end

local function start_plain_or_manual_sharding()
    box.cfg(cfg)

    box.once('bootstrap_schema_v1', function()
        ensure_app_user()
        ensure_replication_user_if_needed()
        create_plain_schema()
    end)

    if read_only then
        box.cfg{read_only = true}
    end

    rawset(_G, 'put_local', function(key, value)
        return box.space[space_name]:replace{key, value}
    end)

    rawset(_G, 'get_local', function(key)
        return box.space[space_name]:get{key}
    end)

    rawset(_G, 'truncate_local', function()
        box.space[space_name]:truncate()
        return box.space[space_name]:len()
    end)

    rawset(_G, 'put', function(key, value)
        local uri = storage_uri_for_key(key)

        if uri ~= nil then
            return remote_call(uri, 'put_local', {key, value})
        end

        return box.space[space_name]:replace{key, value}
    end)

    rawset(_G, 'get', function(key)
        local uri = storage_uri_for_key(key)

        if uri ~= nil then
            return remote_call(uri, 'get_local', {key})
        end

        return box.space[space_name]:get{key}
    end)

    rawset(_G, 'truncate_kv', function()
        if #shard_uris > 0 then
            local result = {}

            for _, uri in ipairs(shard_uris) do
                table.insert(result, remote_call(uri, 'truncate_local', {}))
            end

            return result
        end

        box.space[space_name]:truncate()
        return box.space[space_name]:len()
    end)
end

local function start_vshard()
    local vshard = require('vshard')
    -- Tarantool 3.x net.box resolves vshard persistent functions through _G.
    rawset(_G, 'vshard', vshard)
    local vshard_cfg = dofile('/opt/tarantool/vshard_cfg.lua')

    if vshard_role == 'storage' then
        if instance_uuid == '' then
            error('TARANTOOL_INSTANCE_UUID is required for vshard storage')
        end

        if replicaset_uuid == '' then
            error('TARANTOOL_REPLICASET_UUID is required for vshard storage')
        end

        local storage_cfg = {
            listen = '0.0.0.0:3301',

            memtx_memory = memtx_memory,
            wal_mode = wal_mode,

            memtx_dir = '/var/lib/tarantool',
            vinyl_dir = '/var/lib/tarantool',

            read_only = false,

            instance_uuid = instance_uuid,
            replicaset_uuid = replicaset_uuid,
        }

        box.cfg(storage_cfg)

        box.once('bootstrap_users_v1', function()
            ensure_app_user()
        end)

        box.once('bootstrap_vshard_storage_schema_v1', function()
            create_vshard_storage_schema()
        end)

        vshard.storage.cfg(vshard_cfg, instance_uuid)

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
            box.space[space_name]:truncate()
            return box.space[space_name]:len()
        end)

        return
    end

    if vshard_role ~= 'router' then
        error('Unknown TARANTOOL_VSHARD_ROLE: ' .. tostring(vshard_role))
    end

    box.cfg(cfg)

    box.once('bootstrap_users_v1', function()
        ensure_app_user()
    end)

    vshard.router.cfg(vshard_cfg)

    fiber.create(function()
        for i = 1, 60 do
            local ok, err = pcall(function()
                vshard.router.bootstrap({
                    timeout = 2,
                    if_not_bootstrapped = true
                })
            end)

            if ok then
                print('vshard bootstrap completed or already done')
                return
            end

            print('vshard bootstrap retry ' .. tostring(i) .. ': ' .. tostring(err))
            fiber.sleep(1)
        end
    end)

    local function bucket_id_for_key(key)
        key = tostring(key)
        if vshard.router.bucket_id_strcrc32 ~= nil then
            return vshard.router.bucket_id_strcrc32(key)
        end
        return vshard.router.bucket_id(key)
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

        for _, replicaset in pairs(vshard_cfg.sharding) do
            for _, replica in pairs(replicaset.replicas) do
                if replica.master then
                    local c = net_box.connect(replica.uri, {
                        wait_connected = false
                    })

                    if not c:wait_connected(5) then
                        error('Cannot connect to ' .. replica.uri .. ': ' .. tostring(c.error))
                    end

                    table.insert(result, c:call('truncate_storage', {}))
                    c:close()
                end
            end
        end

        return result
    end)
end

if is_vshard then
    start_vshard()
else
    start_plain_or_manual_sharding()
end

print('Tarantool node started')
print('node=' .. node_name)
print('topology=' .. topology)
print('role=' .. role)
print('vshard_role=' .. tostring(vshard_role))
print('read_only=' .. tostring(read_only))
print('space=' .. space_name)
print('wal_mode=' .. wal_mode)
print('replication_enabled=' .. tostring(replication_raw ~= ''))
print('shard_uris=' .. shard_uris_raw)
EOF2
    fi

    if src="$(resolve_config_file "$TARANTOOL_START_FILE" "tarantool/start.sh")"; then
        echo "Using prepared Tarantool start.sh: $src"
        cp "$src" "$PROJECT_DIR/tarantool/start.sh"
    else
        cat > "$PROJECT_DIR/tarantool/start.sh" <<'EOF2'
#!/bin/sh
set -eu

unset TT_APP_NAME
unset TT_INSTANCE_NAME
unset TT_CONFIG
unset TT_CONFIG_ETCD_ENDPOINTS

exec tarantool /opt/tarantool/init.lua
EOF2
    fi

    chmod +x "$PROJECT_DIR/tarantool/start.sh"

    if src="$(resolve_config_file "$TARANTOOL_DOCKERFILE" "tarantool/Dockerfile")"; then
        echo "Using prepared Tarantool Dockerfile: $src"
        cp "$src" "$PROJECT_DIR/tarantool/Dockerfile"
    else
        if tarantool_is_vshard_topology; then
            cat > "$PROJECT_DIR/tarantool/Dockerfile" <<EOF2
FROM tarantool/tarantool:3

# The official tarantool/tarantool image may not include tt, tarantoolctl or luarocks.
# For the benchmark stand we install vshard by copying the Lua module from
# the official GitHub release archive. This avoids exit code 127 during build.
ADD https://github.com/tarantool/vshard/archive/refs/tags/${TARANTOOL_VSHARD_VERSION}.tar.gz /tmp/vshard.tar.gz

RUN set -eux; \
    mkdir -p /tmp/vshard-src /usr/local/share/tarantool; \
    tar -xzf /tmp/vshard.tar.gz -C /tmp/vshard-src --strip-components=1; \
    cp -R /tmp/vshard-src/vshard /usr/local/share/tarantool/vshard; \
    env -u TT_APP_NAME -u TT_INSTANCE_NAME -u TT_CONFIG -u TT_CONFIG_ETCD_ENDPOINTS \
        tarantool -e "local vshard = require('vshard'); print('vshard installed', vshard._VERSION)"; \
    rm -rf /tmp/vshard.tar.gz /tmp/vshard-src

COPY init.lua /opt/tarantool/init.lua
COPY vshard_cfg.lua /opt/tarantool/vshard_cfg.lua
COPY start.sh /usr/local/bin/start-tarantool-single

RUN chmod +x /usr/local/bin/start-tarantool-single

ENTRYPOINT ["/usr/local/bin/start-tarantool-single"]
EOF2
        else
            cat > "$PROJECT_DIR/tarantool/Dockerfile" <<'EOF2'
FROM tarantool/tarantool:3

COPY init.lua /opt/tarantool/init.lua
COPY vshard_cfg.lua /opt/tarantool/vshard_cfg.lua
COPY start.sh /usr/local/bin/start-tarantool-single

RUN chmod +x /usr/local/bin/start-tarantool-single

ENTRYPOINT ["/usr/local/bin/start-tarantool-single"]
EOF2
        fi
    fi
}

# ------------------------------------------------------------
# PostgreSQL config
# ------------------------------------------------------------

write_postgres_files() {
    if ! enabled postgres; then
        return 0
    fi

    log "Preparing PostgreSQL"

    local src=""

    if src="$(resolve_config_file "$POSTGRES_INIT_SQL_FILE" "postgres/init.sql")"; then
        echo "Using prepared PostgreSQL init.sql: $src"
        cp "$src" "$PROJECT_DIR/postgres/init.sql"
        return 0
    fi

    cat > "$PROJECT_DIR/postgres/init.sql" <<EOF2
CREATE TABLE IF NOT EXISTS ${POSTGRES_TABLE} (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
EOF2
}

# ------------------------------------------------------------
# Docker Compose generation
# ------------------------------------------------------------

write_compose_from_custom_file() {
    if [[ -n "$CUSTOM_COMPOSE_FILE" ]]; then
        [[ -f "$CUSTOM_COMPOSE_FILE" ]] || die "CUSTOM_COMPOSE_FILE not found: $CUSTOM_COMPOSE_FILE"

        log "Using prepared docker-compose.yml: $CUSTOM_COMPOSE_FILE"
        cp "$CUSTOM_COMPOSE_FILE" "$PROJECT_DIR/docker-compose.yml"
        return 0
    fi

    if [[ -n "$CONFIG_DIR" && -f "$CONFIG_DIR/docker-compose.yml" ]]; then
        log "Using prepared docker-compose.yml from CONFIG_DIR: $CONFIG_DIR/docker-compose.yml"
        cp "$CONFIG_DIR/docker-compose.yml" "$PROJECT_DIR/docker-compose.yml"
        return 0
    fi

    return 1
}

append_redis_compose() {
    if ! enabled redis; then
        return 0
    fi

    case "$REDIS_TOPOLOGY" in
        single)
            cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
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
    deploy:
      resources:
        limits:
          cpus: "${REDIS_CPU_LIMIT}"
          memory: ${REDIS_MEMORY_LIMIT}

EOF2
            ;;

        replication2|replication4)
            local replica_count=1
            if [[ "$REDIS_TOPOLOGY" == "replication4" ]]; then
                replica_count=3
            fi

            cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  redis-master:
    image: ${REDIS_IMAGE}
    container_name: redis-master
    command: ["redis-server", "/usr/local/etc/redis/redis.conf"]
    ports:
      - "${REDIS_PORT}:6379"
    volumes:
      - ./redis/master.conf:/usr/local/etc/redis/redis.conf:ro
      - redis-master-data:/data
    networks:
      - ${NETWORK_NAME}
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: "${REDIS_CPU_LIMIT}"
          memory: ${REDIS_MEMORY_LIMIT}

EOF2

            for i in $(seq 1 "$replica_count"); do
                local host_port=$((REDIS_PORT + i))

                cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  redis-replica-${i}:
    image: ${REDIS_IMAGE}
    container_name: redis-replica-${i}
    command: ["redis-server", "/usr/local/etc/redis/redis.conf"]
    depends_on:
      - redis-master
    ports:
      - "${host_port}:6379"
    volumes:
      - ./redis/replica-${i}.conf:/usr/local/etc/redis/redis.conf:ro
      - redis-replica-${i}-data:/data
    networks:
      - ${NETWORK_NAME}
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: "${REDIS_CPU_LIMIT}"
          memory: ${REDIS_MEMORY_LIMIT}

EOF2
            done
            ;;

        sharding2|sharding4)
            local shards
            shards="$(redis_shard_count)"

            for i in $(seq 1 "$shards"); do
                local host_port=$((REDIS_SHARD_BASE_PORT + i - 1))

                cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  redis-shard-${i}:
    image: ${REDIS_IMAGE}
    container_name: redis-shard-${i}
    command: ["redis-server", "/usr/local/etc/redis/redis.conf"]
    ports:
      - "${host_port}:6379"
    volumes:
      - ./redis/shard-${i}/redis.conf:/usr/local/etc/redis/redis.conf:ro
      - redis-shard-${i}-data:/data
    networks:
      - ${NETWORK_NAME}
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: "${REDIS_CPU_LIMIT}"
          memory: ${REDIS_MEMORY_LIMIT}

EOF2
            done
            ;;

        sharding_replication4)
            for shard in 1 2; do
                local master_port=$((REDIS_SHARD_BASE_PORT + (shard - 1) * 2))
                local replica_port=$((master_port + 1))

                cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  redis-s${shard}-master:
    image: ${REDIS_IMAGE}
    container_name: redis-s${shard}-master
    command: ["redis-server", "/usr/local/etc/redis/redis.conf"]
    ports:
      - "${master_port}:6379"
    volumes:
      - ./redis/s${shard}-master/redis.conf:/usr/local/etc/redis/redis.conf:ro
      - redis-s${shard}-master-data:/data
    networks:
      - ${NETWORK_NAME}
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: "${REDIS_CPU_LIMIT}"
          memory: ${REDIS_MEMORY_LIMIT}

  redis-s${shard}-replica:
    image: ${REDIS_IMAGE}
    container_name: redis-s${shard}-replica
    command: ["redis-server", "/usr/local/etc/redis/redis.conf"]
    depends_on:
      - redis-s${shard}-master
    ports:
      - "${replica_port}:6379"
    volumes:
      - ./redis/s${shard}-replica/redis.conf:/usr/local/etc/redis/redis.conf:ro
      - redis-s${shard}-replica-data:/data
    networks:
      - ${NETWORK_NAME}
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: "${REDIS_CPU_LIMIT}"
          memory: ${REDIS_MEMORY_LIMIT}

EOF2
            done
            ;;

        cluster_sharding3|cluster_sharding4|cluster_sharding_replication6)
            local nodes
            nodes="$(redis_cluster_node_count)"

            for i in $(seq 1 "$nodes"); do
                cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  redis-cluster-${i}:
    image: ${REDIS_IMAGE}
    container_name: redis-cluster-${i}
    command: ["redis-server", "/usr/local/etc/redis/redis.conf"]
    network_mode: host
    volumes:
      - ./redis/cluster-${i}/redis.conf:/usr/local/etc/redis/redis.conf:ro
      - redis-cluster-${i}-data:/data
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: "${REDIS_CPU_LIMIT}"
          memory: ${REDIS_MEMORY_LIMIT}

EOF2
            done
            ;;
    esac
}

append_tarantool_compose() {
    if ! enabled tarantool; then
        return 0
    fi

    case "$TARANTOOL_TOPOLOGY" in
        single)
            cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  tarantool:
    build:
      context: ./tarantool
      dockerfile: Dockerfile
    image: ${TARANTOOL_IMAGE}
    container_name: ${TARANTOOL_CONTAINER}
    environment:
      TARANTOOL_NODE_NAME: tarantool
      TARANTOOL_TOPOLOGY: single
      TARANTOOL_ROLE: master
      TARANTOOL_READ_ONLY: "false"
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
    deploy:
      resources:
        limits:
          cpus: "${TARANTOOL_CPU_LIMIT}"
          memory: ${TARANTOOL_MEMORY_LIMIT}

EOF2
            ;;

        replication2|replication4)
            local replica_count=1
            if [[ "$TARANTOOL_TOPOLOGY" == "replication4" ]]; then
                replica_count=3
            fi

            local repl_uris="${TARANTOOL_REPLICATION_USER}:${TARANTOOL_REPLICATION_PASSWORD}@tarantool-master:3301"
            for i in $(seq 1 "$replica_count"); do
                repl_uris="${repl_uris},${TARANTOOL_REPLICATION_USER}:${TARANTOOL_REPLICATION_PASSWORD}@tarantool-replica-${i}:3301"
            done

            cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  tarantool-master:
    build:
      context: ./tarantool
      dockerfile: Dockerfile
    image: ${TARANTOOL_IMAGE}
    container_name: tarantool-master
    environment:
      TARANTOOL_NODE_NAME: tarantool-master
      TARANTOOL_TOPOLOGY: ${TARANTOOL_TOPOLOGY}
      TARANTOOL_ROLE: master
      TARANTOOL_READ_ONLY: "false"
      TARANTOOL_REPLICATION: "${repl_uris}"
      TARANTOOL_REPLICATION_USER: ${TARANTOOL_REPLICATION_USER}
      TARANTOOL_REPLICATION_PASSWORD: ${TARANTOOL_REPLICATION_PASSWORD}
      TARANTOOL_USER: ${TARANTOOL_USER}
      TARANTOOL_PASSWORD: ${TARANTOOL_PASSWORD}
      TARANTOOL_SPACE: ${TARANTOOL_SPACE}
      TARANTOOL_MEMTX_MEMORY: "${TARANTOOL_MEMTX_MEMORY}"
      TARANTOOL_WAL_MODE: ${TARANTOOL_WAL_MODE}
    ports:
      - "${TARANTOOL_PORT}:3301"
    volumes:
      - tarantool-master-data:/var/lib/tarantool
    networks:
      - ${NETWORK_NAME}
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: "${TARANTOOL_CPU_LIMIT}"
          memory: ${TARANTOOL_MEMORY_LIMIT}

EOF2

            for i in $(seq 1 "$replica_count"); do
                local host_port=$((TARANTOOL_PORT + i))

                cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  tarantool-replica-${i}:
    build:
      context: ./tarantool
      dockerfile: Dockerfile
    image: ${TARANTOOL_IMAGE}
    container_name: tarantool-replica-${i}
    depends_on:
      - tarantool-master
    environment:
      TARANTOOL_NODE_NAME: tarantool-replica-${i}
      TARANTOOL_TOPOLOGY: ${TARANTOOL_TOPOLOGY}
      TARANTOOL_ROLE: replica
      TARANTOOL_READ_ONLY: "true"
      TARANTOOL_REPLICATION: "${repl_uris}"
      TARANTOOL_REPLICATION_USER: ${TARANTOOL_REPLICATION_USER}
      TARANTOOL_REPLICATION_PASSWORD: ${TARANTOOL_REPLICATION_PASSWORD}
      TARANTOOL_USER: ${TARANTOOL_USER}
      TARANTOOL_PASSWORD: ${TARANTOOL_PASSWORD}
      TARANTOOL_SPACE: ${TARANTOOL_SPACE}
      TARANTOOL_MEMTX_MEMORY: "${TARANTOOL_MEMTX_MEMORY}"
      TARANTOOL_WAL_MODE: ${TARANTOOL_WAL_MODE}
    ports:
      - "${host_port}:3301"
    volumes:
      - tarantool-replica-${i}-data:/var/lib/tarantool
    networks:
      - ${NETWORK_NAME}
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: "${TARANTOOL_CPU_LIMIT}"
          memory: ${TARANTOOL_MEMORY_LIMIT}

EOF2
            done
            ;;

        sharding2|sharding4)
            local shards
            shards="$(tarantool_shard_count)"

            local shard_uris=""
            for shard in $(seq 1 "$shards"); do
                if [[ -n "$shard_uris" ]]; then
                    shard_uris="${shard_uris},"
                fi
                shard_uris="${shard_uris}${TARANTOOL_USER}:${TARANTOOL_PASSWORD}@tarantool-shard-${shard}:3301"
            done

            for shard in $(seq 1 "$shards"); do
                local host_port=$((TARANTOOL_PORT + shard - 1))

                cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  tarantool-shard-${shard}:
    build:
      context: ./tarantool
      dockerfile: Dockerfile
    image: ${TARANTOOL_IMAGE}
    container_name: tarantool-shard-${shard}
    environment:
      TARANTOOL_NODE_NAME: tarantool-shard-${shard}
      TARANTOOL_TOPOLOGY: ${TARANTOOL_TOPOLOGY}
      TARANTOOL_ROLE: shard
      TARANTOOL_READ_ONLY: "false"
      TARANTOOL_SHARD_URIS: "${shard_uris}"
      TARANTOOL_USER: ${TARANTOOL_USER}
      TARANTOOL_PASSWORD: ${TARANTOOL_PASSWORD}
      TARANTOOL_SPACE: ${TARANTOOL_SPACE}
      TARANTOOL_MEMTX_MEMORY: "${TARANTOOL_MEMTX_MEMORY}"
      TARANTOOL_WAL_MODE: ${TARANTOOL_WAL_MODE}
    ports:
      - "${host_port}:3301"
    volumes:
      - tarantool-shard-${shard}-data:/var/lib/tarantool
    networks:
      - ${NETWORK_NAME}
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: "${TARANTOOL_CPU_LIMIT}"
          memory: ${TARANTOOL_MEMORY_LIMIT}

EOF2
            done
            ;;

        sharding_replication4)
            local shard_uris="${TARANTOOL_USER}:${TARANTOOL_PASSWORD}@tarantool-s1-r1:3301,${TARANTOOL_USER}:${TARANTOOL_PASSWORD}@tarantool-s2-r1:3301"

            for shard in 1 2; do
                local repl_uris="${TARANTOOL_REPLICATION_USER}:${TARANTOOL_REPLICATION_PASSWORD}@tarantool-s${shard}-r1:3301,${TARANTOOL_REPLICATION_USER}:${TARANTOOL_REPLICATION_PASSWORD}@tarantool-s${shard}-r2:3301"

                for replica in 1 2; do
                    local role="replica"
                    local readonly="true"

                    if [[ "$replica" == "1" ]]; then
                        role="master"
                        readonly="false"
                    fi

                    local node_index=$(((shard - 1) * 2 + replica))
                    local host_port=$((TARANTOOL_PORT + node_index - 1))

                    cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  tarantool-s${shard}-r${replica}:
    build:
      context: ./tarantool
      dockerfile: Dockerfile
    image: ${TARANTOOL_IMAGE}
    container_name: tarantool-s${shard}-r${replica}
    environment:
      TARANTOOL_NODE_NAME: tarantool-s${shard}-r${replica}
      TARANTOOL_TOPOLOGY: sharding_replication4
      TARANTOOL_ROLE: ${role}
      TARANTOOL_READ_ONLY: "${readonly}"
      TARANTOOL_REPLICATION: "${repl_uris}"
      TARANTOOL_SHARD_URIS: "${shard_uris}"
      TARANTOOL_REPLICATION_USER: ${TARANTOOL_REPLICATION_USER}
      TARANTOOL_REPLICATION_PASSWORD: ${TARANTOOL_REPLICATION_PASSWORD}
      TARANTOOL_USER: ${TARANTOOL_USER}
      TARANTOOL_PASSWORD: ${TARANTOOL_PASSWORD}
      TARANTOOL_SPACE: ${TARANTOOL_SPACE}
      TARANTOOL_MEMTX_MEMORY: "${TARANTOOL_MEMTX_MEMORY}"
      TARANTOOL_WAL_MODE: ${TARANTOOL_WAL_MODE}
    ports:
      - "${host_port}:3301"
    volumes:
      - tarantool-s${shard}-r${replica}-data:/var/lib/tarantool
    networks:
      - ${NETWORK_NAME}
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: "${TARANTOOL_CPU_LIMIT}"
          memory: ${TARANTOOL_MEMORY_LIMIT}

EOF2
                done
            done
            ;;

        vshard2|vshard3|vshard4)
            local shards
            shards="$(tarantool_vshard_shard_count)"

            cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  tarantool-vshard-router:
    build:
      context: ./tarantool
      dockerfile: Dockerfile
    image: ${TARANTOOL_IMAGE}
    container_name: tarantool-vshard-router
    depends_on:
EOF2

            for shard in $(seq 1 "$shards"); do
                cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
      - tarantool-vshard-storage-${shard}
EOF2
            done

            cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
    environment:
      TARANTOOL_NODE_NAME: tarantool-vshard-router
      TARANTOOL_TOPOLOGY: ${TARANTOOL_TOPOLOGY}
      TARANTOOL_ROLE: router
      TARANTOOL_VSHARD_ROLE: router
      TARANTOOL_READ_ONLY: "false"
      TARANTOOL_USER: ${TARANTOOL_USER}
      TARANTOOL_PASSWORD: ${TARANTOOL_PASSWORD}
      TARANTOOL_SPACE: ${TARANTOOL_SPACE}
      TARANTOOL_MEMTX_MEMORY: "${TARANTOOL_MEMTX_MEMORY}"
      TARANTOOL_WAL_MODE: ${TARANTOOL_WAL_MODE}
    ports:
      - "${TARANTOOL_PORT}:3301"
    volumes:
      - tarantool-vshard-router-data:/var/lib/tarantool
    networks:
      - ${NETWORK_NAME}
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: "${TARANTOOL_ROUTER_CPU_LIMIT}"
          memory: ${TARANTOOL_MEMORY_LIMIT}

EOF2

            for shard in $(seq 1 "$shards"); do
                local host_port=$((TARANTOOL_PORT + shard))
                local instance_uuid
                instance_uuid=$(printf '22222222-2222-2222-2222-%012d' "$shard")

                cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  tarantool-vshard-storage-${shard}:
    build:
      context: ./tarantool
      dockerfile: Dockerfile
    image: ${TARANTOOL_IMAGE}
    container_name: tarantool-vshard-storage-${shard}
    environment:
      TARANTOOL_NODE_NAME: tarantool-vshard-storage-${shard}
      TARANTOOL_TOPOLOGY: ${TARANTOOL_TOPOLOGY}
      TARANTOOL_ROLE: storage
      TARANTOOL_VSHARD_ROLE: storage
      TARANTOOL_INSTANCE_UUID: "${instance_uuid}"
      TARANTOOL_READ_ONLY: "false"
      TARANTOOL_USER: ${TARANTOOL_USER}
      TARANTOOL_PASSWORD: ${TARANTOOL_PASSWORD}
      TARANTOOL_SPACE: ${TARANTOOL_SPACE}
      TARANTOOL_MEMTX_MEMORY: "${TARANTOOL_MEMTX_MEMORY}"
      TARANTOOL_WAL_MODE: ${TARANTOOL_WAL_MODE}
    ports:
      - "${host_port}:3301"
    volumes:
      - tarantool-vshard-storage-${shard}-data:/var/lib/tarantool
    networks:
      - ${NETWORK_NAME}
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: "${TARANTOOL_STORAGE_CPU_LIMIT}"
          memory: ${TARANTOOL_MEMORY_LIMIT}

EOF2
            done
            ;;
    esac
}

append_postgres_compose() {
    if ! enabled postgres; then
        return 0
    fi

    cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
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
    deploy:
      resources:
        limits:
          cpus: "${POSTGRES_CPU_LIMIT}"
          memory: ${POSTGRES_MEMORY_LIMIT}

EOF2
}

append_ydb_compose() {
    if ! enabled ydb; then
        return 0
    fi

    cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
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
    deploy:
      resources:
        limits:
          cpus: "${YDB_CPU_LIMIT}"
          memory: ${YDB_MEMORY_LIMIT}

EOF2
}

append_volumes() {
    cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
networks:
  ${NETWORK_NAME}:
    driver: bridge

volumes:
EOF2

    if enabled redis; then
        case "$REDIS_TOPOLOGY" in
            single)
                cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  redis-data:
EOF2
                ;;
            replication2)
                cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  redis-master-data:
  redis-replica-1-data:
EOF2
                ;;
            replication4)
                cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  redis-master-data:
  redis-replica-1-data:
  redis-replica-2-data:
  redis-replica-3-data:
EOF2
                ;;
            sharding2)
                cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  redis-shard-1-data:
  redis-shard-2-data:
EOF2
                ;;
            sharding4)
                cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  redis-shard-1-data:
  redis-shard-2-data:
  redis-shard-3-data:
  redis-shard-4-data:
EOF2
                ;;
            sharding_replication4)
                cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  redis-s1-master-data:
  redis-s1-replica-data:
  redis-s2-master-data:
  redis-s2-replica-data:
EOF2
                ;;
            cluster_sharding3)
                cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  redis-cluster-1-data:
  redis-cluster-2-data:
  redis-cluster-3-data:
EOF2
                ;;
            cluster_sharding4)
                cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  redis-cluster-1-data:
  redis-cluster-2-data:
  redis-cluster-3-data:
  redis-cluster-4-data:
EOF2
                ;;
            cluster_sharding_replication6)
                cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  redis-cluster-1-data:
  redis-cluster-2-data:
  redis-cluster-3-data:
  redis-cluster-4-data:
  redis-cluster-5-data:
  redis-cluster-6-data:
EOF2
                ;;
        esac
    fi

    if enabled tarantool; then
        case "$TARANTOOL_TOPOLOGY" in
            single)
                cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  tarantool-data:
EOF2
                ;;
            replication2)
                cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  tarantool-master-data:
  tarantool-replica-1-data:
EOF2
                ;;
            replication4)
                cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  tarantool-master-data:
  tarantool-replica-1-data:
  tarantool-replica-2-data:
  tarantool-replica-3-data:
EOF2
                ;;
            sharding2)
                cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  tarantool-shard-1-data:
  tarantool-shard-2-data:
EOF2
                ;;
            sharding4)
                cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  tarantool-shard-1-data:
  tarantool-shard-2-data:
  tarantool-shard-3-data:
  tarantool-shard-4-data:
EOF2
                ;;
            sharding_replication4)
                cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  tarantool-s1-r1-data:
  tarantool-s1-r2-data:
  tarantool-s2-r1-data:
  tarantool-s2-r2-data:
EOF2
                ;;
            vshard2|vshard3|vshard4)
                cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  tarantool-vshard-router-data:
EOF2
                local shards
                shards="$(tarantool_vshard_shard_count)"
                for shard in $(seq 1 "$shards"); do
                    cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  tarantool-vshard-storage-${shard}-data:
EOF2
                done
                ;;
        esac
    fi

    if enabled postgres; then
        cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  postgres-data:
EOF2
    fi

    if enabled ydb; then
        cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF2
  ydb-certs:
  ydb-data:
EOF2
    fi
}

write_compose_generated() {
    log "Generating docker-compose.yml"

    cat > "$PROJECT_DIR/docker-compose.yml" <<EOF2
services:
EOF2

    append_redis_compose
    append_tarantool_compose
    append_postgres_compose
    append_ydb_compose
    append_volumes
}

write_compose() {
    if write_compose_from_custom_file; then
        return 0
    fi

    write_compose_generated
}

# ------------------------------------------------------------
# Build / Start
# ------------------------------------------------------------

build_images() {
    log "Building images"

    (
        cd "$PROJECT_DIR"

        if enabled tarantool; then
            if is_true "$BUILD_NO_CACHE"; then
                docker compose build --no-cache
            else
                docker compose build
            fi
        else
            echo "No locally built services selected."
        fi
    )
}

start_containers() {
    if ! is_true "$START_CONTAINERS"; then
        log "START_CONTAINERS=0, containers are not started"
        return 0
    fi

    log "Starting containers"

    (
        cd "$PROJECT_DIR"
        docker compose up -d --force-recreate
    )
}

init_redis_cluster_if_needed() {
    if ! enabled redis; then
        return 0
    fi

    if ! redis_is_cluster_topology; then
        return 0
    fi

    log "Initializing Redis Cluster, topology=${REDIS_TOPOLOGY}"

    local nodes
    nodes="$(redis_cluster_node_count)"

    local replicas
    replicas="$(redis_cluster_replicas)"

    for i in $(seq 1 "$nodes"); do
        local port=$((REDIS_CLUSTER_BASE_PORT + i - 1))
        local container="redis-cluster-${i}"

        for attempt in {1..60}; do
            if docker exec "$container" redis-cli -p "$port" ping 2>/dev/null | grep -q PONG; then
                echo "${container} is ready on port ${port}."
                break
            fi

            if [[ "$attempt" -eq 60 ]]; then
                echo "${container} did not start."
                docker logs "$container" || true
                exit 1
            fi

            sleep 1
        done
    done

    local first_port="$REDIS_CLUSTER_BASE_PORT"

    if docker exec redis-cluster-1 redis-cli -p "$first_port" cluster info 2>/dev/null | grep -q 'cluster_state:ok'; then
        echo "Redis Cluster is already initialized."
        return 0
    fi

    local cluster_nodes=()
    for i in $(seq 1 "$nodes"); do
        local port=$((REDIS_CLUSTER_BASE_PORT + i - 1))
        cluster_nodes+=("127.0.0.1:${port}")
    done

    docker exec redis-cluster-1 redis-cli \
        --cluster create "${cluster_nodes[@]}" \
        --cluster-replicas "$replicas" \
        --cluster-yes

    echo "Waiting for cluster_state:ok..."

    for _ in {1..60}; do
        if docker exec redis-cluster-1 redis-cli -p "$first_port" cluster info 2>/dev/null | grep -q 'cluster_state:ok'; then
            echo "Redis Cluster is ready."
            return 0
        fi

        sleep 1
    done

    echo "Redis Cluster did not become cluster_state:ok"
    docker exec redis-cluster-1 redis-cli -p "$first_port" cluster info || true
    docker exec redis-cluster-1 redis-cli -p "$first_port" cluster nodes || true
    exit 1
}

# ------------------------------------------------------------
# Redis verification
# ------------------------------------------------------------

verify_redis_single() {
    for i in {1..30}; do
        if docker exec "$REDIS_CONTAINER" redis-cli ping 2>/dev/null | grep -q PONG; then
            echo "Redis is ready."
            break
        fi

        if [[ "$i" -eq 30 ]]; then
            docker compose -f "$PROJECT_DIR/docker-compose.yml" logs redis
            exit 1
        fi

        sleep 1
    done

    docker exec "$REDIS_CONTAINER" redis-cli SET test_key "hello_redis"
    docker exec "$REDIS_CONTAINER" redis-cli GET test_key
}

verify_redis_replication() {
    for i in {1..30}; do
        if docker exec redis-master redis-cli ping 2>/dev/null | grep -q PONG; then
            echo "Redis master is ready."
            break
        fi

        if [[ "$i" -eq 30 ]]; then
            docker compose -f "$PROJECT_DIR/docker-compose.yml" logs redis-master
            exit 1
        fi

        sleep 1
    done

    docker exec redis-master redis-cli SET test_key "hello_redis_replication"
    docker exec redis-master redis-cli GET test_key

    echo
    echo "Redis replication info:"
    docker exec redis-master redis-cli INFO replication | grep -E 'role|connected_slaves' || true
}

verify_redis_sharding() {
    local shards
    shards="$(redis_shard_count)"

    for shard in $(seq 1 "$shards"); do
        local container="redis-shard-${shard}"

        for i in {1..30}; do
            if docker exec "$container" redis-cli ping 2>/dev/null | grep -q PONG; then
                echo "$container is ready."
                break
            fi

            if [[ "$i" -eq 30 ]]; then
                docker compose -f "$PROJECT_DIR/docker-compose.yml" logs "$container"
                exit 1
            fi

            sleep 1
        done

        docker exec "$container" redis-cli SET "test_key_${shard}" "hello_redis_shard_${shard}"
        docker exec "$container" redis-cli GET "test_key_${shard}"
    done
}

verify_redis_sharding_replication4() {
    for shard in 1 2; do
        local master="redis-s${shard}-master"
        local replica="redis-s${shard}-replica"

        for i in {1..30}; do
            if docker exec "$master" redis-cli ping 2>/dev/null | grep -q PONG; then
                echo "$master is ready."
                break
            fi

            if [[ "$i" -eq 30 ]]; then
                docker compose -f "$PROJECT_DIR/docker-compose.yml" logs "$master"
                exit 1
            fi

            sleep 1
        done

        docker exec "$master" redis-cli SET "test_key_s${shard}" "hello_redis_s${shard}"
        docker exec "$master" redis-cli GET "test_key_s${shard}"

        echo
        echo "Replication info for $master:"
        docker exec "$master" redis-cli INFO replication | grep -E 'role|connected_slaves' || true

        echo
        echo "Replica info for $replica:"
        docker exec "$replica" redis-cli INFO replication | grep -E 'role|master_host|master_port|master_link_status' || true
    done
}

verify_redis_cluster() {
    local nodes
    nodes="$(redis_cluster_node_count)"

    local first_port="$REDIS_CLUSTER_BASE_PORT"

    for i in $(seq 1 "$nodes"); do
        local port=$((REDIS_CLUSTER_BASE_PORT + i - 1))
        local container="redis-cluster-${i}"

        for attempt in {1..60}; do
            if docker exec "$container" redis-cli -p "$port" ping 2>/dev/null | grep -q PONG; then
                echo "$container is ready."
                break
            fi

            if [[ "$attempt" -eq 60 ]]; then
                docker logs "$container" || true
                exit 1
            fi

            sleep 1
        done
    done

    docker exec redis-cluster-1 redis-cli -p "$first_port" cluster info
    docker exec redis-cluster-1 redis-cli -p "$first_port" cluster nodes

    echo
    echo "Redis Cluster read/write check:"

    docker exec redis-cluster-1 redis-cli -c -p "$first_port" SET test_key "hello_redis_cluster"
    docker exec redis-cluster-1 redis-cli -c -p "$first_port" GET test_key
}

verify_redis() {
    if ! enabled redis; then
        return 0
    fi

    log "Waiting for Redis, topology=${REDIS_TOPOLOGY}"

    case "$REDIS_TOPOLOGY" in
        single)
            verify_redis_single
            ;;
        replication2|replication4)
            verify_redis_replication
            ;;
        sharding2|sharding4)
            verify_redis_sharding
            ;;
        sharding_replication4)
            verify_redis_sharding_replication4
            ;;
        cluster_sharding3|cluster_sharding4|cluster_sharding_replication6)
            verify_redis_cluster
            ;;
    esac
}

# ------------------------------------------------------------
# Tarantool verification
# ------------------------------------------------------------

tarantool_containers_for_topology() {
    case "$TARANTOOL_TOPOLOGY" in
        single)
            echo "$TARANTOOL_CONTAINER"
            ;;
        replication2)
            echo "tarantool-master tarantool-replica-1"
            ;;
        replication4)
            echo "tarantool-master tarantool-replica-1 tarantool-replica-2 tarantool-replica-3"
            ;;
        sharding2)
            echo "tarantool-shard-1 tarantool-shard-2"
            ;;
        sharding4)
            echo "tarantool-shard-1 tarantool-shard-2 tarantool-shard-3 tarantool-shard-4"
            ;;
        sharding_replication4)
            echo "tarantool-s1-r1 tarantool-s1-r2 tarantool-s2-r1 tarantool-s2-r2"
            ;;
        vshard2|vshard3|vshard4)
            local shards
            shards="$(tarantool_vshard_shard_count)"
            local containers="tarantool-vshard-router"
            for shard in $(seq 1 "$shards"); do
                containers="${containers} tarantool-vshard-storage-${shard}"
            done
            echo "$containers"
            ;;
    esac
}

tarantool_check_container() {
    case "$TARANTOOL_TOPOLOGY" in
        single) echo "$TARANTOOL_CONTAINER" ;;
        replication2|replication4) echo "tarantool-master" ;;
        sharding2|sharding4) echo "tarantool-shard-1" ;;
        sharding_replication4) echo "tarantool-s1-r1" ;;
        vshard2|vshard3|vshard4) echo "tarantool-vshard-router" ;;
    esac
}

wait_tarantool_container() {
    local container="$1"

    for i in {1..60}; do
        if docker exec "$container" sh -c "
            unset TT_APP_NAME TT_INSTANCE_NAME TT_CONFIG TT_CONFIG_ETCD_ENDPOINTS

            tarantool -e '
                local net_box = require(\"net.box\")
                local c = net_box.connect(\"${TARANTOOL_USER}:${TARANTOOL_PASSWORD}@127.0.0.1:3301\", {
                    wait_connected = false
                })

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

        if [[ "$i" -eq 60 ]]; then
            echo "Tarantool did not start: $container"
            docker logs "$container" || true
            return 1
        fi

        sleep 1
    done
}

verify_tarantool() {
    if ! enabled tarantool; then
        return 0
    fi

    log "Waiting for Tarantool, topology=${TARANTOOL_TOPOLOGY}"

    local container
    for container in $(tarantool_containers_for_topology); do
        wait_tarantool_container "$container"
    done

    local check_container
    check_container="$(tarantool_check_container)"

    log "Actual Tarantool run configuration"
    docker inspect "$check_container" --format '
Image={{.Config.Image}}
Entrypoint={{json .Config.Entrypoint}}
Cmd={{json .Config.Cmd}}
Env={{json .Config.Env}}
' || true

    log "Tarantool read/write check"

    docker exec "$check_container" sh -c "
        unset TT_APP_NAME TT_INSTANCE_NAME TT_CONFIG TT_CONFIG_ETCD_ENDPOINTS

        tarantool -e '
            local net_box = require(\"net.box\")
            local json = require(\"json\")

            local c = net_box.connect(\"${TARANTOOL_USER}:${TARANTOOL_PASSWORD}@127.0.0.1:3301\", {
                wait_connected = false
            })

            if not c:wait_connected(5) then
                error(\"Cannot connect to Tarantool: \" .. tostring(c.error))
            end

            c:call(\"put\", {\"test_key\", \"hello_tarantool\"})
            local result = c:call(\"get\", {\"test_key\"})

            print(json.encode(result))

            c:close()
        '
    "

    echo
    echo "Tarantool containers:"
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep tarantool || true

    echo
    echo "Main Tarantool container logs:"
    docker logs --tail=30 "$check_container" || true
}

# ------------------------------------------------------------
# PostgreSQL / YDB verification
# ------------------------------------------------------------

verify_postgres() {
    if ! enabled postgres; then
        return 0
    fi

    log "Waiting for PostgreSQL"

    for i in {1..60}; do
        if docker exec "$POSTGRES_CONTAINER" pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
            echo "PostgreSQL is ready."
            break
        fi

        if [[ "$i" -eq 60 ]]; then
            echo "PostgreSQL did not start."
            docker compose -f "$PROJECT_DIR/docker-compose.yml" logs postgres
            exit 1
        fi

        sleep 1
    done

    local actual_max_connections
    actual_max_connections="$(docker exec "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SHOW max_connections;")"
    echo "PostgreSQL max_connections: ${actual_max_connections}"

    if [[ "$actual_max_connections" != "$POSTGRES_MAX_CONNECTIONS" ]]; then
        die "PostgreSQL max_connections mismatch: expected ${POSTGRES_MAX_CONNECTIONS}, got ${actual_max_connections}"
    fi

    log "PostgreSQL read/write check"

    docker exec "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
        INSERT INTO ${POSTGRES_TABLE}(key, value)
        VALUES ('test_key', 'hello_postgres')
        ON CONFLICT (key)
        DO UPDATE SET value = EXCLUDED.value;
    "

    docker exec "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
        SELECT * FROM ${POSTGRES_TABLE} WHERE key = 'test_key';
    "
}

verify_ydb() {
    if ! enabled ydb; then
        return 0
    fi

    log "Waiting for YDB"

    if wait_tcp "127.0.0.1" "$YDB_GRPC_PORT" "YDB gRPC"; then
        echo "YDB gRPC port is available."
    else
        echo "YDB did not start."
        docker compose -f "$PROJECT_DIR/docker-compose.yml" logs ydb
        exit 1
    fi

    log "YDB check"
    echo "YDB endpoint: grpc://localhost:${YDB_GRPC_PORT}/local"
    echo "YDB Web UI: http://localhost:${YDB_MON_PORT}"
}

verify_all() {
    if ! is_true "$VERIFY"; then
        log "VERIFY=0, checks skipped"
        return 0
    fi

    verify_redis
    verify_tarantool
    verify_postgres
    verify_ydb
}

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

print_redis_summary() {
    if ! enabled redis; then
        return 0
    fi

    echo
    echo "Redis:"
    echo "  topology: ${REDIS_TOPOLOGY}"

    case "$REDIS_TOPOLOGY" in
        single)
            echo "  mode: single-node"
            echo "  host: localhost"
            echo "  port: ${REDIS_PORT}"
            echo "  container: ${REDIS_CONTAINER}"
            ;;
        replication2|replication4)
            echo "  mode: master-replica"
            echo "  master: localhost:${REDIS_PORT}, container: redis-master"
            local replica_count=1
            if [[ "$REDIS_TOPOLOGY" == "replication4" ]]; then
                replica_count=3
            fi
            for i in $(seq 1 "$replica_count"); do
                echo "  replica ${i}: localhost:$((REDIS_PORT + i)), container: redis-replica-${i}"
            done
            ;;
        sharding2|sharding4)
            echo "  mode: manual/client-side sharding"
            local shards
            shards="$(redis_shard_count)"
            for i in $(seq 1 "$shards"); do
                echo "  shard ${i}: localhost:$((REDIS_SHARD_BASE_PORT + i - 1)), container: redis-shard-${i}"
            done
            ;;
        sharding_replication4)
            echo "  mode: manual sharding + replication, 2 shards x 2 nodes"
            for shard in 1 2; do
                local master_port=$((REDIS_SHARD_BASE_PORT + (shard - 1) * 2))
                local replica_port=$((master_port + 1))
                echo "  shard ${shard} master:  localhost:${master_port}, container: redis-s${shard}-master"
                echo "  shard ${shard} replica: localhost:${replica_port}, container: redis-s${shard}-replica"
            done
            ;;
        cluster_sharding3|cluster_sharding4|cluster_sharding_replication6)
            echo "  mode: Redis Cluster"
            echo "  cluster nodes: $(redis_cluster_node_count)"
            echo "  replicas per master: $(redis_cluster_replicas)"
            echo "  client addrs:"
            local nodes
            nodes="$(redis_cluster_node_count)"
            for i in $(seq 1 "$nodes"); do
                echo "    127.0.0.1:$((REDIS_CLUSTER_BASE_PORT + i - 1))  container: redis-cluster-${i}"
            done
            ;;
    esac
}

print_tarantool_summary() {
    if ! enabled tarantool; then
        return 0
    fi

    echo
    echo "Tarantool:"
    echo "  topology: ${TARANTOOL_TOPOLOGY}"
    echo "  user: ${TARANTOOL_USER}"
    echo "  password: ${TARANTOOL_PASSWORD}"
    echo "  space: ${TARANTOOL_SPACE}"

    case "$TARANTOOL_TOPOLOGY" in
        single)
            echo "  host: localhost"
            echo "  port: ${TARANTOOL_PORT}"
            echo "  container: ${TARANTOOL_CONTAINER}"
            ;;
        replication2|replication4)
            echo "  master: localhost:${TARANTOOL_PORT}, container: tarantool-master"
            local replica_count=1
            if [[ "$TARANTOOL_TOPOLOGY" == "replication4" ]]; then
                replica_count=3
            fi
            for i in $(seq 1 "$replica_count"); do
                echo "  replica ${i}: localhost:$((TARANTOOL_PORT + i)), container: tarantool-replica-${i}"
            done
            ;;
        sharding2|sharding4)
            echo "  mode: manual router by hash(key), not vshard"
            local shards
            shards="$(tarantool_shard_count)"
            for i in $(seq 1 "$shards"); do
                echo "  shard ${i}: localhost:$((TARANTOOL_PORT + i - 1)), container: tarantool-shard-${i}"
            done
            ;;
        sharding_replication4)
            echo "  mode: manual router + replication, 2 shards x 2 nodes"
            for shard in 1 2; do
                for replica in 1 2; do
                    local role="replica"
                    if [[ "$replica" == "1" ]]; then
                        role="master"
                    fi
                    local node_index=$(((shard - 1) * 2 + replica))
                    echo "  shard ${shard} ${role}: localhost:$((TARANTOOL_PORT + node_index - 1)), container: tarantool-s${shard}-r${replica}"
                done
            done
            ;;
        vshard2|vshard3|vshard4)
            echo "  mode: vshard router + storage nodes"
            echo "  bucket_count: ${TARANTOOL_VSHARD_BUCKET_COUNT}"
            echo "  router: localhost:${TARANTOOL_PORT}, container: tarantool-vshard-router, cpu: ${TARANTOOL_ROUTER_CPU_LIMIT}"
            local shards
            shards="$(tarantool_vshard_shard_count)"
            for shard in $(seq 1 "$shards"); do
                echo "  storage ${shard}: localhost:$((TARANTOOL_PORT + shard)), container: tarantool-vshard-storage-${shard}, cpu: ${TARANTOOL_STORAGE_CPU_LIMIT}"
            done
            ;;
    esac
}

print_summary() {
    log "Containers"

    (
        cd "$PROJECT_DIR"
        docker compose ps
    )

    echo
    echo "Done."
    echo
    echo "Project:"
    echo "  path: $PROJECT_DIR"
    echo "  targets: $DEPLOY_TARGETS"

    print_redis_summary
    print_tarantool_summary

    if enabled postgres; then
        echo
        echo "PostgreSQL:"
        echo "  host: localhost"
        echo "  port: ${POSTGRES_PORT}"
        echo "  user: ${POSTGRES_USER}"
        echo "  password: ${POSTGRES_PASSWORD}"
        echo "  database: ${POSTGRES_DB}"
        echo "  table: ${POSTGRES_TABLE}"
        echo "  max_connections: ${POSTGRES_MAX_CONNECTIONS}"
        echo "  container: ${POSTGRES_CONTAINER}"
        echo "  conn: postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=disable"
    fi

    if enabled ydb; then
        echo
        echo "YDB:"
        echo "  gRPC: grpc://localhost:${YDB_GRPC_PORT}/local"
        echo "  Web UI: http://localhost:${YDB_MON_PORT}"
        echo "  container: ${YDB_CONTAINER}"
    fi
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

normalize_targets
normalize_topologies
validate_targets
validate_topologies
validate_postgres_config

log "Run parameters"
echo "PROJECT_DIR=$PROJECT_DIR"
echo "DEPLOY_TARGETS=$DEPLOY_TARGETS"
echo "REDIS_TOPOLOGY=$REDIS_TOPOLOGY"
echo "TARANTOOL_TOPOLOGY=$TARANTOOL_TOPOLOGY"
echo "CONFIG_DIR=${CONFIG_DIR:-<empty>}"
echo "CUSTOM_COMPOSE_FILE=${CUSTOM_COMPOSE_FILE:-<empty>}"
echo "CLEAN_PROJECT=$CLEAN_PROJECT"
echo "REMOVE_VOLUMES=$REMOVE_VOLUMES"
echo "REMOVE_IMAGES=$REMOVE_IMAGES"
echo "BUILD_NO_CACHE=$BUILD_NO_CACHE"
echo "START_CONTAINERS=$START_CONTAINERS"
echo "VERIFY=$VERIFY"

compose_down_old
remove_old_containers
remove_old_images
prepare_project_dir

write_redis_config
write_tarantool_files
write_postgres_files
write_compose

build_images
start_containers
init_redis_cluster_if_needed
verify_all
print_summary
