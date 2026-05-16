package cmd

import (
	"context"
	"fmt"
	"strings"
	"time"

	bench "redis-tarantool-bench/internal"

	"github.com/spf13/cobra"
)

type benchFlags struct {
	target      string
	operation   string
	requests    int
	concurrency int
	valueSize   int
	keyPrefix   string
	timeout     time.Duration

	redisAddr     string
	redisPassword string
	redisDB       int

	tarantoolAddr     string
	tarantoolUser     string
	tarantoolPassword string
	tarantoolSpace    string
	tarantoolNoDDL    bool

	print      bool
	outputFile string
	fileFormat string
}

var flags benchFlags

var benchCmd = &cobra.Command{
	Use:   "bench",
	Short: "Run Redis/Tarantool SET/GET benchmark",
	RunE: func(cmd *cobra.Command, args []string) error {
		targets, err := parseTargets(flags.target)
		if err != nil {
			return err
		}

		operations, err := parseOperations(flags.operation)
		if err != nil {
			return err
		}

		cfg := bench.Config{
			Requests:    flags.requests,
			Concurrency: flags.concurrency,
			ValueSize:   flags.valueSize,
			KeyPrefix:   flags.keyPrefix,
			Timeout:     flags.timeout,
			Redis: bench.RedisConfig{
				Addr:     flags.redisAddr,
				Password: flags.redisPassword,
				DB:       flags.redisDB,
			},
			Tarantool: bench.TarantoolConfig{
				Addr:        flags.tarantoolAddr,
				User:        flags.tarantoolUser,
				Password:    flags.tarantoolPassword,
				Space:       flags.tarantoolSpace,
				SkipDDLInit: flags.tarantoolNoDDL,
			},
		}

		if err := cfg.Validate(); err != nil {
			return err
		}

		ctx := context.Background()
		results := make([]bench.Result, 0, len(targets)*len(operations))

		for _, target := range targets {
			for _, operation := range operations {
				var result bench.Result
				var runErr error

				switch target {
				case bench.TargetRedis:
					result, runErr = bench.RunRedis(ctx, cfg, operation)
				case bench.TargetTarantool:
					result, runErr = bench.RunTarantool(ctx, cfg, operation)
				default:
					return fmt.Errorf("unknown target: %s", target)
				}

				if runErr != nil {
					return runErr
				}

				results = append(results, result)
			}
		}

		if flags.print {
			bench.PrintResults(cmd.OutOrStdout(), results)
		}

		if flags.outputFile != "" {
			return bench.WriteResults(flags.outputFile, flags.fileFormat, results)
		}

		return nil
	},
}

func init() {
	rootCmd.AddCommand(benchCmd)

	benchCmd.Flags().StringVar(&flags.target, "target", "all", "benchmark target: redis, tarantool, all")
	benchCmd.Flags().StringVar(&flags.operation, "operation", "all", "operation: set, get, all")
	benchCmd.Flags().IntVar(&flags.requests, "requests", 10000, "total operations per benchmark")
	benchCmd.Flags().IntVar(&flags.concurrency, "concurrency", 16, "number of parallel workers")
	benchCmd.Flags().IntVar(&flags.valueSize, "value-size", 128, "value size in bytes")
	benchCmd.Flags().StringVar(&flags.keyPrefix, "key-prefix", "bench", "key prefix")
	benchCmd.Flags().DurationVar(&flags.timeout, "timeout", 5*time.Second, "connection/request timeout")

	benchCmd.Flags().StringVar(&flags.redisAddr, "redis-addr", "127.0.0.1:6379", "Redis address")
	benchCmd.Flags().StringVar(&flags.redisPassword, "redis-password", "", "Redis password")
	benchCmd.Flags().IntVar(&flags.redisDB, "redis-db", 0, "Redis DB number")

	benchCmd.Flags().StringVar(&flags.tarantoolAddr, "tarantool-addr", "127.0.0.1:3301", "Tarantool address")
	benchCmd.Flags().StringVar(&flags.tarantoolUser, "tarantool-user", "guest", "Tarantool user")
	benchCmd.Flags().StringVar(&flags.tarantoolPassword, "tarantool-password", "", "Tarantool password")
	benchCmd.Flags().StringVar(&flags.tarantoolSpace, "tarantool-space", "kv", "Tarantool space name")
	benchCmd.Flags().BoolVar(&flags.tarantoolNoDDL, "tarantool-no-ddl", false, "do not create Tarantool space/index automatically")

	benchCmd.Flags().BoolVar(&flags.print, "print", true, "print results to terminal")
	benchCmd.Flags().StringVar(&flags.outputFile, "output-file", "", "write results to file; empty means disabled")
	benchCmd.Flags().StringVar(&flags.fileFormat, "file-format", "json", "file format: json, csv")
}

func parseTargets(value string) ([]bench.Target, error) {
	switch strings.ToLower(value) {
	case "redis":
		return []bench.Target{bench.TargetRedis}, nil
	case "tarantool":
		return []bench.Target{bench.TargetTarantool}, nil
	case "all":
		return []bench.Target{bench.TargetRedis, bench.TargetTarantool}, nil
	default:
		return nil, fmt.Errorf("invalid --target=%q: use redis, tarantool or all", value)
	}
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
