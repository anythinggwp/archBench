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

## Basic examples

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

## Sequential benchmark runs

Repeat the same benchmark configuration several times:

```bash
./dbbench bench \
  --target all \
  --operation all \
  --requests 100000 \
  --concurrency 64 \
  --value-size 128 \
  --runs 5 \
  --run-delay 2s \
  --output-file repeat-results.json \
  --file-format json
```

Run a sequence with different concurrency values:

```bash
./dbbench bench \
  --target all \
  --operation all \
  --requests 100000 \
  --concurrency-list 1,8,16,32,64 \
  --value-size 128 \
  --output-file concurrency-results.csv \
  --file-format csv
```

Run a matrix of several request counts, concurrency levels, and value sizes:

```bash
./dbbench bench \
  --target all \
  --operation all \
  --requests-list 10000,50000,100000 \
  --concurrency-list 1,8,32 \
  --value-size-list 64,128,1024 \
  --runs 3 \
  --run-delay 1s \
  --output-file matrix-results.csv \
  --file-format csv
```

The list flags override the single-value flags:

- `--requests-list` overrides `--requests`;
- `--concurrency-list` overrides `--concurrency`;
- `--value-size-list` overrides `--value-size`.

Each generated test receives its own `run` number. The `run` field is printed in the terminal table and written to JSON/CSV output.


## Summary mode

Use `--summary` to print and save aggregated results after several sequential runs.
The summary groups rows by:

```text
target + operation + requests + concurrency + value_size
```

For each group it calculates:

- number of runs;
- total successful and failed operations;
- average/min/max duration;
- average/min/max throughput;
- average/min/max average latency;
- minimum observed latency across runs;
- maximum observed latency across runs;
- average p50/p95/p99 latency.

Example: repeat the same Redis GET benchmark five times and print summary:

```bash
./dbbench bench \
  --target redis \
  --operation get \
  --requests 100000 \
  --concurrency 64 \
  --value-size 128 \
  --runs 5 \
  --summary
```

Example: run several concurrency levels and save raw rows plus summary rows to CSV:

```bash
./dbbench bench \
  --target all \
  --operation all \
  --requests 100000 \
  --concurrency-list 1,8,16,32,64 \
  --runs 3 \
  --summary \
  --output-file results-with-summary.csv \
  --file-format csv
```

When `--file-format json` is used with `--summary`, the output file has this structure:

```json
{
  "results": [
    "raw benchmark rows"
  ],
  "summary": [
    "aggregated rows"
  ]
}
```

When `--file-format csv` is used, the first column is `record_type`:

```text
result   — raw benchmark run
summary  — aggregated row
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
