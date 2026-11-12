// Settings store: the three-layer wire merge and document access (ADR 0002, phase 3e).
//
// settingsWire() reproduces ThroneBoxBridge.settingsWire() exactly:
//   1. overlay layer — documents/ui_settings.json (shell-only keys)
//   2. schema layer  — the generated spec table, reading Room rows via rowStore
//   3. derived layer — fontSize, perAppManaged, queryMode, batteryExempt
//
// Rows stay in Room (33 Kotlin files write them); the JSON documents (ui_settings,
// preferences) are Go-owned. Reads are uncached — every call re-reads rows and docs,
// mirroring SettingsStore's cache-free doctrine.
package mobile

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
)

const (
	uiSettingsDoc  = "ui_settings"
	preferencesDoc = "preferences"
	hostFactsDoc   = "host_facts"
	applyPending   = "apply_pending"
)

// settingsStoreMu serialises read-modify-write on the settings documents.
var settingsStoreMu = sync.Mutex

// --- document helpers ---------------------------------------------------------

func readJSONDoc(name string) map[string]any {
	dir, err := documentsDir()
	if err != nil {
		return map[string]any{}
	}
	data, err := os.ReadFile(filepath.Join(dir, name+".json"))
	if err != nil {
		return map[string]any{}
	}
	var doc struct {
		Version int            `json:"version"`
		Name    string         `json:"name"`
		Rows    map[string]any `json:"rows"`
	}
	if json.Unmarshal(data, &doc) != nil || doc.Rows == nil {
		return map[string]any{}
	}
	return doc.Rows
}

func writeJSONDoc(name string, rows map[string]any) error {
	dir, err := documentsDir()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if rows == nil {
		rows = map[string]any{}
	}
	payload, err := json.MarshalIndent(map[string]any{
		"version": 1, "name": name, "rows": rows,
	}, "", "  ")
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

// --- host facts ---------------------------------------------------------------

func readHostFacts() map[string]any {
	return readJSONDoc(hostFactsDoc)
}

// --- settingsWire() -----------------------------------------------------------

// settingsWire produces the flat camelCase map that Dart reads. The three layers
// are merged in order: overlay, schema (wins), derived (settles last).
func settingsWire(rows map[string]string) map[string]any {
	settingsStoreMu.Lock()
	defer settingsStoreMu.Unlock()

	result := map[string]any{}

	// Layer 1: overlay (shell-only keys from ui_settings.json).
	overlay := readJSONDoc(uiSettingsDoc)
	for k, v := range overlay {
		result[k] = v
	}

	// Layer 2: schema (wins over overlay).
	for _, spec := range settingSpecs {
		result[spec.bridgeKey] = decodeRow(spec, rows)
	}

	// Layer 3: derived (settles last).
	if fs, ok := result["fontSize"]; ok {
		switch v := fs.(type) {
		case float64:
			result["fontSize"] = int(v)
		case string:
			n := 0
			for _, c := range v {
				if c >= '0' && c <= '9' {
					n = n*10 + int(c-'0')
				} else {
					n = 0
					break
				}
			}
			result["fontSize"] = n
		}
	} else {
		result["fontSize"] = 0
	}
	result["perAppManaged"] = false
	result["perAppManagedList"] = []string{}
	result["queryMode"] = "ROOT"

	// batteryExempt from host facts.
	facts := readHostFacts()
	if v, ok := facts["batteryExempt"].(bool); ok {
		result["batteryExempt"] = v
	} else {
		result["batteryExempt"] = false
	}

	return result
}

// --- settingsSet --------------------------------------------------------------

// settingsSet writes one key and returns the full updated wire map.
// Returns the apply level (0=None, 1=Reload, 2=AppRestart) and whether the key is known.
func settingsSet(store rowStore, key string, value any) (map[string]any, int, bool) {
	settingsStoreMu.Lock()
	defer settingsStoreMu.Unlock()

	spec := findSpec(key)
	if spec == nil {
		return nil, 0, false
	}

	rows := store.All()
	rowMap := make(map[string]string, len(rows))
	for _, r := range rows {
		rowMap[r.Key] = r.Value
	}

	writes := encodeWire(*spec, value, rowMap)
	for k, v := range writes {
		store.Put(k, v)
	}

	// Rebuild the row map after writes.
	rows = store.All()
	rowMap = make(map[string]string, len(rows))
	for _, r := range rows {
		rowMap[r.Key] = r.Value
	}

	return settingsWire(rowMap), spec.apply, true
}

// --- settingsPatch ------------------------------------------------------------

// settingsPatch writes multiple keys and returns the full updated wire map.
// Returns the heaviest apply level among the written keys.
func settingsPatch(store rowStore, values map[string]any) (map[string]any, int) {
	settingsStoreMu.Lock()
	defer settingsStoreMu.Unlock()

	maxApply := 0
	rows := store.All()
	rowMap := make(map[string]string, len(rows))
	for _, r := range rows {
		rowMap[r.Key] = r.Value
	}

	for key, value := range values {
		spec := findSpec(key)
		if spec == nil {
			continue
		}
		writes := encodeWire(*spec, value, rowMap)
		for k, v := range writes {
			store.Put(k, v)
			rowMap[k] = v
		}
		if spec.apply > maxApply {
			maxApply = spec.apply
		}
	}

	// Rebuild after writes.
	rows = store.All()
	rowMap = make(map[string]string, len(rows))
	for _, r := range rows {
		rowMap[r.Key] = r.Value
	}

	return settingsWire(rowMap), maxApply
}

// --- settingsReset ------------------------------------------------------------

// settingsReset deletes rows for the given keys and returns the full updated wire map.
// Empty key list means reset all. Returns the heaviest apply level among changed keys.
func settingsReset(store rowStore, keys []string) (map[string]any, int) {
	settingsStoreMu.Lock()
	defer settingsStoreMu.Unlock()

	maxApply := 0
	if len(keys) == 0 {
		// Reset all.
		for _, spec := range settingSpecs {
			before := decodeRow(spec, rowMapOf(store))
			deleteSpecRows(store, spec)
			after := decodeRow(spec, rowMapOf(store))
			if !wireEqual(before, after) && spec.apply > maxApply {
				maxApply = spec.apply
			}
		}
	} else {
		for _, key := range keys {
			spec := findSpec(key)
			if spec == nil {
				continue
			}
			before := decodeRow(spec, rowMapOf(store))
			deleteSpecRows(store, spec)
			after := decodeRow(spec, rowMapOf(store))
			if !wireEqual(before, after) && spec.apply > maxApply {
				maxApply = spec.apply
			}
		}
	}

	return settingsWire(rowMapOf(store)), maxApply
}

// --- preferencesSet -----------------------------------------------------------

// preferencesSet merges values into the preferences document and returns the merged map.
func preferencesSet(values map[string]any) map[string]any {
	settingsStoreMu.Lock()
	defer settingsStoreMu.Unlock()

	merged := readJSONDoc(preferencesDoc)
	for k, v := range values {
		if v == nil {
			delete(merged, k)
		} else {
			merged[k] = v
		}
	}
	writeJSONDoc(preferencesDoc, merged)
	return merged
}

// --- helpers ------------------------------------------------------------------

func findSpec(key string) *settingSpec {
	for i := range settingSpecs {
		if settingSpecs[i].bridgeKey == key {
			return &settingSpecs[i]
		}
	}
	return nil
}

func rowMapOf(store rowStore) map[string]string {
	rows := store.All()
	m := make(map[string]string, len(rows))
	for _, r := range rows {
		m[r.Key] = r.Value
	}
	return m
}

func deleteSpecRows(store rowStore, spec settingSpec) {
	for _, key := range spec.rowKeys {
		store.Delete(key)
	}
	// Also try camelToSnake and the raw bridge key (matching Settings.reset).
	store.Delete(camelToSnake(spec.bridgeKey))
	store.Delete(spec.bridgeKey)
}

func wireEqual(a, b any) bool {
	aj, _ := json.Marshal(a)
	bj, _ := json.Marshal(b)
	return string(aj) == string(bj)
}

// camelToSnake converts camelCase to snake_case (matching SettingsSchema.kt).
func camelToSnake(name string) string {
	out := make([]byte, 0, len(name)+4)
	for _, c := range name {
		if c >= 'A' && c <= 'Z' {
			out = append(out, '_')
			out = append(out, c+32)
		} else {
			out = append(out, c)
		}
	}
	return string(out)
}
