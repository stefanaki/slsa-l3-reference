package catalog

import (
	"bytes"
	"encoding/json"
	"reflect"
	"testing"
)

func TestWriteTable(t *testing.T) {
	var buf bytes.Buffer
	if err := WriteTable(&buf, Items()); err != nil {
		t.Fatal(err)
	}
	want := "SKU      NAME     QUANTITY\n" +
		"WID-001  Widget   120\n" +
		"GAD-002  Gadget   35\n" +
		"STA-003  Stapler  8\n"
	if got := buf.String(); got != want {
		t.Errorf("table mismatch\ngot:\n%s\nwant:\n%s", got, want)
	}
}

func TestWriteJSONRoundTrips(t *testing.T) {
	var buf bytes.Buffer
	if err := WriteJSON(&buf, Items()); err != nil {
		t.Fatal(err)
	}
	var got []Item
	if err := json.Unmarshal(buf.Bytes(), &got); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if !reflect.DeepEqual(got, Items()) {
		t.Errorf("got %+v, want %+v", got, Items())
	}
}
