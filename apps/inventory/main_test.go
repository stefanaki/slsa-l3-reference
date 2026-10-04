package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func run(t *testing.T, args ...string) (string, error) {
	t.Helper()
	var out bytes.Buffer
	cmd := newRootCmd(&out)
	cmd.SetErr(&out)
	cmd.SetArgs(args)
	err := cmd.Execute()
	return out.String(), err
}

func TestVersionPrintsInjectedVersion(t *testing.T) {
	old := version
	t.Cleanup(func() { version = old })
	version = "1.2.3"

	got, err := run(t, "version")
	if err != nil {
		t.Fatal(err)
	}
	if got != "1.2.3\n" {
		t.Errorf("got %q, want %q", got, "1.2.3\n")
	}
}

func TestListDefaultsToTable(t *testing.T) {
	got, err := run(t, "list")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(got, "SKU") || !strings.Contains(got, "Widget") {
		t.Errorf("unexpected table output:\n%s", got)
	}
}

func TestListJSON(t *testing.T) {
	got, err := run(t, "list", "-o", "json")
	if err != nil {
		t.Fatal(err)
	}
	var items []map[string]any
	if err := json.Unmarshal([]byte(got), &items); err != nil {
		t.Fatalf("invalid JSON: %v\n%s", err, got)
	}
	if len(items) != 3 {
		t.Errorf("got %d items, want 3", len(items))
	}
}

func TestListRejectsUnknownOutput(t *testing.T) {
	if _, err := run(t, "list", "-o", "yaml"); err == nil {
		t.Error("expected an error for -o yaml")
	}
}
