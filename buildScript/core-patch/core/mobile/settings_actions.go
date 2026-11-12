// Settings mutation actions on the action bus (ADR 0002, phase 3e, PR-3).
//
// These handlers read and write the Room settings table (via rowStore) and the
// Go-owned UI documents, returning the full wire map after every mutation — the
// same contract as the channel arms. Complex side effects (service reload, DNS
// history) are announced as events; Kotlin actuators execute them.
package mobile

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
)

// Errors returned to Dart.
var (
	errNoRowStore  = errors.New("settings row store is not initialized")
	errUnknownKey  = errors.New("unknown settings key")
)

// The method names the Dart ActionMethod enum uses.
const (
	settingsGetMethod    Method = "settingsGet"
	settingsSetMethod    Method = "settingsSet"
	settingsPatchMethod  Method = "settingsPatch"
	settingsResetMethod  Method = "settingsReset"
	preferencesSetMethod Method = "preferencesSet"
)

func init() {
	register(settingsGetMethod, handleSettingsGet)
	register(settingsSetMethod, handleSettingsSet)
	register(settingsPatchMethod, handleSettingsPatch)
	register(settingsResetMethod, handleSettingsReset)
	register(preferencesSetMethod, handlePreferencesSet)
}

// --- settings.get -------------------------------------------------------------

func handleSettingsGet(_ json.RawMessage) (any, error) {
	store := globalRowStore()
	if store == nil {
		return nil, errNoRowStore
	}
	return settingsWire(rowMapOf(store)), nil
}

// --- settings.set -------------------------------------------------------------

func handleSettingsSet(data json.RawMessage) (any, error) {
	var payload struct {
		Key     string `json:"key"`
		Value   any    `json:"value"`
		Restart bool   `json:"restart"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}

	store := globalRowStore()
	if store == nil {
		return nil, errNoRowStore
	}

	wire, apply, ok := settingsSet(store, payload.Key, payload.Value)
	if !ok {
		return nil, errUnknownKey
	}

	// Side effects.
	if apply >= 2 {
		markApplyPending()
	}
	if payload.Restart && apply >= 1 {
		sendEvent("serviceReload", true)
	}
	sendEvent("settings", wire)
	return wire, nil
}

// --- settings.patch -----------------------------------------------------------

func handleSettingsPatch(data json.RawMessage) (any, error) {
	var payload struct {
		Value map[string]any `json:"value"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}

	store := globalRowStore()
	if store == nil {
		return nil, errNoRowStore
	}

	wire, apply := settingsPatch(store, payload.Value)
	if apply >= 2 {
		markApplyPending()
	}
	sendEvent("settings", wire)
	return wire, nil
}

// --- settings.reset -----------------------------------------------------------

func handleSettingsReset(data json.RawMessage) (any, error) {
	var payload struct {
		Keys []string `json:"keys"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}

	store := globalRowStore()
	if store == nil {
		return nil, errNoRowStore
	}

	wire, apply := settingsReset(store, payload.Keys)
	if apply >= 2 {
		markApplyPending()
		sendEvent("applyRequired", "Restart")
	}
	if apply == 1 {
		sendEvent("serviceReload", true)
	}
	sendEvent("settings", wire)
	return wire, nil
}

// --- preferences.set ----------------------------------------------------------

func handlePreferencesSet(data json.RawMessage) (any, error) {
	var payload struct {
		Value map[string]any `json:"value"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}
	return preferencesSet(payload.Value), nil
}

// --- helpers ------------------------------------------------------------------

// markApplyPending creates the apply_pending marker file so `ready` can show
// the restart badge. Deleted on process restart (Setup).
func markApplyPending() {
	dir, err := documentsDir()
	if err != nil {
		return
	}
	writeFile := func(path string) {
		f, err := os.Create(path)
		if err == nil {
			f.Close()
		}
	}
	writeFile(filepath.Join(dir, applyPending))
}
