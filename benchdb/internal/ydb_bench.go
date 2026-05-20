package internal

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"

	_ "github.com/ydb-platform/ydb-go-sdk/v3"
	"github.com/ydb-platform/ydb-go-sdk/v3/table/types"
)

func RunYDB(ctx context.Context, cfg Config, operation Operation) (Result, error) {
	db, err := sql.Open("ydb", cfg.YDB.ConnectionString)
	if err != nil {
		return Result{}, fmt.Errorf("ydb open failed: %w", err)
	}
	defer db.Close()

	maxOpenConns := cfg.YDB.MaxOpenConns
	if maxOpenConns <= 0 {
		maxOpenConns = cfg.Concurrency
	}
	db.SetMaxOpenConns(maxOpenConns)
	db.SetMaxIdleConns(maxOpenConns)

	pingCtx, cancel := context.WithTimeout(ctx, cfg.Timeout)
	defer cancel()
	if err := db.PingContext(pingCtx); err != nil {
		return Result{}, fmt.Errorf("ydb ping failed: %w", err)
	}

	if !cfg.YDB.SkipDDLInit {
		if err := ensureYDBTable(ctx, db, cfg.YDB.Table); err != nil {
			return Result{}, err
		}
	}

	switch operation {
	case OperationSet:
		return runYDBSet(ctx, db, cfg), nil
	case OperationGet:
		if err := preloadYDB(ctx, db, cfg); err != nil {
			return Result{}, err
		}
		return runYDBGet(ctx, db, cfg), nil
	default:
		return Result{}, fmt.Errorf("unsupported ydb operation: %s", operation)
	}
}

func runYDBSet(ctx context.Context, db *sql.DB, cfg Config) Result {
	query := fmt.Sprintf(`
DECLARE $key AS Utf8;
DECLARE $value AS Utf8;
UPSERT INTO %s (`+"`key`"+`, `+"`value`"+`) VALUES ($key, $value);`, ydbIdentifier(cfg.YDB.Table))

	return runMeasured(TargetYDB, OperationSet, cfg, func(key string, value string) error {
		_, err := db.ExecContext(ctx, query,
			sql.Named("key", types.TextValue(key)),
			sql.Named("value", types.TextValue(value)),
		)
		return err
	})
}

func runYDBGet(ctx context.Context, db *sql.DB, cfg Config) Result {
	query := fmt.Sprintf(`
DECLARE $key AS Utf8;
SELECT `+"`value`"+` FROM %s WHERE `+"`key`"+` = $key;`, ydbIdentifier(cfg.YDB.Table))

	return runMeasured(TargetYDB, OperationGet, cfg, func(key string, value string) error {
		var got string
		err := db.QueryRowContext(ctx, query, sql.Named("key", types.TextValue(key))).Scan(&got)
		if errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("ydb key not found: %s", key)
		}
		return err
	})
}

func preloadYDB(ctx context.Context, db *sql.DB, cfg Config) error {
	value := strings.Repeat("x", cfg.ValueSize)
	query := fmt.Sprintf(`
DECLARE $key AS Utf8;
DECLARE $value AS Utf8;
UPSERT INTO %s (`+"`key`"+`, `+"`value`"+`) VALUES ($key, $value);`, ydbIdentifier(cfg.YDB.Table))

	result := runMeasured(TargetYDB, OperationGet, cfg, func(key string, _ string) error {
		_, err := db.ExecContext(ctx, query,
			sql.Named("key", types.TextValue(key)),
			sql.Named("value", types.TextValue(value)),
		)
		return err
	})
	if result.Failed > 0 {
		return fmt.Errorf("ydb preload failed: %d errors, first errors: %v", result.Failed, result.SampleErrors)
	}
	return nil
}

func ensureYDBTable(ctx context.Context, db *sql.DB, table string) error {
	query := fmt.Sprintf(`
CREATE TABLE IF NOT EXISTS %s (
    `+"`key`"+` Utf8 NOT NULL,
    `+"`value`"+` Utf8,
    PRIMARY KEY (`+"`key`"+`)
);`, ydbIdentifier(table))

	_, err := db.ExecContext(ctx, query)
	if err != nil {
		return fmt.Errorf("ydb table init failed: %w; create table manually or use --ydb-no-ddl", err)
	}
	return nil
}

func ydbIdentifier(identifier string) string {
	return "`" + strings.ReplaceAll(identifier, "`", "``") + "`"
}
