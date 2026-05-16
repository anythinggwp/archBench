# redis-tarantool-bench

CLI benchmark for Redis and Tarantool key-value SET/GET operations.

## Install dependencies

```bash
go mod tidy
```

The project uses:

- `github.com/spf13/cobra` for CLI;
- `github.com/redis/go-redis/v9` for Redis;
- `github.com/tarantool/go-tarantool/v2` for Tarantool.

## Build

```bash
go build -o dbbench .
```

## Examples

Run all benchmarks and print results:

```bash
./dbbench bench \
  --target all \
  --operation all \
  --requests 100000 \
  --concurrency 64 \
  --value-size 128
```

Run only Redis SET and save JSON:

```bash
./dbbench bench \
  --target redis \
  --operation set \
  --redis-addr 127.0.0.1:6379 \
  --requests 100000 \
  --concurrency 64 \
  --output-file redis-set.json \
  --file-format json
```

Run only Tarantool GET and save CSV while also printing table:

```bash
./dbbench bench \
  --target tarantool \
  --operation get \
  --tarantool-addr 127.0.0.1:3301 \
  --tarantool-user guest \
  --tarantool-space kv \
  --requests 100000 \
  --concurrency 64 \
  --output-file tarantool-get.csv \
  --file-format csv
```

## Tarantool schema

By default, the benchmark tries to create this space automatically:

```lua
box.schema.space.create('kv', {if_not_exists = true})
box.space.kv:format({
  {name = 'key', type = 'string'},
  {name = 'value', type = 'string'},
})
box.space.kv:create_index('primary', {
  parts = {{field = 'key', type = 'string'}},
  if_not_exists = true,
})
```

If your Tarantool user has no DDL permissions, create the space manually and run with:

```bash
--tarantool-no-ddl
```
