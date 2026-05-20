package internal

import (
	"context"
	"fmt"

	_ "github.com/ydb-platform/ydb-go-sdk/v3"
)

func CleanupTargets(ctx context.Context, cfg Config, targets []Target) error {
	for _, target := range targets {
		if err := CleanupTarget(ctx, cfg, target); err != nil {
			return fmt.Errorf("cleanup %s failed: %w", target, err)
		}
	}

	return nil
}

func CleanupTarget(ctx context.Context, cfg Config, target Target) error {
	switch target {
	case TargetRedis:
		return cleanupRedis(ctx, cfg)

	case TargetTarantool:
		return cleanupTarantool(ctx, cfg)

	case TargetYDB:
		return cleanupYDB(ctx, cfg)

	case TargetPostgres:
		return cleanupPostgres(ctx, cfg)

	default:
		return fmt.Errorf("unknown cleanup target: %s", target)
	}
}
