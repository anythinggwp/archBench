package internal

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func RunPostgres(ctx context.Context, cfg Config, operation Operation) (Result, error) {
	connectCtx, cancel := context.WithTimeout(ctx, cfg.Timeout)
	defer cancel()

	poolCfg, err := pgxpool.ParseConfig(cfg.Postgres.ConnString)
	if err != nil {
		return Result{}, fmt.Errorf("postgres parse connection string failed: %w", err)
	}

	maxConns := cfg.Postgres.MaxConns
	if maxConns <= 0 {
		maxConns = cfg.Concurrency
	}
	poolCfg.MaxConns = int32(maxConns)
	poolCfg.ConnConfig.ConnectTimeout = cfg.Timeout
	poolCfg.ConnConfig.User = cfg.Postgres.User
	poolCfg.ConnConfig.Password = cfg.Postgres.Password
	poolCfg.ConnConfig.Database = cfg.Postgres.DB

	pool, err := pgxpool.NewWithConfig(connectCtx, poolCfg)
	if err != nil {
		return Result{}, fmt.Errorf("postgres connect failed: %w", err)
	}
	defer pool.Close()

	pingCtx, pingCancel := context.WithTimeout(ctx, cfg.Timeout)
	defer pingCancel()
	if err := pool.Ping(pingCtx); err != nil {
		return Result{}, fmt.Errorf("postgres ping failed: %w", err)
	}

	if !cfg.Postgres.SkipDDLInit {
		if err := ensurePostgresTable(ctx, pool, cfg.Postgres.Table); err != nil {
			return Result{}, err
		}
	}

	switch operation {
	case OperationSet:
		return runPostgresSet(ctx, pool, cfg), nil
	case OperationGet:
		if err := preloadPostgres(ctx, pool, cfg); err != nil {
			return Result{}, err
		}
		return runPostgresGet(ctx, pool, cfg), nil
	default:
		return Result{}, fmt.Errorf("unsupported postgres operation: %s", operation)
	}
}

func runPostgresSet(ctx context.Context, pool *pgxpool.Pool, cfg Config) Result {
	table := quotePostgresIdentifier(cfg.Postgres.Table)
	query := fmt.Sprintf(
		`INSERT INTO %s (key, value) VALUES ($1, $2) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value`,
		table,
	)

	return runMeasured(ctx, TargetPostgres, OperationSet, cfg, func(key string, value string) error {
		_, err := pool.Exec(ctx, query, key, value)
		return err
	})
}

func runPostgresGet(ctx context.Context, pool *pgxpool.Pool, cfg Config) Result {
	table := quotePostgresIdentifier(cfg.Postgres.Table)
	query := fmt.Sprintf(`SELECT value FROM %s WHERE key = $1`, table)

	return runMeasured(ctx, TargetPostgres, OperationGet, cfg, func(key string, value string) error {
		var got string
		err := pool.QueryRow(ctx, query, key).Scan(&got)
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("postgres key not found: %s", key)
		}
		return err
	})
}

func preloadPostgres(ctx context.Context, pool *pgxpool.Pool, cfg Config) error {
	table := quotePostgresIdentifier(cfg.Postgres.Table)
	value := strings.Repeat("x", cfg.ValueSize)
	query := fmt.Sprintf(
		`INSERT INTO %s (key, value) VALUES ($1, $2) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value`,
		table,
	)

	preloadCfg := cfg
	preloadCfg.LoadDuration = 0

	result := runMeasured(ctx, TargetPostgres, OperationGet, preloadCfg, func(key string, _ string) error {
		_, err := pool.Exec(ctx, query, key, value)
		return err
	})
	if result.Failed > 0 {
		return fmt.Errorf("postgres preload failed: %d errors, first errors: %v", result.Failed, result.SampleErrors)
	}
	return nil
}

func ensurePostgresTable(ctx context.Context, pool *pgxpool.Pool, table string) error {
	query := fmt.Sprintf(`
CREATE TABLE IF NOT EXISTS %s (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
)`, quotePostgresIdentifier(table))

	_, err := pool.Exec(ctx, query)
	if err != nil {
		return fmt.Errorf("postgres table init failed: %w; create table manually or use --postgres-no-ddl", err)
	}
	return nil
}

func quotePostgresIdentifier(identifier string) string {
	return `"` + strings.ReplaceAll(identifier, `"`, `""`) + `"`
}

func cleanupPostgres(ctx context.Context, cfg Config) error {
	connectCtx, cancel := context.WithTimeout(ctx, cfg.Timeout)
	defer cancel()

	poolCfg, err := pgxpool.ParseConfig(cfg.Postgres.ConnString)
	if err != nil {
		return fmt.Errorf("postgres parse connection string failed: %w", err)
	}

	maxConns := cfg.Postgres.MaxConns
	if maxConns <= 0 {
		maxConns = cfg.Concurrency
	}

	poolCfg.MaxConns = int32(maxConns)
	poolCfg.ConnConfig.ConnectTimeout = cfg.Timeout

	pool, err := pgxpool.NewWithConfig(connectCtx, poolCfg)
	if err != nil {
		return fmt.Errorf("postgres connect failed: %w", err)
	}
	defer pool.Close()

	if !cfg.Postgres.SkipDDLInit {
		if err := ensurePostgresTable(ctx, pool, cfg.Postgres.Table); err != nil {
			return err
		}
	}

	cleanupCtx, cleanupCancel := context.WithTimeout(ctx, cfg.Timeout)
	defer cleanupCancel()

	query := fmt.Sprintf(
		`TRUNCATE TABLE %s`,
		quotePostgresIdentifier(cfg.Postgres.Table),
	)

	if _, err := pool.Exec(cleanupCtx, query); err != nil {
		return fmt.Errorf("postgres truncate table %q failed: %w", cfg.Postgres.Table, err)
	}

	return nil
}
