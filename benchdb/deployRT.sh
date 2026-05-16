#!/bin/bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-redis-tarantool-stack}"

echo "Останавливаю и удаляю старые контейнеры..."

if [ -d "$PROJECT_DIR" ] && [ -f "$PROJECT_DIR/docker-compose.yml" ]; then
    cd "$PROJECT_DIR"
    docker compose down -v --remove-orphans 2>/dev/null || true
    cd ..
fi

docker rm -f redis-node 2>/dev/null || true
docker rm -f tarantool-node 2>/dev/null || true
docker rm -f tarantool-single-node 2>/dev/null || true

echo "Удаляю старый локальный образ Tarantool..."

docker image rm -f local-tarantool-single:3 2>/dev/null || true

echo "Удаляю старый каталог проекта..."

rm -rf "$PROJECT_DIR"

echo "Создаю структуру проекта..."

mkdir -p "$PROJECT_DIR/redis"
mkdir -p "$PROJECT_DIR/tarantool"

cat > "$PROJECT_DIR/redis/redis.conf" <<'EOF'
bind 0.0.0.0
port 6379

protected-mode no

appendonly yes
appendfilename "appendonly.aof"
dir /data

save 60 1000

loglevel notice
EOF

cat > "$PROJECT_DIR/tarantool/init.lua" <<'EOF'
box.cfg{
    listen = '0.0.0.0:3301',

    memtx_memory = 128 * 1024 * 1024,

    wal_mode = 'write',

    memtx_dir = '/var/lib/tarantool',
    wal_dir = '/var/lib/tarantool',
    vinyl_dir = '/var/lib/tarantool'
}

box.once('bootstrap_v1', function()
    box.schema.user.create('app', {
        password = 'app_pass',
        if_not_exists = true
    })

    box.schema.user.grant(
        'app',
        'read,write,execute',
        'universe',
        nil,
        {if_not_exists = true}
    )

    local kv = box.schema.space.create('kv', {
        if_not_exists = true
    })

    kv:format({
        {name = 'key', type = 'string'},
        {name = 'value', type = 'string'}
    })

    kv:create_index('primary', {
        type = 'HASH',
        parts = {'key'},
        if_not_exists = true
    })
end)

rawset(_G, 'put', function(key, value)
    return box.space.kv:replace{key, value}
end)

rawset(_G, 'get', function(key)
    return box.space.kv:get{key}
end)

print('Tarantool single-node started on 0.0.0.0:3301')
EOF

cat > "$PROJECT_DIR/tarantool/start.sh" <<'EOF'
#!/bin/sh
set -eu

unset TT_APP_NAME
unset TT_INSTANCE_NAME
unset TT_CONFIG
unset TT_CONFIG_ETCD_ENDPOINTS

exec tarantool /opt/tarantool/init.lua
EOF

cat > "$PROJECT_DIR/tarantool/Dockerfile" <<'EOF'
FROM tarantool/tarantool:3

COPY init.lua /opt/tarantool/init.lua
COPY start.sh /usr/local/bin/start-tarantool-single

RUN chmod +x /usr/local/bin/start-tarantool-single

ENTRYPOINT ["/usr/local/bin/start-tarantool-single"]
EOF

cat > "$PROJECT_DIR/docker-compose.yml" <<'EOF'
services:
  redis:
    image: redis:7-alpine
    container_name: redis-node
    command: ["redis-server", "/usr/local/etc/redis/redis.conf"]
    ports:
      - "6379:6379"
    volumes:
      - ./redis/redis.conf:/usr/local/etc/redis/redis.conf:ro
      - redis-data:/data
    networks:
      - db-net
    restart: unless-stopped

  tarantool:
    build:
      context: ./tarantool
      dockerfile: Dockerfile
    image: local-tarantool-single:3
    container_name: tarantool-single-node
    ports:
      - "3301:3301"
    volumes:
      - tarantool-data:/var/lib/tarantool
    networks:
      - db-net
    restart: unless-stopped

networks:
  db-net:
    driver: bridge

volumes:
  redis-data:
  tarantool-data:
EOF

cd "$PROJECT_DIR"

echo "Собираю Tarantool без кэша..."

docker compose build --no-cache tarantool

echo "Запускаю контейнеры..."

docker compose up -d --force-recreate

echo
echo "Фактический запуск Tarantool:"
docker inspect tarantool-single-node --format '
Image={{.Config.Image}}
Entrypoint={{json .Config.Entrypoint}}
Cmd={{json .Config.Cmd}}
Env={{json .Config.Env}}
'

echo
echo "Ожидание Redis..."

for i in {1..30}; do
    if docker exec redis-node redis-cli ping 2>/dev/null | grep -q PONG; then
        echo "Redis готов."
        break
    fi

    if [ "$i" -eq 30 ]; then
        echo "Redis не запустился."
        docker compose logs redis
        exit 1
    fi

    sleep 1
done

echo
echo "Ожидание Tarantool..."

for i in {1..30}; do
    if docker exec tarantool-single-node sh -c '
        unset TT_APP_NAME TT_INSTANCE_NAME TT_CONFIG TT_CONFIG_ETCD_ENDPOINTS

        tarantool -e "
            local net_box = require(\"net.box\")

            local c = net_box.connect(\"app:app_pass@127.0.0.1:3301\", {
                wait_connected = false
            })

            if c:wait_connected(1) then
                c:close()
                os.exit(0)
            end

            os.exit(1)
        "
    ' >/dev/null 2>&1; then
        echo "Tarantool готов."
        break
    fi

    if [ "$i" -eq 30 ]; then
        echo "Tarantool не запустился."
        echo
        echo "Логи Tarantool:"
        docker compose logs tarantool
        exit 1
    fi

    sleep 1
done

echo
echo "Контейнеры:"
docker compose ps

echo
echo "Проверка Redis:"
docker exec redis-node redis-cli SET test_key "hello_redis"
docker exec redis-node redis-cli GET test_key

echo
echo "Проверка Tarantool:"
docker exec tarantool-single-node sh -c '
unset TT_APP_NAME TT_INSTANCE_NAME TT_CONFIG TT_CONFIG_ETCD_ENDPOINTS

tarantool -e "
local net_box = require(\"net.box\")
local json = require(\"json\")

local c = net_box.connect(\"app:app_pass@127.0.0.1:3301\", {
    wait_connected = false
})

if not c:wait_connected(5) then
    error(\"Cannot connect to Tarantool: \" .. tostring(c.error))
end

c:call(\"put\", {\"test_key\", \"hello_tarantool\"})
local result = c:call(\"get\", {\"test_key\"})

print(json.encode(result))

c:close()
"
'

echo
echo "Логи Tarantool:"
docker logs --tail=30 tarantool-single-node

echo
echo "Готово."
echo
echo "Redis:"
echo "  host: localhost"
echo "  port: 6379"
echo
echo "Tarantool:"
echo "  host: localhost"
echo "  port: 3301"
echo "  user: app"
echo "  password: app_pass"
echo "  container: tarantool-single-node"