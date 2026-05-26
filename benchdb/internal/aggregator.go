package internal

import (
	"context"
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
	TargetYDB       Target = "ydb"
	TargetPostgres  Target = "postgres"
)

type Operation string

const (
	OperationSet Operation = "set"
	OperationGet Operation = "get"
)

type Config struct {
	Run          int
	Requests     int
	Concurrency  int
	ValueSize    int
	LoadDuration time.Duration
	KeyPrefix    string
	Timeout      time.Duration
	SetMode      string

	VersionedSetKeys        int
	VersionedSetChangeEvery int

	Redis     RedisConfig
	Tarantool TarantoolConfig
	YDB       YDBConfig
	Postgres  PostgresConfig
}

type RedisConfig struct {
	// Mode selects Redis client implementation:
	//   standalone - ordinary single-node Redis client
	//   cluster    - Redis Cluster client with hash-slot routing
	Mode         string
	Addr         string
	ClusterAddrs []string
	Password     string
	DB           int
}

type TarantoolConfig struct {
	Addr        string
	Addrs       []string
	User        string
	Password    string
	Space       string
	SkipDDLInit bool
	MaxConns    int

	// direct — старый режим через space:replace/get
	// cluster — client-side sharding over multiple direct Tarantool instances
	// call   — вызов Lua-функций
	// vshard — вызов Lua-функций на vshard-router
	// crud   — вызов официального CRUD API на vshard-router
	Mode string

	SetFunc      string
	GetFunc      string
	TruncateFunc string
}

type YDBConfig struct {
	ConnectionString string
	Table            string
	SkipDDLInit      bool
	MaxOpenConns     int
}

type PostgresConfig struct {
	ConnString  string
	Table       string
	SkipDDLInit bool
	MaxConns    int
	User        string
	Password    string
	DB          string
}

type Result struct {
	Run          int           `json:"run"`
	Target       Target        `json:"target"`
	Operation    Operation     `json:"operation"`
	Requests     int           `json:"requests"`
	Concurrency  int           `json:"concurrency"`
	ValueSize    int           `json:"value_size"`
	LoadDuration time.Duration `json:"load_duration_ns,omitempty"`
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

type Summary struct {
	Target       Target        `json:"target"`
	Operation    Operation     `json:"operation"`
	Requests     int           `json:"requests"`
	Concurrency  int           `json:"concurrency"`
	ValueSize    int           `json:"value_size"`
	LoadDuration time.Duration `json:"load_duration_ns,omitempty"`
	Runs         int           `json:"runs"`

	SuccessTotal int64 `json:"success_total"`
	FailedTotal  int64 `json:"failed_total"`

	DurationAvg time.Duration `json:"duration_avg_ns"`
	DurationMin time.Duration `json:"duration_min_ns"`
	DurationMax time.Duration `json:"duration_max_ns"`

	ThroughputAvg float64 `json:"throughput_avg_ops_sec"`
	ThroughputMin float64 `json:"throughput_min_ops_sec"`
	ThroughputMax float64 `json:"throughput_max_ops_sec"`

	AvgLatencyAvg time.Duration `json:"avg_latency_avg_ns"`
	AvgLatencyMin time.Duration `json:"avg_latency_min_ns"`
	AvgLatencyMax time.Duration `json:"avg_latency_max_ns"`

	MinLatencyMin time.Duration `json:"min_latency_min_ns"`
	MaxLatencyMax time.Duration `json:"max_latency_max_ns"`

	P50LatencyAvg time.Duration `json:"p50_latency_avg_ns"`
	P95LatencyAvg time.Duration `json:"p95_latency_avg_ns"`
	P99LatencyAvg time.Duration `json:"p99_latency_avg_ns"`
}

type Report struct {
	Results []Result  `json:"results"`
	Summary []Summary `json:"summary,omitempty"`
}

func (c Config) Validate() error {
	if c.Run < 0 {
		return errors.New("run must not be negative")
	}
	if c.Requests <= 0 {
		return errors.New("requests must be greater than zero")
	}
	if c.Concurrency <= 0 {
		return errors.New("concurrency must be greater than zero")
	}
	if c.ValueSize <= 0 {
		return errors.New("value-size must be greater than zero")
	}
	if c.LoadDuration < 0 {
		return errors.New("load-duration must not be negative")
	}
	if c.Timeout <= 0 {
		return errors.New("timeout must be greater than zero")
	}
	if c.KeyPrefix == "" {
		return errors.New("key-prefix must not be empty")
	}
	setMode := normalizeSetMode(c.SetMode)
	switch setMode {
	case "plain", "versioned":
	default:
		return fmt.Errorf("invalid set-mode %q: use plain or versioned", c.SetMode)
	}
	if setMode == "versioned" {
		if c.ValueSize < versionedValueHeaderLen {
			return fmt.Errorf("value-size must be at least %d when set-mode=versioned", versionedValueHeaderLen)
		}
		if c.VersionedSetKeys <= 0 {
			return errors.New("versioned-set-keys must be greater than zero when set-mode=versioned")
		}
		if c.VersionedSetChangeEvery <= 0 {
			return errors.New("versioned-set-change-every must be greater than zero when set-mode=versioned")
		}
	}
	redisMode := strings.ToLower(strings.TrimSpace(c.Redis.Mode))
	if redisMode == "" {
		redisMode = "standalone"
	}

	switch redisMode {
	case "standalone", "single":
		if c.Redis.Addr == "" {
			return errors.New("redis-addr must not be empty")
		}

	case "cluster":
		if len(c.Redis.ClusterAddrs) == 0 {
			return errors.New("redis-cluster-addrs must not be empty when redis-mode=cluster")
		}

	default:
		return fmt.Errorf("invalid redis-mode %q: use standalone or cluster", c.Redis.Mode)
	}
	if len(c.Tarantool.Addrs) == 0 && strings.TrimSpace(c.Tarantool.Addr) == "" {
		return errors.New("tarantool-addr or tarantool-addrs must not be empty")
	}
	for _, addr := range c.Tarantool.Addrs {
		if strings.TrimSpace(addr) == "" {
			return errors.New("tarantool-addrs must not contain empty addresses")
		}
	}
	if c.Tarantool.User == "" {
		return errors.New("tarantool-user must not be empty")
	}
	if c.Tarantool.Space == "" {
		return errors.New("tarantool-space must not be empty")
	}
	if c.Tarantool.MaxConns < 0 {
		return errors.New("tarantool-max-conns must not be negative")
	}
	tarantoolMode := normalizeTarantoolMode(c.Tarantool.Mode)
	switch tarantoolMode {
	case "direct", "cluster", "call", "vshard", "crud":
	default:
		return fmt.Errorf("invalid tarantool-mode %q: use direct, cluster, call, vshard or crud", c.Tarantool.Mode)
	}
	if tarantoolMode == "cluster" && len(cleanStringList(c.Tarantool.Addrs)) == 0 {
		return errors.New("tarantool-addrs must not be empty when tarantool-mode=cluster")
	}
	if tarantoolMode == "call" || tarantoolMode == "vshard" {
		if strings.TrimSpace(c.Tarantool.SetFunc) == "" {
			return errors.New("tarantool-set-func must not be empty in call/vshard mode")
		}
		if strings.TrimSpace(c.Tarantool.GetFunc) == "" {
			return errors.New("tarantool-get-func must not be empty in call/vshard mode")
		}
		if strings.TrimSpace(c.Tarantool.TruncateFunc) == "" {
			return errors.New("tarantool-truncate-func must not be empty in call/vshard mode")
		}
	}
	if c.YDB.ConnectionString == "" {
		return errors.New("ydb-connection-string must not be empty")
	}
	if c.YDB.Table == "" {
		return errors.New("ydb-table must not be empty")
	}
	if c.Postgres.ConnString == "" {
		return errors.New("postgres-conn must not be empty")
	}
	if c.Postgres.Table == "" {
		return errors.New("postgres-table must not be empty")
	}
	return nil
}

type operationFunc func(key string, value string) error
type indexedOperationFunc func(idx int, key string, value string) error
type keyValueFunc func(idx int) (string, string)

func runMeasured(ctx context.Context, target Target, operation Operation, cfg Config, fn operationFunc) Result {
	value := strings.Repeat("x", cfg.ValueSize)
	return runMeasuredIndexed(ctx, target, operation, cfg, func(idx int) (string, string) {
		return makeKey(cfg.KeyPrefix, target, operation, measuredKeyIndex(cfg, idx)), value
	}, func(_ int, key string, value string) error {
		return fn(key, value)
	})
}

func runMeasuredIndexed(ctx context.Context, target Target, operation Operation, cfg Config, keyValue keyValueFunc, fn indexedOperationFunc) Result {
	if cfg.LoadDuration > 0 {
		return runMeasuredForDuration(ctx, target, operation, cfg, keyValue, fn)
	}

	latencies := make([]time.Duration, cfg.Requests)

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
				select {
				case <-ctx.Done():
					return
				default:
				}

				idx := int(atomic.AddInt64(&next, 1) - 1)
				if idx >= cfg.Requests {
					return
				}

				key, value := keyValue(idx)
				opStartedAt := time.Now()
				err := fn(idx, key, value)
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

func runMeasuredForDuration(ctx context.Context, target Target, operation Operation, cfg Config, keyValue keyValueFunc, fn indexedOperationFunc) Result {
	runCtx, cancel := context.WithTimeout(ctx, cfg.LoadDuration)
	defer cancel()

	var next int64
	var success int64
	var failed int64
	var errMu sync.Mutex
	sampleErrors := make([]string, 0, 8)

	startedAt := time.Now()
	latencyCh := make(chan []time.Duration, cfg.Concurrency)
	var wg sync.WaitGroup
	wg.Add(cfg.Concurrency)

	for workerID := 0; workerID < cfg.Concurrency; workerID++ {
		go func() {
			defer wg.Done()

			localLatencies := make([]time.Duration, 0, 1024)
			defer func() {
				latencyCh <- localLatencies
			}()

			for {
				select {
				case <-runCtx.Done():
					return
				default:
				}

				idx := int(atomic.AddInt64(&next, 1) - 1)
				key, value := keyValue(idx)
				opStartedAt := time.Now()
				err := fn(idx, key, value)
				localLatencies = append(localLatencies, time.Since(opStartedAt))

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
	close(latencyCh)
	totalDuration := time.Since(startedAt)

	var latencies []time.Duration
	for workerLatencies := range latencyCh {
		latencies = append(latencies, workerLatencies...)
	}

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
			Run:          cfg.Run,
			Target:       target,
			Operation:    operation,
			Requests:     cfg.Requests,
			Concurrency:  cfg.Concurrency,
			ValueSize:    cfg.ValueSize,
			LoadDuration: cfg.LoadDuration,
			Success:      success,
			Failed:       failed,
			Duration:     totalDuration,
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
		Run:          cfg.Run,
		Target:       target,
		Operation:    operation,
		Requests:     cfg.Requests,
		Concurrency:  cfg.Concurrency,
		ValueSize:    cfg.ValueSize,
		LoadDuration: cfg.LoadDuration,
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

func measuredKeyIndex(cfg Config, idx int) int {
	if cfg.LoadDuration > 0 && cfg.Requests > 0 {
		return idx % cfg.Requests
	}
	return idx
}

const versionedValueHeaderLen = len("v=00000000000000000000;")

func normalizeSetMode(mode string) string {
	mode = strings.ToLower(strings.TrimSpace(mode))
	switch mode {
	case "", "plain", "normal", "default":
		return "plain"
	case "versioned", "version", "if-version-changed":
		return "versioned"
	default:
		return mode
	}
}

func makeVersionedSetKeyValue(cfg Config, target Target, idx int) (string, string) {
	keyCount := cfg.VersionedSetKeys
	if keyCount <= 0 {
		keyCount = 1
	}

	changeEvery := cfg.VersionedSetChangeEvery
	if changeEvery <= 0 {
		changeEvery = 1
	}

	keyIdx := idx % keyCount
	visit := idx / keyCount
	version := uint64(visit / changeEvery)

	key := fmt.Sprintf("%s:%s:%s:versioned:%d", cfg.KeyPrefix, target, OperationSet, keyIdx)
	value := makeVersionedValue(version, cfg.ValueSize)
	return key, value
}

func makeVersionedValue(version uint64, size int) string {
	prefix := fmt.Sprintf("v=%020d;", version)
	if size <= len(prefix) {
		return prefix
	}
	return prefix + strings.Repeat("x", size-len(prefix))
}

func valueVersion(value string) string {
	if len(value) < versionedValueHeaderLen {
		return value
	}
	return value[:versionedValueHeaderLen]
}

func valueVersionChanged(current string, next string) bool {
	return valueVersion(current) != valueVersion(next)
}

func PrintResults(w io.Writer, results []Result) {
	fmt.Fprintln(w)
	fmt.Fprintf(w, "%-5s %-10s %-9s %10s %6s %8s %10s %10s %10s %14s %12s %12s %12s %12s\n",
		"RUN", "TARGET", "OP", "REQUESTS", "CONC", "VALUE", "LOAD", "SUCCESS", "FAILED", "OPS/SEC", "AVG", "P50", "P95", "P99")
	fmt.Fprintf(w, "%s\n", strings.Repeat("-", 156))

	for _, r := range results {
		fmt.Fprintf(w, "%-5d %-10s %-9s %10d %6d %8d %10s %10d %10d %14.2f %12s %12s %12s %12s\n",
			r.Run,
			r.Target,
			r.Operation,
			r.Requests,
			r.Concurrency,
			r.ValueSize,
			formatLoadDuration(r.LoadDuration),
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

func BuildSummary(results []Result) []Summary {
	groups := make(map[summaryKey][]Result)
	keys := make([]summaryKey, 0)

	for _, r := range results {
		key := summaryKey{
			Target:       r.Target,
			Operation:    r.Operation,
			Requests:     r.Requests,
			Concurrency:  r.Concurrency,
			ValueSize:    r.ValueSize,
			LoadDuration: r.LoadDuration,
		}
		if _, ok := groups[key]; !ok {
			keys = append(keys, key)
		}
		groups[key] = append(groups[key], r)
	}

	sort.Slice(keys, func(i, j int) bool {
		return keys[i].less(keys[j])
	})

	summaries := make([]Summary, 0, len(keys))
	for _, key := range keys {
		summaries = append(summaries, summarizeGroup(key, groups[key]))
	}

	return summaries
}

type summaryKey struct {
	Target       Target
	Operation    Operation
	Requests     int
	Concurrency  int
	ValueSize    int
	LoadDuration time.Duration
}

func (k summaryKey) less(other summaryKey) bool {
	if k.Target != other.Target {
		return k.Target < other.Target
	}
	if k.Operation != other.Operation {
		return k.Operation < other.Operation
	}
	if k.Requests != other.Requests {
		return k.Requests < other.Requests
	}
	if k.Concurrency != other.Concurrency {
		return k.Concurrency < other.Concurrency
	}
	if k.ValueSize != other.ValueSize {
		return k.ValueSize < other.ValueSize
	}
	return k.LoadDuration < other.LoadDuration
}

func summarizeGroup(key summaryKey, results []Result) Summary {
	if len(results) == 0 {
		return Summary{
			Target:       key.Target,
			Operation:    key.Operation,
			Requests:     key.Requests,
			Concurrency:  key.Concurrency,
			ValueSize:    key.ValueSize,
			LoadDuration: key.LoadDuration,
		}
	}

	s := Summary{
		Target:        key.Target,
		Operation:     key.Operation,
		Requests:      key.Requests,
		Concurrency:   key.Concurrency,
		ValueSize:     key.ValueSize,
		LoadDuration:  key.LoadDuration,
		Runs:          len(results),
		DurationMin:   results[0].Duration,
		DurationMax:   results[0].Duration,
		ThroughputMin: results[0].Throughput,
		ThroughputMax: results[0].Throughput,
		AvgLatencyMin: results[0].AvgLatency,
		AvgLatencyMax: results[0].AvgLatency,
		MinLatencyMin: results[0].MinLatency,
		MaxLatencyMax: results[0].MaxLatency,
	}

	var durationSum time.Duration
	var avgLatencySum time.Duration
	var p50LatencySum time.Duration
	var p95LatencySum time.Duration
	var p99LatencySum time.Duration
	var throughputSum float64

	for _, r := range results {
		s.SuccessTotal += r.Success
		s.FailedTotal += r.Failed

		durationSum += r.Duration
		throughputSum += r.Throughput
		avgLatencySum += r.AvgLatency
		p50LatencySum += r.P50Latency
		p95LatencySum += r.P95Latency
		p99LatencySum += r.P99Latency

		if r.Duration < s.DurationMin {
			s.DurationMin = r.Duration
		}
		if r.Duration > s.DurationMax {
			s.DurationMax = r.Duration
		}
		if r.Throughput < s.ThroughputMin {
			s.ThroughputMin = r.Throughput
		}
		if r.Throughput > s.ThroughputMax {
			s.ThroughputMax = r.Throughput
		}
		if r.AvgLatency < s.AvgLatencyMin {
			s.AvgLatencyMin = r.AvgLatency
		}
		if r.AvgLatency > s.AvgLatencyMax {
			s.AvgLatencyMax = r.AvgLatency
		}
		if r.MinLatency < s.MinLatencyMin {
			s.MinLatencyMin = r.MinLatency
		}
		if r.MaxLatency > s.MaxLatencyMax {
			s.MaxLatencyMax = r.MaxLatency
		}
	}

	n := time.Duration(len(results))
	s.DurationAvg = durationSum / n
	s.ThroughputAvg = throughputSum / float64(len(results))
	s.AvgLatencyAvg = avgLatencySum / n
	s.P50LatencyAvg = p50LatencySum / n
	s.P95LatencyAvg = p95LatencySum / n
	s.P99LatencyAvg = p99LatencySum / n

	return s
}

func PrintSummary(w io.Writer, summaries []Summary) {
	if len(summaries) == 0 {
		return
	}

	fmt.Fprintln(w)
	fmt.Fprintln(w, "SUMMARY")
	fmt.Fprintf(w, "%-10s %-9s %10s %6s %8s %10s %5s %12s %12s %12s %12s %12s %12s %12s\n",
		"TARGET", "OP", "REQUESTS", "CONC", "VALUE", "LOAD", "RUNS", "OPS_AVG", "OPS_MIN", "OPS_MAX", "AVG_LAT", "AVG_MIN", "AVG_MAX", "P99_AVG")
	fmt.Fprintf(w, "%s\n", strings.Repeat("-", 166))

	for _, s := range summaries {
		fmt.Fprintf(w, "%-10s %-9s %10d %6d %8d %10s %5d %12.2f %12.2f %12.2f %12s %12s %12s %12s\n",
			s.Target,
			s.Operation,
			s.Requests,
			s.Concurrency,
			s.ValueSize,
			formatLoadDuration(s.LoadDuration),
			s.Runs,
			s.ThroughputAvg,
			s.ThroughputMin,
			s.ThroughputMax,
			formatDuration(s.AvgLatencyAvg),
			formatDuration(s.AvgLatencyMin),
			formatDuration(s.AvgLatencyMax),
			formatDuration(s.P99LatencyAvg),
		)
	}
	fmt.Fprintln(w)
}

func WriteResults(path string, format string, results []Result, summaries []Summary) error {
	file, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("create output file: %w", err)
	}
	defer file.Close()

	switch strings.ToLower(format) {
	case "json":
		encoder := json.NewEncoder(file)
		encoder.SetIndent("", "  ")
		if len(summaries) == 0 {
			return encoder.Encode(results)
		}
		return encoder.Encode(Report{Results: results, Summary: summaries})
	case "csv":
		if len(summaries) == 0 {
			return writeResultsOnlyCSV(file, results)
		}
		return writeCSV(file, results, summaries)
	default:
		return fmt.Errorf("unsupported file format %q: use json or csv", format)
	}
}

func writeResultsOnlyCSV(w io.Writer, results []Result) error {
	cw := csv.NewWriter(w)
	defer cw.Flush()

	header := []string{
		"run", "target", "operation", "requests", "concurrency", "value_size", "load_duration_sec", "success", "failed",
		"duration_sec", "throughput_ops_sec", "avg_latency_ms", "min_latency_ms",
		"max_latency_ms", "p50_latency_ms", "p95_latency_ms", "p99_latency_ms",
	}
	if err := cw.Write(header); err != nil {
		return err
	}

	for _, r := range results {
		record := []string{
			fmt.Sprintf("%d", r.Run),
			string(r.Target),
			string(r.Operation),
			fmt.Sprintf("%d", r.Requests),
			fmt.Sprintf("%d", r.Concurrency),
			fmt.Sprintf("%d", r.ValueSize),
			fmt.Sprintf("%.6f", r.LoadDuration.Seconds()),
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

func writeCSV(w io.Writer, results []Result, summaries []Summary) error {
	cw := csv.NewWriter(w)
	defer cw.Flush()

	header := []string{
		"record_type", "run", "target", "operation", "requests", "concurrency", "value_size", "load_duration_sec", "runs",
		"success", "failed", "success_total", "failed_total",
		"duration_sec", "duration_avg_sec", "duration_min_sec", "duration_max_sec",
		"throughput_ops_sec", "throughput_avg_ops_sec", "throughput_min_ops_sec", "throughput_max_ops_sec",
		"avg_latency_ms", "avg_latency_avg_ms", "avg_latency_min_ms", "avg_latency_max_ms",
		"min_latency_ms", "min_latency_min_ms", "max_latency_ms", "max_latency_max_ms",
		"p50_latency_ms", "p50_latency_avg_ms", "p95_latency_ms", "p95_latency_avg_ms", "p99_latency_ms", "p99_latency_avg_ms",
	}
	if err := cw.Write(header); err != nil {
		return err
	}

	for _, r := range results {
		record := []string{
			"result",
			fmt.Sprintf("%d", r.Run),
			string(r.Target),
			string(r.Operation),
			fmt.Sprintf("%d", r.Requests),
			fmt.Sprintf("%d", r.Concurrency),
			fmt.Sprintf("%d", r.ValueSize),
			fmt.Sprintf("%.6f", r.LoadDuration.Seconds()),
			"",
			fmt.Sprintf("%d", r.Success),
			fmt.Sprintf("%d", r.Failed),
			"",
			"",
			fmt.Sprintf("%.6f", r.Duration.Seconds()),
			"",
			"",
			"",
			fmt.Sprintf("%.2f", r.Throughput),
			"",
			"",
			"",
			fmt.Sprintf("%.6f", durationMillis(r.AvgLatency)),
			"",
			"",
			"",
			fmt.Sprintf("%.6f", durationMillis(r.MinLatency)),
			"",
			fmt.Sprintf("%.6f", durationMillis(r.MaxLatency)),
			"",
			fmt.Sprintf("%.6f", durationMillis(r.P50Latency)),
			"",
			fmt.Sprintf("%.6f", durationMillis(r.P95Latency)),
			"",
			fmt.Sprintf("%.6f", durationMillis(r.P99Latency)),
			"",
		}
		if err := cw.Write(record); err != nil {
			return err
		}
	}

	for _, s := range summaries {
		record := []string{
			"summary",
			"",
			string(s.Target),
			string(s.Operation),
			fmt.Sprintf("%d", s.Requests),
			fmt.Sprintf("%d", s.Concurrency),
			fmt.Sprintf("%d", s.ValueSize),
			fmt.Sprintf("%.6f", s.LoadDuration.Seconds()),
			fmt.Sprintf("%d", s.Runs),
			"",
			"",
			fmt.Sprintf("%d", s.SuccessTotal),
			fmt.Sprintf("%d", s.FailedTotal),
			"",
			fmt.Sprintf("%.6f", s.DurationAvg.Seconds()),
			fmt.Sprintf("%.6f", s.DurationMin.Seconds()),
			fmt.Sprintf("%.6f", s.DurationMax.Seconds()),
			"",
			fmt.Sprintf("%.2f", s.ThroughputAvg),
			fmt.Sprintf("%.2f", s.ThroughputMin),
			fmt.Sprintf("%.2f", s.ThroughputMax),
			"",
			fmt.Sprintf("%.6f", durationMillis(s.AvgLatencyAvg)),
			fmt.Sprintf("%.6f", durationMillis(s.AvgLatencyMin)),
			fmt.Sprintf("%.6f", durationMillis(s.AvgLatencyMax)),
			"",
			fmt.Sprintf("%.6f", durationMillis(s.MinLatencyMin)),
			"",
			fmt.Sprintf("%.6f", durationMillis(s.MaxLatencyMax)),
			"",
			fmt.Sprintf("%.6f", durationMillis(s.P50LatencyAvg)),
			"",
			fmt.Sprintf("%.6f", durationMillis(s.P95LatencyAvg)),
			"",
			fmt.Sprintf("%.6f", durationMillis(s.P99LatencyAvg)),
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

func formatLoadDuration(d time.Duration) string {
	if d <= 0 {
		return "-"
	}
	return d.String()
}

func durationMillis(d time.Duration) float64 {
	return float64(d.Nanoseconds()) / float64(time.Millisecond)
}
