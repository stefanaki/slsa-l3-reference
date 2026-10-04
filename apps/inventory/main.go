// Command inventory lists sample stock items.
package main

import (
	"fmt"
	"io"
	"os"

	"github.com/spf13/cobra"

	"github.com/stefanaki/slsa-l3-reference/apps/inventory/internal/catalog"
)

// version is set at build time with -ldflags "-X main.version=<version>".
var version = "dev"

func main() {
	if err := newRootCmd(os.Stdout).Execute(); err != nil {
		os.Exit(1)
	}
}

func newRootCmd(out io.Writer) *cobra.Command {
	root := &cobra.Command{
		Use:          "inventory",
		Short:        "List sample inventory items",
		SilenceUsage: true,
	}
	root.SetOut(out)
	root.AddCommand(newListCmd(), newVersionCmd())
	return root
}

func newListCmd() *cobra.Command {
	var output string
	cmd := &cobra.Command{
		Use:   "list",
		Short: "Print the inventory",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			switch output {
			case "table":
				return catalog.WriteTable(cmd.OutOrStdout(), catalog.Items())
			case "json":
				return catalog.WriteJSON(cmd.OutOrStdout(), catalog.Items())
			default:
				return fmt.Errorf("unknown output %q (want table or json)", output)
			}
		},
	}
	cmd.Flags().StringVarP(&output, "output", "o", "table", "output format: table or json")
	return cmd
}

func newVersionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print the version",
		Args:  cobra.NoArgs,
		Run: func(cmd *cobra.Command, _ []string) {
			fmt.Fprintln(cmd.OutOrStdout(), version)
		},
	}
}
