// Package catalog holds the sample inventory and renders it as a table or JSON.
package catalog

import (
	"encoding/json"
	"fmt"
	"io"
	"text/tabwriter"
)

// Item is one stock entry.
type Item struct {
	SKU      string `json:"sku"`
	Name     string `json:"name"`
	Quantity int    `json:"quantity"`
}

// Items returns the sample inventory.
func Items() []Item {
	return []Item{
		{SKU: "WID-001", Name: "Widget", Quantity: 120},
		{SKU: "GAD-002", Name: "Gadget", Quantity: 35},
		{SKU: "STA-003", Name: "Stapler", Quantity: 8},
	}
}

// WriteTable writes items as an aligned text table.
func WriteTable(w io.Writer, items []Item) error {
	tw := tabwriter.NewWriter(w, 0, 0, 2, ' ', 0)
	fmt.Fprintln(tw, "SKU\tNAME\tQUANTITY")
	for _, it := range items {
		fmt.Fprintf(tw, "%s\t%s\t%d\n", it.SKU, it.Name, it.Quantity)
	}
	return tw.Flush()
}

// WriteJSON writes items as an indented JSON array.
func WriteJSON(w io.Writer, items []Item) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(items)
}
