package internal

import (
	"context"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

func RunRedis(ctx context.Context, cfg Config, operation Operation) (Result, error) {
	client := redis.NewClient(&redis.Options{
		Addr:     cfg.Redis.Addr,
		Password: cfg.Redis.Password,
		DB:       cfg.Redis.DB,
	})
	defer client.Close()

	pingCtx, cancel := context.WithTimeout(ctx, cfg.Timeout)
	defer cancel()
	if err := client.Ping(pingCtx).Err(); err != nil {
		return Result{}, fmt.Errorf("redis ping failed: %w", err)
	}

	switch operation {
	case OperationSet:
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

func runRedisSet(ctx context.Context, client *redis.Client, cfg Config) Result {
	return runMeasured(TargetRedis, OperationSet, cfg, func(key string, value string) error {
		return client.Set(ctx, key, value, 0).Err()
	})
}

func runRedisGet(ctx context.Context, client *redis.Client, cfg Config) Result {
	return runMeasured(TargetRedis, OperationGet, cfg, func(key string, value string) error {
		return client.Get(ctx, key).Err()
	})
}

func preloadRedis(ctx context.Context, client *redis.Client, cfg Config) error {
	value := make([]byte, cfg.ValueSize)
	for i := range value {
		value[i] = 'x'
	}

	preloadCfg := cfg
	preloadCfg.KeyPrefix = cfg.KeyPrefix
	preloadCfg.Requests = cfg.Requests

	result := runMeasured(TargetRedis, OperationGet, preloadCfg, func(key string, _ string) error {
		return client.Set(ctx, key, string(value), time.Hour).Err()
	})
	if result.Failed > 0 {
		return fmt.Errorf("redis preload failed: %d errors, first errors: %v", result.Failed, result.SampleErrors)
	}
	return nil
}

func cleanupRedis(ctx context.Context, cfg Config) error {
	client := redis.NewClient(&redis.Options{
		Addr:     cfg.Redis.Addr,
		Password: cfg.Redis.Password,
		DB:       cfg.Redis.DB,
	})
	defer client.Close()

	cleanupCtx, cancel := context.WithTimeout(ctx, cfg.Timeout)
	defer cancel()

	if err := client.FlushDB(cleanupCtx).Err(); err != nil {
		return fmt.Errorf("redis FLUSHDB failed: %w", err)
	}

	return nil
}
