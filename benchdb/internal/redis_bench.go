package internal

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

func RunRedis(ctx context.Context, cfg Config, operation Operation) (Result, error) {
	client, err := newRedisBenchmarkClient(cfg)
	if err != nil {
		return Result{}, err
	}
	defer client.Close()

	pingCtx, cancel := context.WithTimeout(ctx, cfg.Timeout)
	defer cancel()
	if err := client.Ping(pingCtx).Err(); err != nil {
		return Result{}, fmt.Errorf("redis ping failed: %w", err)
	}

	switch operation {
	case OperationSet:
		if normalizeSetMode(cfg.SetMode) == "versioned" {
			return runRedisVersionedSet(ctx, client, cfg), nil
		}
		return runRedisSet(ctx, client, cfg), nil
	case OperationGet:
		if err := preloadRedis(ctx, client, cfg); err != nil {
			return Result{}, err
		}
		return runRedisGet(ctx, client, cfg), nil
	default:
		return Result{}, fmt.Errorf("unsupported redis operation: %s", operation)
	}
}

func runRedisSet(ctx context.Context, client redis.UniversalClient, cfg Config) Result {
	return runMeasured(ctx, TargetRedis, OperationSet, cfg, func(key string, value string) error {
		return client.Set(ctx, key, value, 0).Err()
	})
}

const redisVersionedSetScript = `
local current = redis.call('GET', KEYS[1])
local new_version = string.sub(ARGV[1], 1, tonumber(ARGV[2]))

if current ~= false and string.sub(current, 1, tonumber(ARGV[2])) == new_version then
    return 0
end

redis.call('SET', KEYS[1], ARGV[1])
return 1
`

func runRedisVersionedSet(ctx context.Context, client redis.UniversalClient, cfg Config) Result {
	return runMeasuredIndexed(ctx, TargetRedis, OperationSet, cfg, func(idx int) (string, string) {
		return makeVersionedSetKeyValue(cfg, TargetRedis, idx)
	}, func(_ int, key string, value string) error {
		return client.Eval(ctx, redisVersionedSetScript, []string{key}, value, versionedValueHeaderLen).Err()
	})
}

func runRedisGet(ctx context.Context, client redis.UniversalClient, cfg Config) Result {
	return runMeasured(ctx, TargetRedis, OperationGet, cfg, func(key string, value string) error {
		return client.Get(ctx, key).Err()
	})
}

func preloadRedis(ctx context.Context, client redis.UniversalClient, cfg Config) error {
	value := make([]byte, cfg.ValueSize)
	for i := range value {
		value[i] = 'x'
	}

	preloadCfg := cfg
	preloadCfg.KeyPrefix = cfg.KeyPrefix
	preloadCfg.Requests = cfg.Requests
	preloadCfg.LoadDuration = 0

	result := runMeasured(ctx, TargetRedis, OperationGet, preloadCfg, func(key string, _ string) error {
		return client.Set(ctx, key, string(value), time.Hour).Err()
	})
	if result.Failed > 0 {
		return fmt.Errorf("redis preload failed: %d errors, first errors: %v", result.Failed, result.SampleErrors)
	}
	return nil
}

func cleanupRedis(ctx context.Context, cfg Config) error {
	client, err := newRedisBenchmarkClient(cfg)
	if err != nil {
		return err
	}
	defer client.Close()

	cleanupCtx, cancel := context.WithTimeout(ctx, cfg.Timeout)
	defer cancel()

	if err := client.FlushDB(cleanupCtx).Err(); err != nil {
		return fmt.Errorf("redis FLUSHDB failed: %w", err)
	}

	return nil
}

func newRedisBenchmarkClient(cfg Config) (redis.UniversalClient, error) {
	poolSize := cfg.Concurrency * 2
	if poolSize < 10 {
		poolSize = 10
	}

	switch normalizedRedisMode(cfg.Redis.Mode) {
	case "standalone":
		return redis.NewClient(&redis.Options{
			Addr:         cfg.Redis.Addr,
			Password:     cfg.Redis.Password,
			DB:           cfg.Redis.DB,
			DialTimeout:  cfg.Timeout,
			ReadTimeout:  cfg.Timeout,
			WriteTimeout: cfg.Timeout,
			PoolSize:     poolSize,
		}), nil

	case "cluster":
		addrs := cleanStringList(cfg.Redis.ClusterAddrs)
		if len(addrs) == 0 {
			return nil, fmt.Errorf("redis cluster mode requires at least one address in --redis-cluster-addrs")
		}

		return redis.NewClusterClient(&redis.ClusterOptions{
			Addrs:        addrs,
			Password:     cfg.Redis.Password,
			DialTimeout:  cfg.Timeout,
			ReadTimeout:  cfg.Timeout,
			WriteTimeout: cfg.Timeout,
			PoolSize:     poolSize,
		}), nil

	default:
		return nil, fmt.Errorf("invalid redis mode %q", cfg.Redis.Mode)
	}
}

func normalizedRedisMode(mode string) string {
	mode = strings.ToLower(strings.TrimSpace(mode))

	switch mode {
	case "", "single", "standalone", "node":
		return "standalone"

	case "cluster", "redis-cluster":
		return "cluster"

	default:
		return mode
	}
}
func cleanStringList(values []string) []string {
	cleaned := make([]string, 0, len(values))

	for _, value := range values {
		value = strings.TrimSpace(value)
		if value != "" {
			cleaned = append(cleaned, value)
		}
	}

	return cleaned
}
