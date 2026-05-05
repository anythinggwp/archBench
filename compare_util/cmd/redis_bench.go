package cmd

import (
	"fmt"

	"github.com/anythinggwp/archBench/compare_util/internal"
	"github.com/spf13/cobra"
)

var redisBenchCfg struct {
	InputGlob  string
	OutputPath string
	KeyColumn  string
	Column     string
}

var redisBenchCmd = &cobra.Command{
	Use:   "redis-bench",
	Short: "Aggregate Redis benchmark CSV files",
	Long: `Aggregate multiple Redis benchmark CSV files.

The command reads several CSV files, groups rows by benchmark name,
and calculates count, mean, median, min and max for numeric columns.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		return runRedisBench()
	},
}

func init() {
	RootCmd.AddCommand(redisBenchCmd)

	redisBenchCmd.Flags().StringVarP(
		&redisBenchCfg.InputGlob,
		"input",
		"i",
		"",
		`input CSV glob, for example "./*.csv" or "./results/*.csv"`,
	)

	redisBenchCmd.Flags().StringVarP(
		&redisBenchCfg.OutputPath,
		"out",
		"o",
		"result.csv",
		"output CSV file path",
	)

	redisBenchCmd.Flags().StringVar(
		&redisBenchCfg.KeyColumn,
		"key",
		"",
		"grouping column name; default is first column",
	)
	redisBenchCmd.Flags().StringVarP(
		&redisBenchCfg.Column,
		"column",
		"c",
		"",
		"numeric column to aggregate; if empty, all numeric columns are aggregated",
	)
	_ = redisBenchCmd.MarkFlagRequired("input")
}

func runRedisBench() error {
	result, err := internal.AggregateRedisBenchCSV(internal.RedisBenchAggregateOptions{
		InputGlob:  redisBenchCfg.InputGlob,
		OutputPath: redisBenchCfg.OutputPath,
		KeyColumn:  redisBenchCfg.KeyColumn,
		Column:     redisBenchCfg.Column,
	})
	if err != nil {
		return err
	}

	fmt.Printf("Processed files: %d\n", result.ProcessedFiles)
	fmt.Printf("Processed rows: %d\n", result.ProcessedRows)
	fmt.Printf("Written output: %s\n", result.OutputPath)

	return nil
}
