package internal

import (
	"context"
	"fmt"
	"hash/crc32"
	"strings"
	"sync/atomic"

	"github.com/tarantool/go-tarantool/v2"
)

func RunTarantool(ctx context.Context, cfg Config, operation Operation) (Result, error) {
	mode := normalizeTarantoolMode(cfg.Tarantool.Mode)

	if (mode == "direct" || mode == "cluster") && !cfg.Tarantool.SkipDDLInit {
		if err := ensureTarantoolSpaces(ctx, cfg); err != nil {
			return Result{}, err
		}
	}

	connPool, err := newTarantoolBenchmarkConnPool(ctx, cfg, mode)
	if err != nil {
		return Result{}, err
	}
	defer connPool.Close()

	switch operation {
	case OperationSet:
		if normalizeSetMode(cfg.SetMode) == "versioned" {
			return runTarantoolVersionedSet(ctx, connPool, cfg, mode), nil
		}
		if mode == "cluster" {
			return runTarantoolClusterSet(ctx, connPool, cfg), nil
		}
		return runTarantoolSet(ctx, connPool, cfg, mode), nil
	case OperationGet:
		if mode == "cluster" {
			if err := preloadTarantoolCluster(ctx, connPool, cfg); err != nil {
				return Result{}, err
			}
			return runTarantoolClusterGet(ctx, connPool, cfg), nil
		}
		if err := preloadTarantool(ctx, connPool, cfg, mode); err != nil {
			return Result{}, err
		}
		return runTarantoolGet(ctx, connPool, cfg, mode), nil
	default:
		return Result{}, fmt.Errorf("unsupported tarantool operation: %s", operation)
	}
}

type tarantoolDoer interface {
	Do(req tarantool.Request) *tarantool.Future
}

type tarantoolConnPool struct {
	conns     []*tarantool.Connection
	next      uint64
	shards    [][]*tarantool.Connection
	shardNext []uint64
}

func newTarantoolBenchmarkConnPool(ctx context.Context, cfg Config, mode string) (*tarantoolConnPool, error) {
	if mode == "cluster" {
		return newTarantoolClusterConnPool(ctx, cfg)
	}

	return newTarantoolConnPool(ctx, cfg)
}

func newTarantoolConnPool(ctx context.Context, cfg Config) (*tarantoolConnPool, error) {
	maxConns := tarantoolMaxConns(cfg)
	addrs := tarantoolAddrs(cfg)
	if len(addrs) == 0 {
		return nil, fmt.Errorf("tarantool address list is empty")
	}

	pool := &tarantoolConnPool{
		conns: make([]*tarantool.Connection, 0, maxConns),
	}

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

func newTarantoolClusterConnPool(ctx context.Context, cfg Config) (*tarantoolConnPool, error) {
	addrs := tarantoolAddrs(cfg)
	if len(addrs) == 0 {
		return nil, fmt.Errorf("tarantool cluster mode requires at least one address")
	}

	maxConns := tarantoolMaxConns(cfg)
	if maxConns < len(addrs) {
		maxConns = len(addrs)
	}

	pool := &tarantoolConnPool{
		conns:     make([]*tarantool.Connection, 0, maxConns),
		shards:    make([][]*tarantool.Connection, len(addrs)),
		shardNext: make([]uint64, len(addrs)),
	}

	for i := 0; i < maxConns; i++ {
		shardIdx := i % len(addrs)
		addr := addrs[shardIdx]
		conn, err := connectTarantoolAddr(ctx, cfg, addr)
		if err != nil {
			pool.Close()
			return nil, fmt.Errorf("tarantool cluster connect %d/%d to shard %d (%s) failed: %w", i+1, maxConns, shardIdx, addr, err)
		}
		pool.conns = append(pool.conns, conn)
		pool.shards[shardIdx] = append(pool.shards[shardIdx], conn)
	}

	return pool, nil
}

func tarantoolMaxConns(cfg Config) int {
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
	return maxConns
}

func connectTarantool(ctx context.Context, cfg Config) (*tarantool.Connection, error) {
	addrs := tarantoolAddrs(cfg)
	if len(addrs) == 0 {
		return nil, fmt.Errorf("tarantool address list is empty")
	}
	return connectTarantoolAddr(ctx, cfg, addrs[0])
}

func tarantoolAddrs(cfg Config) []string {
	addrs := cleanStringList(cfg.Tarantool.Addrs)
	if len(addrs) > 0 {
		return addrs
	}

	addr := strings.TrimSpace(cfg.Tarantool.Addr)
	if addr == "" {
		return nil
	}

	return []string{addr}
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

func (p *tarantoolConnPool) DoForKey(key string, req tarantool.Request) *tarantool.Future {
	if len(p.shards) == 0 {
		return p.Do(req)
	}

	shardIdx := int(crc32.ChecksumIEEE([]byte(key)) % uint32(len(p.shards)))
	conns := p.shards[shardIdx]
	if len(conns) == 1 {
		return conns[0].Do(req)
	}

	idx := atomic.AddUint64(&p.shardNext[shardIdx], 1) - 1
	return conns[int(idx%uint64(len(conns)))].Do(req)
}

func normalizeTarantoolMode(mode string) string {
	mode = strings.ToLower(strings.TrimSpace(mode))
	switch mode {
	case "":
		return "direct"
	case "shard", "sharded", "sharding":
		return "cluster"
	default:
		return mode
	}
}

func runTarantoolSet(ctx context.Context, conn tarantoolDoer, cfg Config, mode string) Result {
	space := cfg.Tarantool.Space
	return runMeasured(ctx, TargetTarantool, OperationSet, cfg, func(key string, value string) error {
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

func runTarantoolGet(ctx context.Context, conn tarantoolDoer, cfg Config, mode string) Result {
	space := cfg.Tarantool.Space
	return runMeasured(ctx, TargetTarantool, OperationGet, cfg, func(key string, value string) error {
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

func runTarantoolClusterSet(ctx context.Context, conn *tarantoolConnPool, cfg Config) Result {
	space := cfg.Tarantool.Space
	return runMeasured(ctx, TargetTarantool, OperationSet, cfg, func(key string, value string) error {
		_, err := conn.DoForKey(key, tarantool.NewReplaceRequest(space).
			Tuple([]interface{}{key, value}),
		).Get()
		return err
	})
}

func runTarantoolClusterGet(ctx context.Context, conn *tarantoolConnPool, cfg Config) Result {
	space := cfg.Tarantool.Space
	return runMeasured(ctx, TargetTarantool, OperationGet, cfg, func(key string, value string) error {
		_, err := conn.DoForKey(key, tarantool.NewSelectRequest(space).
			Index("primary").
			Iterator(tarantool.IterEq).
			Limit(1).
			Key([]interface{}{key}),
		).Get()
		return err
	})
}

func runTarantoolVersionedSet(ctx context.Context, conn *tarantoolConnPool, cfg Config, mode string) Result {
	space := cfg.Tarantool.Space
	return runMeasuredIndexed(ctx, TargetTarantool, OperationSet, cfg, func(idx int) (string, string) {
		return makeVersionedSetKeyValue(cfg, TargetTarantool, idx)
	}, func(_ int, key string, value string) error {
		switch mode {
		case "cluster":
			_, err := conn.DoForKey(key, newTarantoolVersionedReplaceRequest(space, key, value)).Get()
			return err

		case "direct":
			_, err := conn.Do(newTarantoolVersionedReplaceRequest(space, key, value)).Get()
			return err

		case "crud":
			current, found, err := getTarantoolValue(conn, cfg, mode, key)
			if err != nil {
				return err
			}
			if found && !valueVersionChanged(current, value) {
				return nil
			}
			return doTarantoolCrudRequest(
				conn,
				newTarantoolCrudReplaceRequest(space, key, value),
				"crud.replace",
			)

		default:
			current, found, err := getTarantoolValue(conn, cfg, mode, key)
			if err != nil {
				return err
			}
			if found && !valueVersionChanged(current, value) {
				return nil
			}
			return doTarantoolCall(conn, cfg.Tarantool.SetFunc, []interface{}{key, value})
		}
	})
}

func preloadTarantool(ctx context.Context, conn tarantoolDoer, cfg Config, mode string) error {
	space := cfg.Tarantool.Space
	value := strings.Repeat("x", cfg.ValueSize)
	preloadCfg := cfg
	preloadCfg.LoadDuration = 0

	result := runMeasured(ctx, TargetTarantool, OperationGet, preloadCfg, func(key string, _ string) error {
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

func preloadTarantoolCluster(ctx context.Context, conn *tarantoolConnPool, cfg Config) error {
	space := cfg.Tarantool.Space
	value := strings.Repeat("x", cfg.ValueSize)
	preloadCfg := cfg
	preloadCfg.LoadDuration = 0

	result := runMeasured(ctx, TargetTarantool, OperationGet, preloadCfg, func(key string, _ string) error {
		_, err := conn.DoForKey(key, tarantool.NewReplaceRequest(space).
			Tuple([]interface{}{key, value}),
		).Get()
		return err
	})
	if result.Failed > 0 {
		return fmt.Errorf("tarantool cluster preload failed: %d errors, first errors: %v", result.Failed, result.SampleErrors)
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

func newTarantoolVersionedReplaceRequest(space string, key string, value string) tarantool.Request {
	lua := `
local space_name, key, value, version_len = ...
local space = box.space[space_name]

if space == nil then
    error("space '" .. tostring(space_name) .. "' does not exist")
end

local current = space:get{key}
local new_version = string.sub(value, 1, version_len)

if current ~= nil then
    local current_value = current[2]
    if current_value ~= nil and string.sub(current_value, 1, version_len) == new_version then
        return false
    end
end

space:replace{key, value}
return true
`

	return tarantool.NewEvalRequest(lua).Args([]interface{}{space, key, value, versionedValueHeaderLen})
}

func getTarantoolValue(conn tarantoolDoer, cfg Config, mode string, key string) (string, bool, error) {
	var req tarantool.Request
	funcName := "select"

	switch mode {
	case "crud":
		funcName = "crud.get"
		req = newTarantoolCrudGetRequest(cfg.Tarantool.Space, key)

	case "direct", "cluster":
		req = tarantool.NewSelectRequest(cfg.Tarantool.Space).
			Index("primary").
			Iterator(tarantool.IterEq).
			Limit(1).
			Key([]interface{}{key})

	default:
		funcName = cfg.Tarantool.GetFunc
		req = tarantool.NewCallRequest(cfg.Tarantool.GetFunc).Args([]interface{}{key})
	}

	data, err := conn.Do(req).Get()
	if err != nil {
		return "", false, err
	}

	if err := detectTarantoolCallError(funcName, data); err != nil {
		return "", false, err
	}

	value, ok := extractTarantoolValue(data)
	return value, ok, nil
}

func extractTarantoolValue(v interface{}) (string, bool) {
	switch x := v.(type) {
	case nil:
		return "", false

	case []interface{}:
		if len(x) >= 3 {
			if value, ok := stringFromTarantoolValue(x[2]); ok {
				return value, true
			}
		}
		if len(x) >= 2 {
			if value, ok := stringFromTarantoolValue(x[1]); ok {
				return value, true
			}
		}
		for _, item := range x {
			if value, ok := extractTarantoolValue(item); ok {
				return value, true
			}
		}

	case map[string]interface{}:
		if rows, ok := x["rows"]; ok {
			return extractTarantoolValue(rows)
		}

	case map[interface{}]interface{}:
		if rows, ok := x["rows"]; ok {
			return extractTarantoolValue(rows)
		}
	}

	return "", false
}

func stringFromTarantoolValue(v interface{}) (string, bool) {
	switch x := v.(type) {
	case string:
		return x, true
	case []byte:
		return string(x), true
	default:
		return "", false
	}
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

func ensureTarantoolSpaces(ctx context.Context, cfg Config) error {
	for _, addr := range tarantoolAddrs(cfg) {
		conn, err := connectTarantoolAddr(ctx, cfg, addr)
		if err != nil {
			return err
		}

		if err := ensureTarantoolSpace(conn, cfg.Tarantool.Space); err != nil {
			conn.Close()
			return fmt.Errorf("tarantool space init on %s failed: %w", addr, err)
		}

		conn.Close()
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
	mode := normalizeTarantoolMode(cfg.Tarantool.Mode)
	if mode == "cluster" {
		for _, addr := range tarantoolAddrs(cfg) {
			shardConn, err := connectTarantoolAddr(ctx, cfg, addr)
			if err != nil {
				return err
			}

			if !cfg.Tarantool.SkipDDLInit {
				if err := ensureTarantoolSpace(shardConn, cfg.Tarantool.Space); err != nil {
					shardConn.Close()
					return fmt.Errorf("tarantool space init on %s failed: %w", addr, err)
				}
			}

			if err := truncateTarantoolSpace(ctx, shardConn, cfg.Tarantool.Space); err != nil {
				shardConn.Close()
				return fmt.Errorf("tarantool truncate on %s failed: %w", addr, err)
			}

			shardConn.Close()
		}

		return nil
	}

	conn, err := connectTarantool(ctx, cfg)
	if err != nil {
		return err
	}
	defer conn.Close()

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
