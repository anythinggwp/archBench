package cmd

import "github.com/spf13/cobra"

var RootCmd = &cobra.Command{
	Use:   "merge-bench-arch",
	Short: "Merge and compare google benchmark results across 3 architectures",
}
