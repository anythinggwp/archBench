package cmd

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"time"

	bench "redis-tarantool-bench/internal"

	"github.com/spf13/cobra"
)

type benchFlags struct {
	target       string
	operation    string
	requests     int
	concurrency  int
	valueSize    int
	loadDuration time.Duration
	keyPrefix    string
	timeout      time.Duration
	setMode      string

	versionedSetKeys        int
	versionedSetChangeEvery int

	runs               int
	runDelay           time.Duration
	cleanupBetweenRuns bool
	requestsList       string
	concurrencyList    string
	valueSizeList      string

	redisMode         string
	redisAddr         string
	redisClusterAddrs string
	redisPassword     string
	redisDB           int

	tarantoolMode         string
	tarantoolAddr         string
	tarantoolAddrs        string
	tarantoolUser         string
	tarantoolPassword     string
	tarantoolSpace        string
	tarantoolSetFunc      string
	tarantoolGetFunc      string
	tarantoolTruncateFunc string
	tarantoolMaxConns     int
	tarantoolNoDDL        bool

	ydbConnectionString string
	ydbTable            string
	ydbNoDDL            bool
	ydbMaxOpenConns     int

	postgresConn     string
	postgresTable    string
	postgresNoDDL    bool
	postgresMaxConns int
	postgreUser      string
	postgrePassword  string
	postgreDB        string

	print      bool
	summary    bool
	outputFile string
	fileFormat string
}

var flags benchFlags

var benchCmd = &cobra.Command{
	Use:   "bench",
	Short: "Run Redis/Tarantool/YDB/PostgreSQL SET/GET benchmark",
	RunE: func(cmd *cobra.Command, args []string) error {
		targets, err := parseTargets(flags.target)
		if err != nil {
			return err
		}

		operations, err := parseOperations(flags.operation)
		if err != nil {
			return err
		}
		redisClusterAddrs, err := parseStringList(flags.redisClusterAddrs)
		if err != nil {
			return err
		}
		tarantoolAddrs, err := parseStringList(flags.tarantoolAddrs)
		if err != nil {
			return err
		}
		baseCfg := bench.Config{
			Requests:     flags.requests,
			Concurrency:  flags.concurrency,
			ValueSize:    flags.valueSize,
			LoadDuration: flags.loadDuration,
			KeyPrefix:    flags.keyPrefix,
			Timeout:      flags.timeout,
			SetMode:      flags.setMode,

			VersionedSetKeys:        flags.versionedSetKeys,
			VersionedSetChangeEvery: flags.versionedSetChangeEvery,

			Redis: bench.RedisConfig{
				Mode:         flags.redisMode,
				Addr:         flags.redisAddr,
				ClusterAddrs: redisClusterAddrs,
				Password:     flags.redisPassword,
				DB:           flags.redisDB,
			},
			Tarantool: bench.TarantoolConfig{
				Addr:         flags.tarantoolAddr,
				Addrs:        tarantoolAddrs,
				User:         flags.tarantoolUser,
				Password:     flags.tarantoolPassword,
				Space:        flags.tarantoolSpace,
				SkipDDLInit:  flags.tarantoolNoDDL,
				MaxConns:     flags.tarantoolMaxConns,
				Mode:         flags.tarantoolMode,
				SetFunc:      flags.tarantoolSetFunc,
				GetFunc:      flags.tarantoolGetFunc,
				TruncateFunc: flags.tarantoolTruncateFunc,
			},
			YDB: bench.YDBConfig{
				ConnectionString: flags.ydbConnectionString,
				Table:            flags.ydbTable,
				SkipDDLInit:      flags.ydbNoDDL,
				MaxOpenConns:     flags.ydbMaxOpenConns,
			},
			Postgres: bench.PostgresConfig{
				ConnString:  flags.postgresConn,
				Table:       flags.postgresTable,
				SkipDDLInit: flags.postgresNoDDL,
				MaxConns:    flags.postgresMaxConns,
				User:        flags.postgreUser,
				Password:    flags.postgrePassword,
				DB:          flags.postgreDB,
			},
		}

		testConfigs, err := buildTestConfigs(baseCfg, flags)
		if err != nil {
			return err
		}

		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
		defer stop()

		results := make([]bench.Result, 0, len(testConfigs)*len(targets)*len(operations))
		totalRuns := len(testConfigs) * len(targets) * len(operations)
		currentRun := 0

	runLoop:
		for testIndex, cfg := range testConfigs {
			if err := cfg.Validate(); err != nil {
				return fmt.Errorf("invalid config for test #%d: %w", testIndex+1, err)
			}

			for _, target := range targets {
				for _, operation := range operations {
					if ctx.Err() != nil {
						break runLoop
					}

					currentRun++

					if flags.cleanupBetweenRuns {
						if flags.print {
							fmt.Fprintf(cmd.OutOrStdout(), "Cleaning selected databases before run %d/%d...\n", currentRun, totalRuns)
						}

						if err := bench.CleanupTargets(ctx, cfg, targets); err != nil {
							return fmt.Errorf("cleanup before run %d/%d failed: %w", currentRun, totalRuns, err)
						}
					}

					if flags.print {
						if cfg.LoadDuration > 0 {
							fmt.Fprintf(cmd.OutOrStdout(),
								"Running %d/%d: test=%d target=%s operation=%s load_duration=%s keyspace=%d concurrency=%d value_size=%d\n",
								currentRun,
								totalRuns,
								cfg.Run,
								target,
								operation,
								cfg.LoadDuration,
								cfg.Requests,
								cfg.Concurrency,
								cfg.ValueSize,
							)
						} else {
							fmt.Fprintf(cmd.OutOrStdout(),
								"Running %d/%d: test=%d target=%s operation=%s requests=%d concurrency=%d value_size=%d\n",
								currentRun,
								totalRuns,
								cfg.Run,
								target,
								operation,
								cfg.Requests,
								cfg.Concurrency,
								cfg.ValueSize,
							)
						}
					}

					var result bench.Result
					var runErr error

					switch target {
					case bench.TargetRedis:
						result, runErr = bench.RunRedis(ctx, cfg, operation)
					case bench.TargetTarantool:
						result, runErr = bench.RunTarantool(ctx, cfg, operation)
					case bench.TargetYDB:
						result, runErr = bench.RunYDB(ctx, cfg, operation)
					case bench.TargetPostgres:
						result, runErr = bench.RunPostgres(ctx, cfg, operation)
					default:
						return fmt.Errorf("unknown target: %s", target)
					}

					if runErr != nil {
						return fmt.Errorf("run %d/%d failed: %w", currentRun, totalRuns, runErr)
					}

					results = append(results, result)
					if ctx.Err() != nil {
						break runLoop
					}

					if flags.runDelay > 0 && currentRun < totalRuns {
						time.Sleep(flags.runDelay)
					}
				}
			}
		}

		summaries := []bench.Summary(nil)
		if flags.summary {
			summaries = bench.BuildSummary(results)
		}

		if flags.print {
			bench.PrintResults(cmd.OutOrStdout(), results)
			if flags.summary {
				bench.PrintSummary(cmd.OutOrStdout(), summaries)
			}
		}

		if flags.outputFile != "" {
			return bench.WriteResults(flags.outputFile, flags.fileFormat, results, summaries)
		}

		return nil
	},
}

func init() {
	rootCmd.AddCommand(benchCmd)

	benchCmd.Flags().StringVar(&flags.target, "target", "all", "benchmark target: redis, tarantool, ydb, postgres, all; comma-separated values are allowed")
	benchCmd.Flags().StringVar(&flags.operation, "operation", "all", "operation: set, get, all")
	benchCmd.Flags().IntVar(&flags.requests, "requests", 10000, "total operations per benchmark")
	benchCmd.Flags().IntVar(&flags.concurrency, "concurrency", 16, "number of parallel workers")
	benchCmd.Flags().IntVar(&flags.valueSize, "value-size", 128, "value size in bytes")
	benchCmd.Flags().DurationVar(&flags.loadDuration, "load-duration", 0, "load testing mode: run each benchmark for this duration; --requests becomes keyspace size")
	benchCmd.Flags().StringVar(&flags.keyPrefix, "key-prefix", "bench", "key prefix")
	benchCmd.Flags().DurationVar(&flags.timeout, "timeout", 5*time.Second, "connection/request timeout")
	benchCmd.Flags().StringVar(&flags.setMode, "set-mode", "plain", "SET behavior: plain or versioned")
	benchCmd.Flags().IntVar(&flags.versionedSetKeys, "versioned-set-keys", 1000, "keyspace size for --set-mode=versioned")
	benchCmd.Flags().IntVar(&flags.versionedSetChangeEvery, "versioned-set-change-every", 5, "number of repeated writes per key before version changes")

	benchCmd.Flags().IntVar(&flags.runs, "runs", 1, "repeat every generated benchmark configuration N times")
	benchCmd.Flags().DurationVar(&flags.runDelay, "run-delay", 0, "pause between sequential benchmark runs, for example 1s or 500ms")
	benchCmd.Flags().BoolVar(
		&flags.cleanupBetweenRuns,
		"cleanup-between-runs",
		false,
		"clean selected benchmark databases before every target/operation run",
	)
	benchCmd.Flags().StringVar(&flags.requestsList, "requests-list", "", "comma-separated requests values; overrides --requests, for example 10000,50000,100000")
	benchCmd.Flags().StringVar(&flags.concurrencyList, "concurrency-list", "", "comma-separated concurrency values; overrides --concurrency, for example 1,8,16,64")
	benchCmd.Flags().StringVar(&flags.valueSizeList, "value-size-list", "", "comma-separated value-size values; overrides --value-size, for example 64,128,1024")

	benchCmd.Flags().StringVar(
		&flags.redisMode,
		"redis-mode",
		"standalone",
		"Redis client mode: standalone or cluster",
	)
	benchCmd.Flags().StringVar(&flags.redisAddr, "redis-addr", "127.0.0.1:6379", "Redis address")
	benchCmd.Flags().StringVar(
		&flags.redisClusterAddrs,
		"redis-cluster-addrs",
		"127.0.0.1:7001,127.0.0.1:7002,127.0.0.1:7003",
		"comma-separated Redis Cluster node addresses",
	)
	benchCmd.Flags().StringVar(&flags.redisPassword, "redis-password", "", "Redis password")
	benchCmd.Flags().IntVar(&flags.redisDB, "redis-db", 0, "Redis DB number")

	benchCmd.Flags().StringVar(&flags.tarantoolMode, "tarantool-mode", "direct", "Tarantool access mode: direct, cluster, call, vshard or crud")
	benchCmd.Flags().StringVar(&flags.tarantoolAddr, "tarantool-addr", "127.0.0.1:3301", "Tarantool address; for vshard use router/proxy address")
	benchCmd.Flags().StringVar(&flags.tarantoolAddrs, "tarantool-addrs", "", "comma-separated Tarantool addresses; in cluster mode keys are routed by hash")
	benchCmd.Flags().StringVar(&flags.tarantoolUser, "tarantool-user", "guest", "Tarantool user")
	benchCmd.Flags().StringVar(&flags.tarantoolPassword, "tarantool-password", "", "Tarantool password")
	benchCmd.Flags().StringVar(&flags.tarantoolSpace, "tarantool-space", "kv", "Tarantool space name; used only in direct mode")
	benchCmd.Flags().StringVar(&flags.tarantoolSetFunc, "tarantool-set-func", "put", "Tarantool function for SET in call/vshard mode")
	benchCmd.Flags().StringVar(&flags.tarantoolGetFunc, "tarantool-get-func", "get", "Tarantool function for GET in call/vshard mode")
	benchCmd.Flags().StringVar(&flags.tarantoolTruncateFunc, "tarantool-truncate-func", "truncate_kv", "Tarantool function used by --cleanup-between-runs in call/vshard mode")
	benchCmd.Flags().IntVar(&flags.tarantoolMaxConns, "tarantool-max-conns", 0, "Tarantool client connections; 0 means use --concurrency")
	benchCmd.Flags().BoolVar(&flags.tarantoolNoDDL, "tarantool-no-ddl", false, "do not create Tarantool space/index automatically")

	benchCmd.Flags().StringVar(&flags.ydbConnectionString, "ydb-connection-string", "grpc://localhost:2136/local", "YDB connection string, for example grpc://localhost:2136/local")
	benchCmd.Flags().StringVar(&flags.ydbTable, "ydb-table", "kv", "YDB table name")
	benchCmd.Flags().BoolVar(&flags.ydbNoDDL, "ydb-no-ddl", false, "do not create YDB table automatically")
	benchCmd.Flags().IntVar(&flags.ydbMaxOpenConns, "ydb-max-open-conns", 0, "YDB max open connections; 0 means use --concurrency")

	benchCmd.Flags().StringVar(&flags.postgresConn, "postgres-conn", "postgres://postgres:postgres@127.0.0.1:5432/postgres?sslmode=disable", "PostgreSQL connection string")
	benchCmd.Flags().StringVar(&flags.postgresTable, "postgres-table", "kv", "PostgreSQL table name")
	benchCmd.Flags().BoolVar(&flags.postgresNoDDL, "postgres-no-ddl", false, "do not create PostgreSQL table automatically")
	benchCmd.Flags().IntVar(&flags.postgresMaxConns, "postgres-max-conns", 0, "PostgreSQL pool max connections; 0 means use --concurrency")
	benchCmd.Flags().StringVar(&flags.postgreUser, "postgres-user", "postgres", "PostgreSQL username for connection")
	benchCmd.Flags().StringVar(&flags.postgrePassword, "postgres-password", "postgres", "PostgreSQL password connection")
	benchCmd.Flags().StringVar(&flags.postgreDB, "postgres-db", "postgres", "PostgreSQL database")

	benchCmd.Flags().BoolVar(&flags.print, "print", true, "print results to terminal")
	benchCmd.Flags().BoolVar(&flags.summary, "summary", false, "print and save aggregated summary grouped by target, operation, requests, concurrency, value-size and load-duration")
	benchCmd.Flags().StringVar(&flags.outputFile, "output-file", "", "write results to file; empty means disabled")
	benchCmd.Flags().StringVar(&flags.fileFormat, "file-format", "json", "file format: json, csv")
}

func parseTargets(value string) ([]bench.Target, error) {
	parts := strings.Split(value, ",")
	targets := make([]bench.Target, 0, len(parts))
	seen := make(map[bench.Target]bool)

	addTarget := func(target bench.Target) {
		if !seen[target] {
			targets = append(targets, target)
			seen[target] = true
		}
	}

	for _, part := range parts {
		switch strings.ToLower(strings.TrimSpace(part)) {
		case "redis":
			addTarget(bench.TargetRedis)
		case "tarantool":
			addTarget(bench.TargetTarantool)
		case "ydb":
			addTarget(bench.TargetYDB)
		case "postgres", "postgresql", "pg":
			addTarget(bench.TargetPostgres)
		case "all":
			addTarget(bench.TargetRedis)
			addTarget(bench.TargetTarantool)
			addTarget(bench.TargetYDB)
			addTarget(bench.TargetPostgres)
		case "":
			// Ignore empty chunks to tolerate trailing commas.
		default:
			return nil, fmt.Errorf("invalid --target=%q: use redis, tarantool, ydb, postgres or all", value)
		}
	}

	if len(targets) == 0 {
		return nil, fmt.Errorf("target list is empty")
	}
	return targets, nil
}

func parseOperations(value string) ([]bench.Operation, error) {
	switch strings.ToLower(value) {
	case "set":
		return []bench.Operation{bench.OperationSet}, nil
	case "get":
		return []bench.Operation{bench.OperationGet}, nil
	case "all":
		return []bench.Operation{bench.OperationSet, bench.OperationGet}, nil
	default:
		return nil, fmt.Errorf("invalid --operation=%q: use set, get or all", value)
	}
}

func buildTestConfigs(base bench.Config, flags benchFlags) ([]bench.Config, error) {
	if flags.runs <= 0 {
		return nil, fmt.Errorf("runs must be greater than zero")
	}

	requestsValues, err := parsePositiveIntList("requests-list", flags.requestsList, flags.requests)
	if err != nil {
		return nil, err
	}

	concurrencyValues, err := parsePositiveIntList("concurrency-list", flags.concurrencyList, flags.concurrency)
	if err != nil {
		return nil, err
	}

	valueSizeValues, err := parsePositiveIntList("value-size-list", flags.valueSizeList, flags.valueSize)
	if err != nil {
		return nil, err
	}

	configs := make([]bench.Config, 0, len(requestsValues)*len(concurrencyValues)*len(valueSizeValues)*flags.runs)
	runID := 0

	for _, requests := range requestsValues {
		for _, concurrency := range concurrencyValues {
			for _, valueSize := range valueSizeValues {
				for repeat := 1; repeat <= flags.runs; repeat++ {
					runID++
					cfg := base
					cfg.Run = runID
					cfg.Requests = requests
					cfg.Concurrency = concurrency
					cfg.ValueSize = valueSize
					cfg.KeyPrefix = fmt.Sprintf("%s:run%d", base.KeyPrefix, runID)
					configs = append(configs, cfg)
				}
			}
		}
	}

	return configs, nil
}

func parsePositiveIntList(flagName string, raw string, fallback int) ([]int, error) {
	if strings.TrimSpace(raw) == "" {
		if fallback <= 0 {
			return nil, fmt.Errorf("%s fallback value must be greater than zero", flagName)
		}
		return []int{fallback}, nil
	}

	parts := strings.Split(raw, ",")
	values := make([]int, 0, len(parts))

	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			return nil, fmt.Errorf("%s contains empty value", flagName)
		}

		value, err := strconv.Atoi(part)
		if err != nil {
			return nil, fmt.Errorf("invalid %s value %q: %w", flagName, part, err)
		}
		if value <= 0 {
			return nil, fmt.Errorf("%s values must be greater than zero", flagName)
		}

		values = append(values, value)
	}

	return values, nil
}

func parseStringList(raw string) ([]string, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, nil
	}

	parts := strings.Split(raw, ",")
	values := make([]string, 0, len(parts))

	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			return nil, fmt.Errorf("string list contains empty value")
		}
		values = append(values, part)
	}

	return values, nil
}
