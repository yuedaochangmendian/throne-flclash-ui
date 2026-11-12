// Route profiles and rules, as JSON documents owned by the kernel (ADR 0002, phase 3c).
//
// Phase 3b moved the Kotlin reads onto a JSON document set and left the writer in Kotlin.
// That is one writer too many once the Go dispatcher also needs to answer route actions, so
// this file makes Go the ONLY writer: the kernel reads and writes
// `<basePath>/documents/route_profiles.json` and `route_rules.json`, and Kotlin keeps a
// read-only view of the same files (RouteJsonStore).
//
// `basePath` is the app's private files directory: the host sets it in SetupOptions
// (`CoreRuntime.setup` -> `app.filesDir`), and Setup mkdir's it before anything else runs,
// so this package can rely on it existing without asking the platform.
//
// The row shape is deliberately identical to the Kotlin writer's: a flat object per row
// keyed by Room's own column names. That is what makes the Kotlin side able to keep reading
// after the writer changes hands, and what makes the one-time Room export reusable as the
// initial file.
package mobile

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"sync"
)

const (
	routeProfilesDoc = "route_profiles"
	routeRulesDoc    = "route_rules"
	documentsDirName = "documents"
)

var errRouteNotFound = errors.New("no route profile with that id")

// routeStoreMu serialises every read-modify-write. The dispatcher runs each action on its
// own goroutine, and two concurrent saves racing on one document is exactly the lost-update
// this lock exists to prevent.
var routeStoreMu sync.Mutex

// documentsDir is `<basePath>/documents`. An empty basePath means the host has not called
// Setup yet, which is a programming error rather than a transient state.
func documentsDir() (string, error) {
	if sBasePath == "" {
		return "", errors.New("kernel base path is not set; the host must call setup first")
	}
	return filepath.Join(sBasePath, documentsDirName), nil
}

// row is one document row: Room's column names to JSON values.
type row map[string]any

// document is one file: a versioned envelope around rows.
type document struct {
	Version int    `json:"version"`
	Name    string `json:"name"`
	Rows    []row  `json:"rows"`
}

// readDocument loads one document. A missing file answers an empty document rather than an
// error: that is the state before the host's one-time export runs, and the caller decides
// whether an empty set is acceptable.
func readDocument(name string) ([]row, error) {
	dir, err := documentsDir()
	if err != nil {
		return nil, err
	}
	path := filepath.Join(dir, name+".json")
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var doc document
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("read %s.json: %w", name, err)
	}
	if doc.Version > 1 {
		return nil, fmt.Errorf("%s.json has version %d, newer than this build", name, doc.Version)
	}
	return doc.Rows, nil
}

// writeDocument replaces one document atomically: temp file, flush, rename. A crash mid-write
// leaves the previous file intact, which is the only way a half-written set cannot be read
// back as truth.
func writeDocument(name string, rows []row) error {
	dir, err := documentsDir()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if rows == nil {
		rows = []row{}
	}
	payload, err := json.MarshalIndent(document{Version: 1, Name: name, Rows: rows}, "", "  ")
	if err != nil {
		return err
	}
	path := filepath.Join(dir, name+".json")
	temp, err := os.CreateTemp(dir, name+".json.*.tmp")
	if err != nil {
		return err
	}
	tempName := temp.Name()
	if _, err := temp.Write(payload); err != nil {
		temp.Close()
		os.Remove(tempName)
		return err
	}
	if err := temp.Sync(); err != nil {
		temp.Close()
		os.Remove(tempName)
		return err
	}
	if err := temp.Close(); err != nil {
		os.Remove(tempName)
		return err
	}
	if err := os.Rename(tempName, path); err != nil {
		os.Remove(tempName)
		return err
	}
	return nil
}

// --- column helpers ----------------------------------------------------------
//
// json.Unmarshal gives every number a float64, so a row round-tripped through this file would
// turn an int64 id into something that prints as 7 but compares differently. These read the
// typed value the entity conversions expect.

func rowString(r row, key string) string {
	if value, ok := r[key].(string); ok {
		return value
	}
	return ""
}

func rowInt(r row, key string) int {
	switch value := r[key].(type) {
	case float64:
		return int(value)
	case int:
		return value
	}
	return 0
}

func rowInt64(r row, key string) int64 {
	switch value := r[key].(type) {
	case float64:
		return int64(value)
	case int64:
		return value
	case int:
		return int64(value)
	}
	return 0
}

func rowBool(r row, key string) bool {
	switch value := r[key].(type) {
	case bool:
		return value
	// The Kotlin writer stores 0/1; the export copies Room's values verbatim.
	case float64:
		return value != 0
	case int:
		return value != 0
	}
	return false
}

func rowIntOr(r row, key string, fallback int64) int64 {
	if _, ok := r[key]; !ok {
		return fallback
	}
	return rowInt64(r, key)
}

// sortedProfiles orders by id, the order every caller expects (RouteManager.all does the same).
func sortedProfiles(rows []row) []row {
	out := append([]row(nil), rows...)
	sort.SliceStable(out, func(a, b int) bool {
		return rowInt64(out[a], "id") < rowInt64(out[b], "id")
	})
	return out
}

// --- JSON value helpers ------------------------------------------------------
//
// Action payloads arrive as decoded JSON, where every number is a float64 and an absent key
// is nil. These read the typed value the handlers expect without repeating the switches.

func jsonList(raw string) []any {
	if raw == "" {
		return []any{}
	}
	var out []any
	if json.Unmarshal([]byte(raw), &out) != nil {
		return []any{}
	}
	return out
}

func stringOf(value any) string {
	if text, ok := value.(string); ok {
		return text
	}
	return ""
}

// intOf narrows a JSON number to int, saturating rather than wrapping.
//
// The saturation matters on 32-bit devices (armeabi-v7a, i686), where int is
// 32 bits and a stored int64 exceeds it: a plain conversion would wrap a large
// selector interval into a negative and hand the form a value it never stored.
func intOf(value any) int {
	switch typed := value.(type) {
	case float64:
		return narrowToInt(typed)
	case int:
		return typed
	// The kernel's own writes store int64 (a JSON document it re-encoded keeps
	// no float64), so a reader of its own output needs this branch.
	case int64:
		return int64ToInt(typed)
	}
	return 0
}

// int64ToInt narrows an int64 to int without wrapping: the value is compared to
// the platform int bounds before it is converted, so a stored number past them
// saturates instead of coming back negative.
func int64ToInt(value int64) int {
	if value > math.MaxInt {
		return math.MaxInt
	}
	if value < math.MinInt {
		return math.MinInt
	}
	return int(value)
}

// narrowToInt clamps a float64 to the platform int range, refusing NaN and
// infinities. The comparison is against math.MaxInt/math.MinInt — the int
// bounds themselves, not a constant that only matches on one word size — so a
// value past the range saturates instead of wrapping.
func narrowToInt(value float64) int {
	if value != value || math.IsInf(value, 0) {
		return 0
	}
	if value >= float64(math.MaxInt) {
		return math.MaxInt
	}
	if value <= float64(math.MinInt) {
		return math.MinInt
	}
	return int(value)
}

func int64Of(value any) int64 {
	switch typed := value.(type) {
	case float64:
		return int64(typed)
	case int64:
		return typed
	case int:
		return int64(typed)
	}
	return -1
}

func boolOf(value any) bool {
	switch typed := value.(type) {
	case bool:
		return typed
	case float64:
		return typed != 0
	case int:
		return typed != 0
	}
	return false
}

func rulesOfProfile(rows []row, profileID int64) []row {
	kept := make([]row, 0, 8)
	for _, r := range rows {
		if rowInt64(r, "route_profile_id") == profileID {
			kept = append(kept, r)
		}
	}
	sort.SliceStable(kept, func(a, b int) bool {
		return rowInt(kept[a], "rule_order") < rowInt(kept[b], "rule_order")
	})
	return kept
}
