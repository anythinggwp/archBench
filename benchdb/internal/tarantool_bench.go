package internal

import (
	"context"
	"fmt"
	"strings"
	"sync/atomic"

	"github.com/tarantool/go-tarantool/v2"
)

func RunTarantool(ctx context.Context, cfg Config, operation Operation) (Result, error) {
	mode := normalizeTarantoolMode(cfg.Tarantool.Mode)

	if mode == "direct" && !cfg.Tarantool.SkipDDLInit {
		conn, err := connectTarantool(ctx, cfg)
		if err != nil {
			return Result{}, err
		}
		if err := ensureTarantoolSpace(conn, cfg.Tarantool.Space); err != nil {
			conn.Close()
			return Result{}, err
		}
		conn.Close()
	}

	connPool, err := newTarantoolConnPool(ctx, cfg)
	if err != nil {
		return Result{}, err
	}
	defer connPool.Close()

	switch operation {
	case OperationSet:
		return runTarantoolSet(connPool, cfg, mode), nil
	case OperationGet:
		if err := preloadTarantool(connPool, cfg, mode); err != nil {
			return Result{}, err
		}
		return runTarantoolGet(connPool, cfg, mode), nil
	default:
		return Result{}, fmt.Errorf("unsupported tarantool operation: %s", operation)
	}
}

type tarantoolDoer interface {
	Do(req tarantool.Request) *tarantool.Future
}

type tarantoolConnPool struct {
	conns []*tarantool.Connection
	next  uint64
}

func newTarantoolConnPool(ctx context.Context, cfg Config) (*tarantoolConnPool, error) {
	maxConns := cfg.Tarantool.MaxConns
	if maxConns <= 0 {
		maxConns = cfg.Concurrency
	}
	if maxConns > cfg.Requests {
		maxConns = cfg.Requests
	}
	if maxConns < 1 {
		maxConns = 1
	}

	pool := &tarantoolConnPool{
		conns: make([]*tarantool.Connection, 0, maxConns),
	}

	addrs := tarantoolAddrs(cfg)

	for i := 0; i < maxConns; i++ {
		addr := addrs[i%len(addrs)]
		conn, err := connectTarantoolAddr(ctx, cfg, addr)
		if err != nil {
			pool.Close()
			return nil, fmt.Errorf("tarantool connect %d/%d to %s failed: %w", i+1, maxConns, addr, err)
		}
		pool.conns = append(pool.conns, conn)
	}

	return pool, nil
}

func connectTarantool(ctx context.Context, cfg Config) (*tarantool.Connection, error) {
	return connectTarantoolAddr(ctx, cfg, tarantoolAddrs(cfg)[0])
}

func tarantoolAddrs(cfg Config) []string {
	if len(cfg.Tarantool.Addrs) > 0 {
		return cfg.Tarantool.Addrs
	}

	return []string{cfg.Tarantool.Addr}
}

func connectTarantoolAddr(ctx context.Context, cfg Config, addr string) (*tarantool.Connection, error) {
	connectCtx, cancel := context.WithTimeout(ctx, cfg.Timeout)
	defer cancel()

	conn, err := tarantool.Connect(connectCtx, tarantool.NetDialer{
		Address:  addr,
		User:     cfg.Tarantool.User,
		Password: cfg.Tarantool.Password,
	}, tarantool.Opts{
		Timeout: cfg.Timeout,
	})
	if err != nil {
		return nil, fmt.Errorf("tarantool connect failed: %w", err)
	}
	return conn, nil
}

func (p *tarantoolConnPool) Close() {
	for _, conn := range p.conns {
		conn.Close()
	}
}

func (p *tarantoolConnPool) Do(req tarantool.Request) *tarantool.Future {
	if len(p.conns) == 1 {
		return p.conns[0].Do(req)
	}

	idx := atomic.AddUint64(&p.next, 1) - 1
	return p.conns[int(idx%uint64(len(p.conns)))].Do(req)
}

func normalizeTarantoolMode(mode string) string {
	mode = strings.ToLower(strings.TrimSpace(mode))
	if mode == "" {
		return "direct"
	}
	return mode
}

func runTarantoolSet(conn tarantoolDoer, cfg Config, mode string) Result {
	space := cfg.Tarantool.Space
	return runMeasured(TargetTarantool, OperationSet, cfg, func(key string, value string) error {
		if mode == "crud" {
			return doTarantoolCrudRequest(
				conn,
				newTarantoolCrudReplaceRequest(space, key, value),
				"crud.replace",
			)
		}

		if mode != "direct" {
			return doTarantoolCall(conn, cfg.Tarantool.SetFunc, []interface{}{key, value})
		}

		_, err := conn.Do(tarantool.NewReplaceRequest(space).
			Tuple([]interface{}{key, value}),
		).Get()
		return err
	})
}

func runTarantoolGet(conn tarantoolDoer, cfg Config, mode string) Result {
	space := cfg.Tarantool.Space
	return runMeasured(TargetTarantool, OperationGet, cfg, func(key string, value string) error {
		if mode == "crud" {
			return doTarantoolCrudRequest(
				conn,
				newTarantoolCrudGetRequest(space, key),
				"crud.get",
			)
		}

		if mode != "direct" {
			return doTarantoolCall(conn, cfg.Tarantool.GetFunc, []interface{}{key})
		}

		_, err := conn.Do(tarantool.NewSelectRequest(space).
			Index("primary").
			Iterator(tarantool.IterEq).
			Limit(1).
			Key([]interface{}{key}),
		).Get()
		return err
	})
}

func preloadTarantool(conn tarantoolDoer, cfg Config, mode string) error {
	space := cfg.Tarantool.Space
	value := strings.Repeat("x", cfg.ValueSize)

	result := runMeasured(TargetTarantool, OperationGet, cfg, func(key string, _ string) error {
		if mode == "crud" {
			return doTarantoolCrudRequest(
				conn,
				newTarantoolCrudReplaceRequest(space, key, value),
				"crud.replace",
			)
		}

		if mode != "direct" {
			return doTarantoolCall(conn, cfg.Tarantool.SetFunc, []interface{}{key, value})
		}

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

func doTarantoolCall(conn tarantoolDoer, funcName string, args []interface{}) error {
	data, err := conn.Do(tarantool.NewCallRequest(funcName).Args(args)).Get()
	if err != nil {
		return err
	}

	return detectTarantoolCallError(funcName, data)
}

func doTarantoolCrudRequest(conn tarantoolDoer, req tarantool.Request, funcName string) error {
	data, err := conn.Do(req).Get()
	if err != nil {
		return err
	}

	return detectTarantoolCallError(funcName, data)
}

func newTarantoolCrudReplaceRequest(space string, key string, value string) tarantool.Request {
	return tarantool.NewCall17Request("crud.replace").Args([]interface{}{
		space,
		[]interface{}{key, nil, value},
		map[string]interface{}{
			"noreturn": true,
		},
	})
}

func newTarantoolCrudGetRequest(space string, key string) tarantool.Request {
	return tarantool.NewCall17Request("crud.get").Args([]interface{}{
		space,
		[]interface{}{key},
		map[string]interface{}{},
	})
}

func newTarantoolCrudTruncateRequest(space string) tarantool.Request {
	return tarantool.NewCall17Request("crud.truncate").Args([]interface{}{
		space,
		map[string]interface{}{
			"timeout": 10,
		},
	})
}

func detectTarantoolCallError(funcName string, data []interface{}) error {
	if len(data) >= 2 && data[0] == nil && data[1] != nil {
		return fmt.Errorf("%s returned error: %v", funcName, data[1])
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

func cleanupTarantool(ctx context.Context, cfg Config) error {
	conn, err := connectTarantool(ctx, cfg)
	if err != nil {
		return err
	}
	defer conn.Close()

	mode := normalizeTarantoolMode(cfg.Tarantool.Mode)
	if mode == "direct" && !cfg.Tarantool.SkipDDLInit {
		if err := ensureTarantoolSpace(conn, cfg.Tarantool.Space); err != nil {
			return err
		}
	}

	if mode != "direct" {
		if mode == "crud" {
			return doTarantoolCrudRequest(
				conn,
				newTarantoolCrudTruncateRequest(cfg.Tarantool.Space),
				"crud.truncate",
			)
		}

		if err = doTarantoolCall(conn, cfg.Tarantool.TruncateFunc, []interface{}{}); err != nil {
			return fmt.Errorf("tarantool call %q failed: %w", cfg.Tarantool.TruncateFunc, err)
		}

		return nil
	}

	lua := `
local space_name = ...
local space = box.space[space_name]
if space == nil then
    error("space '" .. tostring(space_name) .. "' does not exist")
end
space:truncate()
return space:len()
`

	_, err = conn.Do(
		tarantool.NewEvalRequest(lua).Args([]interface{}{cfg.Tarantool.Space}),
	).Get()
	if err != nil {
		return fmt.Errorf("tarantool truncate space %q failed: %w", cfg.Tarantool.Space, err)
	}

	return nil
}
