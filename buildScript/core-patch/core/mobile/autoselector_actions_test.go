// The auto-selector merge rules (ADR 0002, phase 3d).
//
// The save is a merge, not a replacement: the form sends only what the user
// touched, so an absent key must keep its stored value, and the fields the
// runtime maintains must survive. A replacement would silently reset a
// selector's pool and history on every rename.
package mobile

import (
	"encoding/json"
	"reflect"
	"testing"
)

// storedSelector is a document shaped like AutoSelector.exportToJson, including
// the runtime-owned fields the merge must never name.
const storedSelector = `{
	"name": "Auto Selector",
	"type": "autoselector",
	"gid": 1,
	"gids": [1],
	"name_filter": "old",
	"country_filter": "",
	"exclude_unavailable": false,
	"pool_cap": 8,
	"build_limit": 16,
	"result_validity_mins": 30,
	"test_url": "https://a.example",
	"connectivity_url": "",
	"interval_sec": 300,
	"bench_interval_sec": 600,
	"watch_interval_sec": 60,
	"active_size": 3,
	"sampling": 5,
	"tolerance_ms": 50,
	"max_rtt_ms": 2000,
	"expected": 2,
	"dial_retries": 1,
	"interrupt_on_switch": true,
	"balance": false,
	"balance_mode": "",
	"balance_interval_sec": 120,
	"pool": [11, 12],
	"pool_ranked_at": 1770000000,
	"pinned_id": 12,
	"last_built": [11],
	"last_built_at": 1770000100,
	"history": [{"at": 1770000100, "winner": 11}]
}`

func decodeStored(t *testing.T) map[string]any {
	t.Helper()
	selector := map[string]any{}
	if err := json.Unmarshal([]byte(storedSelector), &selector); err != nil {
		t.Fatalf("the fixture must parse: %v", err)
	}
	return selector
}

func TestMergeKeepsAbsentKeys(t *testing.T) {
	selector := decodeStored(t)
	mergeAutoSelector(selector, map[string]any{})

	if got := stringOf(selector["name"]); got != "Auto Selector" {
		t.Fatalf("an empty request must not touch the name, got %q", got)
	}
	if got := intOf(selector["pool_cap"]); got != 8 {
		t.Fatalf("an empty request must not touch pool_cap, got %d", got)
	}
}

func TestMergeWritesOnlyWhatWasSent(t *testing.T) {
	selector := decodeStored(t)
	mergeAutoSelector(selector, map[string]any{"name": "  renamed  "})

	if got := stringOf(selector["name"]); got != "renamed" {
		t.Fatalf("the name must be trimmed, got %q", got)
	}
	if got := stringOf(selector["name_filter"]); got != "old" {
		t.Fatalf("an untouched filter must survive, got %q", got)
	}
}

func TestMergePreservesRuntimeFields(t *testing.T) {
	selector := decodeStored(t)
	mergeAutoSelector(selector, map[string]any{
		"name":      "renamed",
		"poolCap":   float64(4),
		"gids":      []any{float64(2), float64(3)},
		"intervalSec": float64(900),
	})

	// These five are written by the selector runtime, not the editor. A
	// replacement would drop them and the ranking would restart from nothing.
	for _, key := range []string{"pool", "pool_ranked_at", "last_built", "last_built_at", "history"} {
		if _, present := selector[key]; !present {
			t.Fatalf("the merge dropped the runtime field %q", key)
		}
	}
	if got := selector["pool_ranked_at"]; got != float64(1770000000) {
		t.Fatalf("pool_ranked_at changed: %v", got)
	}
}

func TestMergeClampsBelowMinimum(t *testing.T) {
	selector := decodeStored(t)
	mergeAutoSelector(selector, map[string]any{
		// Zero is meaningful for a cap but fatal for an interval or a size.
		"poolCap":            float64(0),
		"buildLimit":         float64(0),
		"resultValidityMins": float64(0),
		"intervalSec":        float64(0),
		"activeSize":         float64(0),
		"sampling":           float64(0),
		"expected":           float64(0),
		"balanceIntervalSec": float64(0),
		"dialRetries":        float64(0),
		"toleranceMs":        float64(0),
		"maxRTTms":           float64(0),
	})

	if got := intOf(selector["pool_cap"]); got != 0 {
		t.Fatalf("pool_cap allows zero, got %d", got)
	}
	if got := intOf(selector["build_limit"]); got != 0 {
		t.Fatalf("build_limit allows zero, got %d", got)
	}
	if got := intOf(selector["result_validity_mins"]); got != 0 {
		t.Fatalf("result_validity_mins allows zero, got %d", got)
	}
	if got := intOf(selector["dial_retries"]); got != 0 {
		t.Fatalf("dial_retries allows zero, got %d", got)
	}
	if got := intOf(selector["tolerance_ms"]); got != 0 {
		t.Fatalf("tolerance_ms allows zero, got %d", got)
	}
	if got := intOf(selector["max_rtt_ms"]); got != 0 {
		t.Fatalf("max_rtt_ms allows zero, got %d", got)
	}
	for _, key := range []string{
		"interval_sec", "active_size", "sampling", "expected", "balance_interval_sec",
	} {
		if got := intOf(selector[key]); got != 1 {
			t.Fatalf("%s must clamp to 1, got %d", key, got)
		}
	}
}

func TestMergeReadsNumericStrings(t *testing.T) {
	// The form's text inputs send "300", not 300; the Kotlin side accepts both.
	selector := decodeStored(t)
	mergeAutoSelector(selector, map[string]any{"intervalSec": " 900 "})

	if got := intOf(selector["interval_sec"]); got != 900 {
		t.Fatalf("a numeric string must be read, got %d", got)
	}
}

func TestMergeDerivesGIDFromGids(t *testing.T) {
	selector := decodeStored(t)
	mergeAutoSelector(selector, map[string]any{"gids": []any{float64(7), float64(9)}})

	if got := intOf(selector["gid"]); got != 7 {
		t.Fatalf("gid must mirror the first ticked group, got %d", got)
	}
	gids, ok := selector["gids"].([]int64)
	if !ok {
		t.Fatalf("gids must be stored as ints, got %T", selector["gids"])
	}
	if !reflect.DeepEqual(gids, []int64{7, 9}) {
		t.Fatalf("gids must keep their order, got %v", gids)
	}
}

func TestMergeEmptyGidsParksTheSelector(t *testing.T) {
	selector := decodeStored(t)
	mergeAutoSelector(selector, map[string]any{"gids": []any{}})

	if got := intOf(selector["gid"]); got != -1 {
		t.Fatalf("an empty pick must write -1, got %d", got)
	}
}

func TestMergeIgnoresWrongTypes(t *testing.T) {
	selector := decodeStored(t)
	// A flag sent as a string must not overwrite the stored bool, and a number
	// sent as a bool must not become a count.
	mergeAutoSelector(selector, map[string]any{
		"balance":   "true",
		"poolCap":   true,
		"name":      float64(5),
	})

	if got := boolOf(selector["balance"]); got != false {
		t.Fatalf("a non-bool must not set the flag, got %v", got)
	}
	if got := intOf(selector["pool_cap"]); got != 8 {
		t.Fatalf("a non-number must not set the cap, got %d", got)
	}
	if got := stringOf(selector["name"]); got != "Auto Selector" {
		t.Fatalf("a non-string must not set the name, got %q", got)
	}
}

func TestAutoSelectorNumberRejectsNonNumericText(t *testing.T) {
	if _, ok := autoSelectorNumber("1.5.2"); ok {
		t.Fatalf("a version string is not a number")
	}
	if _, ok := autoSelectorNumber(""); ok {
		t.Fatalf("an empty string is not a number")
	}
	if got, ok := autoSelectorNumber("42"); !ok || got != 42 {
		t.Fatalf("42 must parse, got %d ok=%v", got, ok)
	}
}
