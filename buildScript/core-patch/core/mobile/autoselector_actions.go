// Auto-selector actions on the Room-backed profile row (ADR 0002, phase 3d).
//
// `autoSelectorSave` is the one write in the profiles surface that needs no
// Kotlin outbound model: the selector lives in `profiles.outbound_json` as a
// flat JSON object, and saving edits a handful of scalar keys on it. The rest of
// the surface stays on the channel because it is bound to OutboundFactory,
// ProfileJson, reflection over the Mux/Tls fields, or Android resources.
//
// The edit is read-modify-write, deliberately: `exportToJson` also emits the
// fields the *runtime* maintains (`pool`, `pool_ranked_at`, `last_built`,
// `last_built_at`, `history`). Rebuilding the document from the form's values
// would drop them, and a selector would lose its ranked pool on every save.
package mobile

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// autoSelectorSaveMethod is the wire name. `autoSelectorInfo` is not here: the
// save answers the refreshed seed itself, and the editor's read path goes
// through the same builder, so a separate action would be a second shape to
// keep in step with Kotlin's.
const autoSelectorSaveMethod Method = "autoSelectorSave"

func init() {
	register(autoSelectorSaveMethod, handleAutoSelectorSave)
}

// autoSelectorType is the `profiles.type` value selector rows carry.
const autoSelectorType = "autoselector"

// autoSelectorKey is one request key and the stored key it writes.
type autoSelectorKey struct {
	request string
	stored  string
	minimum int64
}

// autoSelectorIntKeys mirrors BboxProfiles.autoSelectorSave line for line,
// including the clamps: a zero in an interval, a size or an expectation would
// stop the selector instead of configuring it.
var autoSelectorIntKeys = []autoSelectorKey{
	{"poolCap", "pool_cap", 0},
	{"buildLimit", "build_limit", 0},
	{"resultValidityMins", "result_validity_mins", 0},
	{"toleranceMs", "tolerance_ms", 0},
	{"maxRTTms", "max_rtt_ms", 0},
	{"dialRetries", "dial_retries", 0},
	{"intervalSec", "interval_sec", 1},
	{"benchIntervalSec", "bench_interval_sec", 1},
	{"watchIntervalSec", "watch_interval_sec", 1},
	{"activeSize", "active_size", 1},
	{"sampling", "sampling", 1},
	{"expected", "expected", 1},
	{"balanceIntervalSec", "balance_interval_sec", 1},
}

// autoSelectorStringKeys are trimmed, and only when the caller sent a string.
var autoSelectorStringKeys = []autoSelectorKey{
	{"name", "name", 0},
	{"nameFilter", "name_filter", 0},
	{"countryFilter", "country_filter", 0},
	{"testURL", "test_url", 0},
	{"connectivityURL", "connectivity_url", 0},
	{"balanceMode", "balance_mode", 0},
}

// autoSelectorBoolKeys are the plain flags.
var autoSelectorBoolKeys = []autoSelectorKey{
	{"excludeUnavailable", "exclude_unavailable", 0},
	{"interruptOnSwitch", "interrupt_on_switch", 0},
	{"balance", "balance", 0},
}

// handleAutoSelectorSave merges the editor's values into one selector row.
//
// Absent keys keep their stored value — the form sends only what the user
// touched — so this is a merge, not a replacement. The answer is the refreshed
// editor seed, which is what the Kotlin implementation returns.
func handleAutoSelectorSave(data json.RawMessage) (any, error) {
	var payload struct {
		ID    int64          `json:"id"`
		Value map[string]any `json:"value"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}
	if payload.ID <= 0 {
		return nil, fmt.Errorf("no auto selector with id %d", payload.ID)
	}

	profiles, err := readRoomProfiles()
	if err != nil {
		return nil, err
	}
	profile := findProfileByID(profiles, payload.ID)
	if profile == nil || rowString(profile, "type") != autoSelectorType {
		return nil, fmt.Errorf("no auto selector with id %d", payload.ID)
	}

	raw := rowString(profile, "outbound_json")
	if raw == "" {
		return nil, fmt.Errorf("the auto selector has no stored document")
	}
	selector := map[string]any{}
	if err := json.Unmarshal([]byte(raw), &selector); err != nil {
		return nil, fmt.Errorf("parse auto selector: %w", err)
	}

	mergeAutoSelector(selector, payload.Value)

	encoded, err := json.Marshal(selector)
	if err != nil {
		return nil, fmt.Errorf("encode auto selector: %w", err)
	}
	// The three columns AutoSelectorProfiles.save writes. Traffic and the test
	// result columns belong to the test runners and stay untouched.
	name := stringOf(selector["name"])
	if err := roomExecParams(
		"UPDATE `profiles` SET `type`=?, `name`=?, `outbound_json`=? WHERE `id`=?;",
		autoSelectorType, name, string(encoded), fmt.Sprint(payload.ID),
	); err != nil {
		return nil, err
	}

	return buildAutoSelectorInfo(selector, payload.ID), nil
}

// mergeAutoSelector applies the request onto the stored document in place.
//
// Only keys the caller sent are touched, and the runtime's own fields are never
// named here, so they survive the merge.
func mergeAutoSelector(selector map[string]any, values map[string]any) {
	for _, key := range autoSelectorStringKeys {
		if text, ok := values[key.request].(string); ok {
			selector[key.stored] = strings.TrimSpace(text)
		}
	}
	for _, key := range autoSelectorBoolKeys {
		if flag, ok := values[key.request].(bool); ok {
			selector[key.stored] = flag
		}
	}
	for _, key := range autoSelectorIntKeys {
		number, ok := autoSelectorNumber(values[key.request])
		if !ok {
			continue
		}
		if number < key.minimum {
			number = key.minimum
		}
		selector[key.stored] = number
	}
	// `gid` mirrors the first ticked group, the way exportToJson derives it; an
	// empty pick writes -1 so the selector names no group rather than keeping a
	// stale one.
	if list, ok := values["gids"].([]any); ok {
		gids := make([]int64, 0, len(list))
		for _, item := range list {
			if id, ok := autoSelectorNumber(item); ok {
				gids = append(gids, id)
			}
		}
		selector["gids"] = gids
		if len(gids) > 0 {
			selector["gid"] = gids[0]
		} else {
			selector["gid"] = int64(-1)
		}
	}
}

// autoSelectorNumber reads an int from a JSON number or a numeric string: the
// form's text fields send both, and the Kotlin side accepts both too
// (`(values[key] as? Number)?.toInt() ?: (values[key] as? String)?.toIntOrNull()`).
//
// The string branch is strconv, not fmt: fmt.Sscan stops at the first character
// it cannot use and reports success, so "1.5.2" would read as 1. toIntOrNull
// rejects the whole string, and so must this.
func autoSelectorNumber(value any) (int64, bool) {
	switch typed := value.(type) {
	case float64:
		return int64(typed), true
	case int64:
		return typed, true
	case int:
		return int64(typed), true
	case string:
		parsed, err := strconv.ParseInt(strings.TrimSpace(typed), 10, 64)
		if err != nil {
			return 0, false
		}
		return parsed, true
	}
	return 0, false
}

// buildAutoSelectorInfo answers the editor seed from a stored document.
//
// Every field the Kotlin editor form reads is here, with the same keys, so the
// screen does not branch on which side answered. `groups` is the picker's menu:
// every group that exists, read from Room.
func buildAutoSelectorInfo(selector map[string]any, id int64) map[string]any {
	gids := make([]any, 0, 4)
	if list, ok := selector["gids"].([]any); ok {
		gids = list
	}
	groups := make([]any, 0, 4)
	if rows, err := readRoomGroups(); err == nil {
		for _, group := range rows {
			groups = append(groups, map[string]any{
				"id":   group.id,
				"name": group.name,
			})
		}
	}

	info := map[string]any{
		"id":                 id,
		"name":               stringOf(selector["name"]),
		"nameFilter":         stringOf(selector["name_filter"]),
		"countryFilter":      stringOf(selector["country_filter"]),
		"excludeUnavailable": boolOf(selector["exclude_unavailable"]),
		"poolCap":            intOf(selector["pool_cap"]),
		"buildLimit":         intOf(selector["build_limit"]),
		"resultValidityMins": intOf(selector["result_validity_mins"]),
		"testURL":            stringOf(selector["test_url"]),
		"connectivityURL":    stringOf(selector["connectivity_url"]),
		"intervalSec":        intOf(selector["interval_sec"]),
		"benchIntervalSec":   intOf(selector["bench_interval_sec"]),
		"watchIntervalSec":   intOf(selector["watch_interval_sec"]),
		"activeSize":         intOf(selector["active_size"]),
		"sampling":           intOf(selector["sampling"]),
		"toleranceMs":        intOf(selector["tolerance_ms"]),
		"maxRTTms":           intOf(selector["max_rtt_ms"]),
		"expected":           intOf(selector["expected"]),
		"dialRetries":        intOf(selector["dial_retries"]),
		"interruptOnSwitch":  boolOf(selector["interrupt_on_switch"]),
		"balance":            boolOf(selector["balance"]),
		"balanceMode":        stringOf(selector["balance_mode"]),
		"balanceIntervalSec": intOf(selector["balance_interval_sec"]),
		"gids":               gids,
		"pinnedId":           intOf(selector["pinned_id"]),
		"groups":             groups,
	}
	return info
}
