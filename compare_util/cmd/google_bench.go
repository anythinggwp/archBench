package cmd

import (
	"fmt"

	"github.com/anythinggwp/archBench/compare_util/internal"
	"github.com/spf13/cobra"
)

var (
	metricFlag string
	outFile    string
)

var compareGoogleBenchCmd = &cobra.Command{
	Use:   "compare <arch1> <file1.json> <arch2> <file2.json> <arch3> <file3.json>",
	Short: "Compare benchmark results for three architectures",
	Args: func(cmd *cobra.Command, args []string) error {
		if len(args) != 6 {
			return fmt.Errorf("expected 6 positional args: <arch1> <file1> <arch2> <file2> <arch3> <file3>")
		}
		return nil
	},
	Run: func(cmd *cobra.Command, args []string) {
		metrics, err := internal.MetricList(metricFlag)
		if err != nil {
			internal.Die(err.Error())
		}

		files := make([]internal.FileData, 0, 3)
		for i := 0; i < 6; i += 2 {
			arch := args[i]
			path := args[i+1]
			fd, err := internal.ParseGoogleBenchmarkJSON(arch, path)
			if err != nil {
				internal.Die(fmt.Sprintf("%s: %v", path, err))
			}
			files = append(files, fd)
		}

		if err := internal.WriteCSV(files, metrics, outFile); err != nil {
			internal.Die(err.Error())
		}
	},
}

func init() {
	compareGoogleBenchCmd.Flags().StringVarP(&metricFlag, "metric", "m", "real_time",
		"metric to compare: real_time|cpu_time|iterations|bytes_per_second|items_per_second|all")
	compareGoogleBenchCmd.Flags().StringVarP(&outFile, "out", "o", "",
		"output CSV file (default: stdout)")

	RootCmd.AddCommand(compareGoogleBenchCmd)
}
