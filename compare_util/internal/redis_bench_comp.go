package internal

import (
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

type RedisBenchAggregateOptions struct {
	InputGlob  string
	OutputPath string
	KeyColumn  string
	Column     string
}

type RedisBenchAggregateResult struct {
	ProcessedFiles int
	ProcessedRows  int
	OutputPath     string
}

type RedisBenchResultRow struct {
	Key   string
	Stats map[string]RedisBenchColumnStats
}

type RedisBenchColumnStats struct {
	Count  int
	Mean   float64
	Median float64
	Min    float64
	Max    float64
}

type redisBenchCollector struct {
	Values map[string][]float64
}

func AggregateRedisBenchCSV(opts RedisBenchAggregateOptions) (*RedisBenchAggregateResult, error) {
	if strings.TrimSpace(opts.InputGlob) == "" {
		return nil, errors.New("input glob is required")
	}

	if strings.TrimSpace(opts.OutputPath) == "" {
		opts.OutputPath = "result.csv"
	}

	paths, err := filepath.Glob(opts.InputGlob)
	if err != nil {
		return nil, fmt.Errorf("bad input glob: %w", err)
	}

	if len(paths) == 0 {
		return nil, fmt.Errorf("no CSV files matched input glob: %s", opts.InputGlob)
	}

	groups := make(map[string]*redisBenchCollector)
	numericColumnsSeen := make(map[string]bool)

	var numericColumns []string
	var processedRows int

	for _, path := range paths {
		rows, err := readRedisBenchFile(
			path,
			opts.KeyColumn,
			opts.Column,
			groups,
			numericColumnsSeen,
			&numericColumns,
		)
		if err != nil {
			return nil, err
		}

		processedRows += rows
	}

	rows := buildRedisBenchRows(groups)

	if err := writeRedisBenchSummaryCSV(opts.OutputPath, rows, numericColumns); err != nil {
		return nil, err
	}

	return &RedisBenchAggregateResult{
		ProcessedFiles: len(paths),
		ProcessedRows:  processedRows,
		OutputPath:     opts.OutputPath,
	}, nil
}

func readRedisBenchFile(
	path string,
	keyColumn string,
	targetColumn string,
	groups map[string]*redisBenchCollector,
	numericColumnsSeen map[string]bool,
	numericColumns *[]string,
) (int, error) {
	file, err := os.Open(path)
	if err != nil {
		return 0, fmt.Errorf("open %s: %w", path, err)
	}
	defer file.Close()

	reader := csv.NewReader(file)
	reader.TrimLeadingSpace = true
	reader.FieldsPerRecord = -1

	header, err := reader.Read()
	if err != nil {
		return 0, fmt.Errorf("read CSV header from %s: %w", path, err)
	}

	keyIndex, err := findRedisBenchKeyColumnIndex(header, keyColumn)
	if err != nil {
		return 0, fmt.Errorf("%s: %w", path, err)
	}

	var processedRows int

	for {
		record, err := reader.Read()
		if errors.Is(err, io.EOF) {
			break
		}

		if err != nil {
			return processedRows, fmt.Errorf("read CSV record from %s: %w", path, err)
		}

		if keyIndex >= len(record) {
			continue
		}

		key := strings.TrimSpace(record[keyIndex])
		if key == "" {
			continue
		}

		if _, ok := groups[key]; !ok {
			groups[key] = &redisBenchCollector{
				Values: make(map[string][]float64),
			}
		}

		for i, rawValue := range record {
			if i == keyIndex || i >= len(header) {
				continue
			}

			columnName := strings.TrimSpace(header[i])
			if columnName == "" {
				continue
			}

			if strings.TrimSpace(targetColumn) != "" &&
				!strings.EqualFold(columnName, strings.TrimSpace(targetColumn)) {
				continue
			}

			value, ok := parseRedisBenchNumber(rawValue)
			if !ok {
				continue
			}

			groups[key].Values[columnName] = append(groups[key].Values[columnName], value)

			if !numericColumnsSeen[columnName] {
				numericColumnsSeen[columnName] = true
				*numericColumns = append(*numericColumns, columnName)
			}
		}

		processedRows++
	}

	return processedRows, nil
}

func findRedisBenchKeyColumnIndex(header []string, keyColumn string) (int, error) {
	if len(header) == 0 {
		return 0, errors.New("empty CSV header")
	}

	if strings.TrimSpace(keyColumn) == "" {
		return 0, nil
	}

	for i, column := range header {
		if strings.EqualFold(strings.TrimSpace(column), strings.TrimSpace(keyColumn)) {
			return i, nil
		}
	}

	return 0, fmt.Errorf("key column %q not found", keyColumn)
}

func buildRedisBenchRows(groups map[string]*redisBenchCollector) []RedisBenchResultRow {
	rows := make([]RedisBenchResultRow, 0, len(groups))

	for key, collector := range groups {
		row := RedisBenchResultRow{
			Key:   key,
			Stats: make(map[string]RedisBenchColumnStats),
		}

		for columnName, values := range collector.Values {
			if len(values) == 0 {
				continue
			}

			row.Stats[columnName] = calculateRedisBenchStats(values)
		}

		rows = append(rows, row)
	}

	sort.Slice(rows, func(i, j int) bool {
		return rows[i].Key < rows[j].Key
	})

	return rows
}

func calculateRedisBenchStats(values []float64) RedisBenchColumnStats {
	sortedValues := make([]float64, len(values))
	copy(sortedValues, values)

	sort.Float64s(sortedValues)

	var sum float64
	for _, value := range sortedValues {
		sum += value
	}

	count := len(sortedValues)
	mean := sum / float64(count)

	var median float64
	mid := count / 2

	if count%2 == 0 {
		median = (sortedValues[mid-1] + sortedValues[mid]) / 2
	} else {
		median = sortedValues[mid]
	}

	return RedisBenchColumnStats{
		Count:  count,
		Mean:   mean,
		Median: median,
		Min:    sortedValues[0],
		Max:    sortedValues[count-1],
	}
}

func writeRedisBenchSummaryCSV(
	outputPath string,
	rows []RedisBenchResultRow,
	numericColumns []string,
) error {
	file, err := os.Create(outputPath)
	if err != nil {
		return fmt.Errorf("create output CSV %s: %w", outputPath, err)
	}
	defer file.Close()

	writer := csv.NewWriter(file)
	defer writer.Flush()

	header := []string{"benchmark"}

	for _, column := range numericColumns {
		header = append(
			header,
			column+"_count",
			column+"_mean",
			column+"_median",
			column+"_min",
			column+"_max",
		)
	}

	if err := writer.Write(header); err != nil {
		return fmt.Errorf("write CSV header: %w", err)
	}

	for _, row := range rows {
		record := []string{row.Key}

		for _, column := range numericColumns {
			stats, ok := row.Stats[column]
			if !ok {
				record = append(record, "", "", "", "", "")
				continue
			}

			record = append(
				record,
				strconv.Itoa(stats.Count),
				formatRedisBenchFloat(stats.Mean),
				formatRedisBenchFloat(stats.Median),
				formatRedisBenchFloat(stats.Min),
				formatRedisBenchFloat(stats.Max),
			)
		}

		if err := writer.Write(record); err != nil {
			return fmt.Errorf("write CSV record: %w", err)
		}
	}

	return nil
}

func parseRedisBenchNumber(raw string) (float64, bool) {
	value := strings.TrimSpace(raw)
	value = strings.Trim(value, `"`)
	value = strings.ReplaceAll(value, ",", ".")

	if value == "" {
		return 0, false
	}

	parsed, err := strconv.ParseFloat(value, 64)
	if err != nil {
		return 0, false
	}

	if math.IsNaN(parsed) || math.IsInf(parsed, 0) {
		return 0, false
	}

	return parsed, true
}

func formatRedisBenchFloat(value float64) string {
	return strconv.FormatFloat(value, 'f', 6, 64)
}
