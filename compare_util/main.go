package main

import (
	"github.com/anythinggwp/archBench/compare_util/cmd"
	"github.com/anythinggwp/archBench/compare_util/internal"
)

func main() {
	if err := cmd.RootCmd.Execute(); err != nil {
		internal.Die(err.Error())
	}
}
