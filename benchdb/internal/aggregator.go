package bench

import (
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type Target string

const (
	TargetRedis     Target = "redis"
	TargetTarantool Target = "tarantool"
)

type Operation string

const (
	OperationSet Operation = "set"
	OperationGet Operation = "get"
)

type Config struct {
	Requests    int
	Concurrency int
	ValueSize   int
	KeyPrefix   string
	Timeout     time.Duration

	Redis     RedisConfig
	Tarantool TarantoolConfig
}

type RedisConfig struct {
	Addr     string
	Password string
	DB       int
}

type TarantoolConfig struct {
	Addr        string
	User        string
	Password    string
	Space       string
	SkipDDLInit bool
}

type Result struct {
	Target       Target        `json:"target"`
	Operation    Operation     `json:"operation"`
	Requests     int           `json:"requests"`
	Concurrency  int           `json:"concurrency"`
	Success      int64         `json:"success"`
	Failed       int64         `json:"failed"`
	Duration     time.Duration `json:"duration_ns"`
	Throughput   float64       `json:"throughput_ops_sec"`
	AvgLatency   time.Duration `json:"avg_latency_ns"`
	MinLatency   time.Duration `json:"min_latency_ns"`
	MaxLatency   time.Duration `json:"max_latency_ns"`
	P50Latency   time.Duration `json:"p50_latency_ns"`
	P95Latency   time.Duration `json:"p95_latency_ns"`
	P99Latency   time.Duration `json:"p99_latency_ns"`
	SampleErrors []string      `json:"sample_errors,omitempty"`
}

func (c Config) Validate() error {
	if c.Requests <= 0 {
		return errors.New("requests must be greater than zero")
	}
	if c.Concurrency <= 0 {
		return errors.New("concurrency must be greater than zero")
	}
	if c.ValueSize <= 0 {
		return errors.New("value-size must be greater than zero")
	}
	if c.Timeout <= 0 {
		return errors.New("timeout must be greater than zero")
	}
	if c.KeyPrefix == "" {
		return errors.New("key-prefix must not be empty")
	}
	if c.Redis.Addr == "" {
		return errors.New("redis-addr must not be empty")
	}
	if c.Tarantool.Addr == "" {
		return errors.New("tarantool-addr must not be empty")
	}
	if c.Tarantool.User == "" {
		return errors.New("tarantool-user must not be empty")
	}
	if c.Tarantool.Space == "" {
		return errors.New("tarantool-space must not be empty")
	}
	return nil
}

type operationFunc func(key string, value string) error

func runMeasured(target Target, operation Operation, cfg Config, fn operationFunc) Result {
	latencies := make([]time.Duration, cfg.Requests)
	value := strings.Repeat("x", cfg.ValueSize)

	var next int64
	var success int64
	var failed int64
	var errMu sync.Mutex
	sampleErrors := make([]string, 0, 8)

	startedAt := time.Now()
	var wg sync.WaitGroup
	wg.Add(cfg.Concurrency)

	for workerID := 0; workerID < cfg.Concurrency; workerID++ {
		go func() {
			defer wg.Done()

			for {
				idx := int(atomic.AddInt64(&next, 1) - 1)
				if idx >= cfg.Requests {
					return
				}

				key := makeKey(cfg.KeyPrefix, target, operation, idx)
				opStartedAt := time.Now()
				err := fn(key, value)
				latencies[idx] = time.Since(opStartedAt)

				if err != nil {
					atomic.AddInt64(&failed, 1)
					errMu.Lock()
					if len(sampleErrors) < cap(sampleErrors) {
						sampleErrors = append(sampleErrors, err.Error())
					}
					errMu.Unlock()
					continue
				}

				atomic.AddInt64(&success, 1)
			}
		}()
	}

	wg.Wait()
	totalDuration := time.Since(startedAt)

	return aggregateResult(target, operation, cfg, latencies, totalDuration, success, failed, sampleErrors)
}

func aggregateResult(
	target Target,
	operation Operation,
	cfg Config,
	latencies []time.Duration,
	totalDuration time.Duration,
	success int64,
	failed int64,
	sampleErrors []string,
) Result {
	if len(latencies) == 0 {
		return Result{
			Target:      target,
			Operation:   operation,
			Requests:    cfg.Requests,
			Concurrency: cfg.Concurrency,
			Success:     success,
			Failed:      failed,
			Duration:    totalDuration,
		}
	}

	sorted := append([]time.Duration(nil), latencies...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })

	var sum time.Duration
	for _, latency := range latencies {
		sum += latency
	}

	throughput := 0.0
	if totalDuration > 0 {
		throughput = float64(success) / totalDuration.Seconds()
	}

	return Result{
		Target:       target,
		Operation:    operation,
		Requests:     cfg.Requests,
		Concurrency:  cfg.Concurrency,
		Success:      success,
		Failed:       failed,
		Duration:     totalDuration,
		Throughput:   throughput,
		AvgLatency:   sum / time.Duration(len(latencies)),
		MinLatency:   sorted[0],
		MaxLatency:   sorted[len(sorted)-1],
		P50Latency:   percentile(sorted, 0.50),
		P95Latency:   percentile(sorted, 0.95),
		P99Latency:   percentile(sorted, 0.99),
		SampleErrors: sampleErrors,
	}
}

func percentile(sorted []time.Duration, p float64) time.Duration {
	if len(sorted) == 0 {
		return 0
	}
	if len(sorted) == 1 {
		return sorted[0]
	}

	pos := p * float64(len(sorted)-1)
	lower := int(math.Floor(pos))
	upper := int(math.Ceil(pos))
	if lower == upper {
		return sorted[lower]
	}

	weight := pos - float64(lower)
	return time.Duration(float64(sorted[lower])*(1-weight) + float64(sorted[upper])*weight)
}

func makeKey(prefix string, target Target, operation Operation, idx int) string {
	return fmt.Sprintf("%s:%s:%s:%d", prefix, target, operation, idx)
}

func PrintResults(w io.Writer, results []Result) {
	fmt.Fprintln(w)
	fmt.Fprintf(w, "%-10s %-9s %10s %6s %10s %10s %14s %12s %12s %12s %12s\n",
		"TARGET", "OP", "REQUESTS", "CONC", "SUCCESS", "FAILED", "OPS/SEC", "AVG", "P50", "P95", "P99")
	fmt.Fprintf(w, "%s\n", strings.Repeat("-", 125))

	for _, r := range results {
		fmt.Fprintf(w, "%-10s %-9s %10d %6d %10d %10d %14.2f %12s %12s %12s %12s\n",
			r.Target,
			r.Operation,
			r.Requests,
			r.Concurrency,
			r.Success,
			r.Failed,
			r.Throughput,
			formatDuration(r.AvgLatency),
			formatDuration(r.P50Latency),
			formatDuration(r.P95Latency),
			formatDuration(r.P99Latency),
		)

		if len(r.SampleErrors) > 0 {
			fmt.Fprintf(w, "  sample errors for %s/%s:\n", r.Target, r.Operation)
			for _, sample := range r.SampleErrors {
				fmt.Fprintf(w, "    - %s\n", sample)
			}
		}
	}
	fmt.Fprintln(w)
}

func WriteResults(path string, format string, results []Result) error {
	file, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("create output file: %w", err)
	}
	defer file.Close()

	switch strings.ToLower(format) {
	case "json":
		encoder := json.NewEncoder(file)
		encoder.SetIndent("", "  ")
		return encoder.Encode(results)
	case "csv":
		return writeCSV(file, results)
	default:
		return fmt.Errorf("unsupported file format %q: use json or csv", format)
	}
}

func writeCSV(w io.Writer, results []Result) error {
	cw := csv.NewWriter(w)
	defer cw.Flush()

	header := []string{
		"target", "operation", "requests", "concurrency", "success", "failed",
		"duration_sec", "throughput_ops_sec", "avg_latency_ms", "min_latency_ms",
		"max_latency_ms", "p50_latency_ms", "p95_latency_ms", "p99_latency_ms",
	}
	if err := cw.Write(header); err != nil {
		return err
	}

	for _, r := range results {
		record := []string{
			string(r.Target),
			string(r.Operation),
			fmt.Sprintf("%d", r.Requests),
			fmt.Sprintf("%d", r.Concurrency),
			fmt.Sprintf("%d", r.Success),
			fmt.Sprintf("%d", r.Failed),
			fmt.Sprintf("%.6f", r.Duration.Seconds()),
			fmt.Sprintf("%.2f", r.Throughput),
			fmt.Sprintf("%.6f", durationMillis(r.AvgLatency)),
			fmt.Sprintf("%.6f", durationMillis(r.MinLatency)),
			fmt.Sprintf("%.6f", durationMillis(r.MaxLatency)),
			fmt.Sprintf("%.6f", durationMillis(r.P50Latency)),
			fmt.Sprintf("%.6f", durationMillis(r.P95Latency)),
			fmt.Sprintf("%.6f", durationMillis(r.P99Latency)),
		}
		if err := cw.Write(record); err != nil {
			return err
		}
	}

	return cw.Error()
}

func formatDuration(d time.Duration) string {
	if d < time.Microsecond {
		return fmt.Sprintf("%dns", d.Nanoseconds())
	}
	if d < time.Millisecond {
		return fmt.Sprintf("%.2fµs", float64(d.Nanoseconds())/1000.0)
	}
	return fmt.Sprintf("%.2fms", durationMillis(d))
}

func durationMillis(d time.Duration) float64 {
	return float64(d.Nanoseconds()) / float64(time.Millisecond)
}
