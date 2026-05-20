package internal

import (
	"context"
	"fmt"
	"strings"

	"github.com/tarantool/go-tarantool/v2"
)

func RunTarantool(ctx context.Context, cfg Config, operation Operation) (Result, error) {
	connectCtx, cancel := context.WithTimeout(ctx, cfg.Timeout)
	defer cancel()

	conn, err := tarantool.Connect(connectCtx, tarantool.NetDialer{
		Address:  cfg.Tarantool.Addr,
		User:     cfg.Tarantool.User,
		Password: cfg.Tarantool.Password,
	}, tarantool.Opts{
		Timeout: cfg.Timeout,
	})
	if err != nil {
		return Result{}, fmt.Errorf("tarantool connect failed: %w", err)
	}
	defer conn.Close()

	if !cfg.Tarantool.SkipDDLInit {
		if err := ensureTarantoolSpace(conn, cfg.Tarantool.Space); err != nil {
			return Result{}, err
		}
	}

	switch operation {
	case OperationSet:
		return runTarantoolSet(conn, cfg), nil
	case OperationGet:
		if err := preloadTarantool(conn, cfg); err != nil {
			return Result{}, err
		}
		return runTarantoolGet(conn, cfg), nil
	default:
		return Result{}, fmt.Errorf("unsupported tarantool operation: %s", operation)
	}
}

func runTarantoolSet(conn *tarantool.Connection, cfg Config) Result {
	space := cfg.Tarantool.Space
	return runMeasured(TargetTarantool, OperationSet, cfg, func(key string, value string) error {
		_, err := conn.Do(tarantool.NewReplaceRequest(space).
			Tuple([]interface{}{key, value}),
		).Get()
		return err
	})
}

func runTarantoolGet(conn *tarantool.Connection, cfg Config) Result {
	space := cfg.Tarantool.Space
	return runMeasured(TargetTarantool, OperationGet, cfg, func(key string, value string) error {
		_, err := conn.Do(tarantool.NewSelectRequest(space).
			Index("primary").
			Iterator(tarantool.IterEq).
			Limit(1).
			Key([]interface{}{key}),
		).Get()
		return err
	})
}

func preloadTarantool(conn *tarantool.Connection, cfg Config) error {
	space := cfg.Tarantool.Space
	value := strings.Repeat("x", cfg.ValueSize)

	result := runMeasured(TargetTarantool, OperationGet, cfg, func(key string, _ string) error {
		_, err := conn.Do(tarantool.NewReplaceRequest(space).
			Tuple([]interface{}{key, value}),
		).Get()
		return err
	})
	if result.Failed > 0 {
		return fmt.Errorf("tarantool preload failed: %d errors, first errors: %v", result.Failed, result.SampleErrors)
	}
	return nil
}

func ensureTarantoolSpace(conn *tarantool.Connection, space string) error {
	ddl := `
local space_name = ...
local space = box.space[space_name]

if space == nil then
    space = box.schema.space.create(space_name, {if_not_exists = true})
end

space:format({
    {name = 'key', type = 'string'},
    {name = 'value', type = 'string'},
})

if space.index.primary == nil then
    space:create_index('primary', {
        parts = {{field = 'key', type = 'string'}},
        if_not_exists = true,
    })
end

return true
`

	_, err := conn.Do(tarantool.NewEvalRequest(ddl).Args([]interface{}{space})).Get()
	if err != nil {
		return fmt.Errorf("tarantool space init failed: %w; create space manually or use --tarantool-no-ddl", err)
	}
	return nil
}

func truncateTarantoolSpace(
	ctx context.Context,
	conn *tarantool.Connection,
	spaceName string,
) error {
	if spaceName == "" {
		return fmt.Errorf("tarantool space name is empty")
	}

	lua := `
		local space_name = ...
		local s = box.space[space_name]
		if s == nil then
			error("space '" .. tostring(space_name) .. "' does not exist")
		end
		s:truncate()
		return s:len()
	`

	req := tarantool.NewEvalRequest(lua).Args([]interface{}{spaceName})

	resp, err := conn.Do(req).GetResponse()
	if err != nil {
		return fmt.Errorf("tarantool truncate space %q failed: %w", spaceName, err)
	}

	_ = resp
	return nil
}
