package internal

import (
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"sort"
	"strconv"
	"strings"
)

type BenchmarkEntry struct {
	Name string `json:"name"`

	RealTime       *float64 `json:"real_time,omitempty"`
	CPUTime        *float64 `json:"cpu_time,omitempty"`
	Iterations     *float64 `json:"iterations,omitempty"`
	BytesPerSecond *float64 `json:"bytes_per_second,omitempty"`
	ItemsPerSecond *float64 `json:"items_per_second,omitempty"`

	TimeUnit string `json:"time_unit,omitempty"`
}

type BenchmarkFile struct {
	Benchmarks []BenchmarkEntry `json:"benchmarks"`
}

type FileData struct {
	Arch     string
	Filename string
	Values   map[string]map[string]float64 // benchmark_name -> metric -> value
}

var supportedMetrics = []string{
	"real_time",
	"cpu_time",
	"iterations",
	"bytes_per_second",
	"items_per_second",
}

func Die(msg string) {
	fmt.Fprintln(os.Stderr, "error:", msg)
	os.Exit(1)
}

func IsTimeMetric(metric string) bool {
	return metric == "real_time" || metric == "cpu_time"
}

func UnitToNSFactor(unit string) float64 {
	switch unit {
	case "ns":
		return 1.0
	case "us":
		return 1e3
	case "ms":
		return 1e6
	case "s":
		return 1e9
	case "ps":
		return 1e-3
	default:
		return 1.0
	}
}

func MetricValue(entry BenchmarkEntry, metric string) (float64, bool) {
	switch metric {
	case "real_time":
		if entry.RealTime == nil {
			return 0, false
		}
		return *entry.RealTime, true
	case "cpu_time":
		if entry.CPUTime == nil {
			return 0, false
		}
		return *entry.CPUTime, true
	case "iterations":
		if entry.Iterations == nil {
			return 0, false
		}
		return *entry.Iterations, true
	case "bytes_per_second":
		if entry.BytesPerSecond == nil {
			return 0, false
		}
		return *entry.BytesPerSecond, true
	case "items_per_second":
		if entry.ItemsPerSecond == nil {
			return 0, false
		}
		return *entry.ItemsPerSecond, true
	default:
		return 0, false
	}
}

func MetricList(metricFlag string) ([]string, error) {
	if metricFlag == "all" {
		return supportedMetrics, nil
	}
	for _, m := range supportedMetrics {
		if metricFlag == m {
			return []string{metricFlag}, nil
		}
	}
	return nil, fmt.Errorf("unsupported metric: %s", metricFlag)
}

func ParseGoogleBenchmarkJSON(arch, path string) (FileData, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return FileData{}, err
	}

	var bf BenchmarkFile
	if err := json.Unmarshal(data, &bf); err != nil {
		return FileData{}, err
	}
	if bf.Benchmarks == nil {
		return FileData{}, errors.New("not a google benchmark json: no benchmarks field")
	}

	fd := FileData{
		Arch:     arch,
		Filename: path,
		Values:   make(map[string]map[string]float64),
	}

	for _, b := range bf.Benchmarks {
		if b.Name == "" {
			continue
		}

		if _, ok := fd.Values[b.Name]; !ok {
			fd.Values[b.Name] = make(map[string]float64)
		}

		for _, metric := range supportedMetrics {
			v, ok := MetricValue(b, metric)
			if !ok {
				continue
			}
			if IsTimeMetric(metric) {
				unit := b.TimeUnit
				if unit == "" {
					unit = "ns"
				}
				v *= UnitToNSFactor(unit)
			}
			fd.Values[b.Name][metric] = v
		}
	}

	return fd, nil
}

func formatFloat(v float64) string {
	if math.IsNaN(v) {
		return ""
	}
	return strconv.FormatFloat(v, 'f', 6, 64)
}

func formatPercentDelta(base, other float64) string {
	if math.IsNaN(base) || math.IsNaN(other) || base == 0 {
		return ""
	}
	pct := ((other - base) / base) * 100.0
	return strconv.FormatFloat(pct, 'f', 2, 64)
}

func collectAllNames(files []FileData) []string {
	set := make(map[string]struct{})
	for _, f := range files {
		for name := range f.Values {
			set[name] = struct{}{}
		}
	}

	names := make([]string, 0, len(set))
	for name := range set {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

func bestArch(files []FileData, values []float64, metric string) (string, float64) {
	if len(files) != len(values) {
		return "", math.NaN()
	}

	bestIdx := -1
	bestVal := 0.0
	higherIsBetter := strings.HasSuffix(metric, "_per_second")

	for i, v := range values {
		if math.IsNaN(v) {
			continue
		}
		if bestIdx == -1 {
			bestIdx = i
			bestVal = v
			continue
		}
		if higherIsBetter {
			if v > bestVal {
				bestIdx = i
				bestVal = v
			}
		} else {
			if v < bestVal {
				bestIdx = i
				bestVal = v
			}
		}
	}

	if bestIdx == -1 {
		return "", math.NaN()
	}
	return files[bestIdx].Arch, bestVal
}

func metricValueFromFile(file FileData, benchName, metric string) (float64, bool) {
	benchMetrics, ok := file.Values[benchName]
	if !ok {
		return 0, false
	}
	v, ok := benchMetrics[metric]
	return v, ok
}

func WriteCSV(files []FileData, metrics []string, outPath string) error {
	if len(files) != 3 {
		return errors.New("this utility expects exactly 3 architecture inputs")
	}

	var out *os.File
	var err error
	if outPath == "" {
		out = os.Stdout
	} else {
		out, err = os.Create(outPath)
		if err != nil {
			return err
		}
		defer out.Close()
	}

	w := csv.NewWriter(out)
	defer w.Flush()

	header := []string{
		"benchmark",
		"metric",
		files[0].Arch,
		files[1].Arch,
		files[2].Arch,
		"best_arch",
		"best_value",
		files[1].Arch + "_vs_" + files[0].Arch + "_%",
		files[2].Arch + "_vs_" + files[0].Arch + "_%",
	}
	if err := w.Write(header); err != nil {
		return err
	}

	names := collectAllNames(files)

	for _, name := range names {
		for _, metric := range metrics {
			v0, ok0 := metricValueFromFile(files[0], name, metric)
			v1, ok1 := metricValueFromFile(files[1], name, metric)
			v2, ok2 := metricValueFromFile(files[2], name, metric)

			f0 := math.NaN()
			f1 := math.NaN()
			f2 := math.NaN()

			if ok0 {
				f0 = v0
			}
			if ok1 {
				f1 = v1
			}
			if ok2 {
				f2 = v2
			}

			// пропускаем строки, где ни у кого нет этой метрики
			if math.IsNaN(f0) && math.IsNaN(f1) && math.IsNaN(f2) {
				continue
			}

			bestName, bestValue := bestArch(files, []float64{f0, f1, f2}, metric)

			row := []string{
				name,
				metric,
				formatFloat(f0),
				formatFloat(f1),
				formatFloat(f2),
				bestName,
				formatFloat(bestValue),
				formatPercentDelta(f0, f1),
				formatPercentDelta(f0, f2),
			}

			if err := w.Write(row); err != nil {
				return err
			}
		}
	}

	return w.Error()
}
