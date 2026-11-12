// Hand-written codec archetypes for the settings schema (ADR 0002, phase 3e).
//
// Each codec translates between the wire value (what Dart sends/receives) and the Room row
// value (what the settings table stores). The generated schema references these by ID.
// The encodings must match SettingsSchema.kt exactly.
//
// The settings domain is channel-authoritative again: Room is the only writer, so
// these are pure functions kept as a contract (and a base for a future migration),
// exercised by settings_codec_test.go. No runtime handler calls them today.
package mobile

import (
	"encoding/json"
	"strconv"
	"strings"
)

// --- codec interface ----------------------------------------------------------

// decodeRow reads one or more room rows and produces the wire value for a bridge key.
// rows is the full row set (needed by codecs that read sibling rows like signedPair).
func decodeRow(spec settingSpec, rows map[string]string) any {
	switch spec.codec {
	case codecDirect:
		return decodeDirect(spec, rows)
	case codecSignedPair:
		return decodeSignedPair(spec, rows)
	case codecSignedMinutes:
		return decodeSignedMinutes(spec, rows)
	case codecInvertedBool:
		return decodeInvertedBool(spec, rows)
	case codecAddressPair:
		return decodeAddressPair(spec, rows)
	case codecMappedInt:
		return decodeMappedInt(spec, rows)
	case codecNewlineList:
		return decodeNewlineList(spec, rows)
	case codecLongAsBool:
		return decodeLongAsBool(spec, rows)
	case codecListDefault:
		return decodeListDefault(spec, rows)
	case codecConstant:
		return decodeConstant(spec)
	case codecHostFact:
		return decodeHostFact(spec, rows)
	}
	return nil
}

// encodeWire takes the wire value and returns the room rows to write.
// rows is the current row set (needed by codecs that preserve sign/state).
func encodeWire(spec settingSpec, value any, rows map[string]string) map[string]string {
	switch spec.codec {
	case codecDirect:
		return encodeDirect(spec, value)
	case codecSignedPair:
		return encodeSignedPair(spec, value, rows)
	case codecSignedMinutes:
		return encodeSignedMinutes(spec, value, rows)
	case codecInvertedBool:
		return encodeInvertedBool(spec, value)
	case codecAddressPair:
		return encodeAddressPair(spec, value)
	case codecMappedInt:
		return encodeMappedInt(spec, value)
	case codecNewlineList:
		return encodeNewlineList(spec, value)
	case codecLongAsBool:
		return encodeLongAsBool(spec, value)
	case codecListDefault:
		return encodeListDefault(spec, value)
	case codecConstant:
		return nil // constants are never stored
	case codecHostFact:
		return nil // host facts are published by Kotlin
	}
	return nil
}

// --- direct -------------------------------------------------------------------

func decodeDirect(spec settingSpec, rows map[string]string) any {
	raw, ok := rows[spec.rowKeys[0]]
	if !ok {
		return defaultValue(spec)
	}
	switch spec.kind {
	case kindBool:
		return raw == "true"
	case kindInt:
		n, _ := strconv.Atoi(raw)
		return n
	case kindList:
		var list []string
		if raw != "" {
			json.Unmarshal([]byte(raw), &list)
		}
		if list == nil {
			list = []string{}
		}
		return list
	default:
		return raw
	}
}

func encodeDirect(spec settingSpec, value any) map[string]string {
	key := spec.rowKeys[0]
	switch spec.kind {
	case kindBool:
		if b, ok := value.(bool); ok && b {
			return map[string]string{key: "true"}
		}
		return map[string]string{key: "false"}
	case kindInt:
		switch v := value.(type) {
		case float64:
			return map[string]string{key: strconv.Itoa(int(v))}
		case int:
			return map[string]string{key: strconv.Itoa(v)}
		case string:
			if n, err := strconv.Atoi(v); err == nil {
				return map[string]string{key: strconv.Itoa(n)}
			}
		}
		return map[string]string{key: "0"}
	case kindList:
		list, _ := value.([]string)
		if list == nil {
			list = []string{}
		}
		encoded, _ := json.Marshal(list)
		return map[string]string{key: string(encoded)}
	default:
		s, _ := value.(string)
		return map[string]string{key: s}
	}
}

// --- signedPair: two bridge keys share one signed int row ----------------------
// Flag = row > 0; port = |row| (default when row is 0).

func decodeSignedPair(spec settingSpec, rows map[string]string) any {
	raw := rows[spec.rowKeys[0]]
	n, _ := strconv.Atoi(raw)
	if spec.kind == kindBool {
		return n > 0
	}
	// kindInt: the port.
	abs := n
	if abs < 0 {
		abs = -abs
	}
	if abs == 0 {
		// Default port per key.
		if strings.Contains(spec.bridgeKey, "clash") {
			return 9090
		}
		return 9091
	}
	return abs
}

func encodeSignedPair(spec settingSpec, value any, rows map[string]string) map[string]string {
	key := spec.rowKeys[0]
	raw := rows[key]
	n, _ := strconv.Atoi(raw)
	abs := n
	if abs < 0 {
		abs = -abs
	}
	if abs == 0 {
		if strings.Contains(spec.bridgeKey, "clash") {
			abs = 9090
		} else {
			abs = 9091
		}
	}
	if spec.kind == kindBool {
		enabled, _ := value.(bool)
		if enabled {
			return map[string]string{key: strconv.Itoa(abs)}
		}
		return map[string]string{key: strconv.Itoa(-abs)}
	}
	// kindInt: write the port, preserving the sign.
	port, _ := value.(int)
	if port <= 0 {
		port = abs
	}
	if n > 0 || (n == 0 && false) {
		return map[string]string{key: strconv.Itoa(port)}
	}
	return map[string]string{key: strconv.Itoa(-port)}
}

// --- signedMinutes: negative = off, positive = minutes -------------------------

func decodeSignedMinutes(spec settingSpec, rows map[string]string) any {
	raw := rows[spec.rowKeys[0]]
	n, _ := strconv.Atoi(raw)
	if spec.kind == kindBool {
		return n > 0
	}
	abs := n
	if abs < 0 {
		abs = -abs
	}
	if abs < 30 {
		if strings.Contains(spec.bridgeKey, "sub") {
			return 30
		}
		return 1440
	}
	return abs
}

func encodeSignedMinutes(spec settingSpec, value any, rows map[string]string) map[string]string {
	key := spec.rowKeys[0]
	raw := rows[key]
	n, _ := strconv.Atoi(raw)
	if spec.kind == kindBool {
		enabled, _ := value.(bool)
		abs := n
		if abs < 0 {
			abs = -abs
		}
		if abs < 30 {
			if strings.Contains(spec.bridgeKey, "sub") {
				abs = 30
			} else {
				abs = 1440
			}
		}
		if enabled {
			return map[string]string{key: strconv.Itoa(abs)}
		}
		return map[string]string{key: "-1"}
	}
	// kindInt: write minutes, preserving sign.
	minutes, _ := value.(int)
	if minutes < 30 {
		minutes = 30
	}
	if minutes > 525600 {
		minutes = 525600
	}
	if n > 0 {
		return map[string]string{key: strconv.Itoa(minutes)}
	}
	return map[string]string{key: strconv.Itoa(-minutes)}
}

// --- invertedBool: bridge key is the negation of the row -----------------------

func decodeInvertedBool(spec settingSpec, rows map[string]string) any {
	raw := rows[spec.rowKeys[0]]
	return raw != "true"
}

func encodeInvertedBool(spec settingSpec, value any) map[string]string {
	b, _ := value.(bool)
	if b {
		return map[string]string{spec.rowKeys[0]: "false"}
	}
	return map[string]string{spec.rowKeys[0]: "true"}
}

// --- addressPair: bool maps to an address string -------------------------------

func decodeAddressPair(spec settingSpec, rows map[string]string) any {
	raw := rows[spec.rowKeys[0]]
	return raw == "::"
}

func encodeAddressPair(spec settingSpec, value any) map[string]string {
	b, _ := value.(bool)
	if b {
		return map[string]string{spec.rowKeys[0]: "::"}
	}
	return map[string]string{spec.rowKeys[0]: "127.0.0.1"}
}

// --- mappedInt: bool row exposed as 1/2 int ------------------------------------

func decodeMappedInt(spec settingSpec, rows map[string]string) any {
	raw := rows[spec.rowKeys[0]]
	return raw == "true" || raw == "1"
}

func encodeMappedInt(spec settingSpec, value any) map[string]string {
	// Wire is 1 (true) or 2 (false); row is bool.
	switch v := value.(type) {
	case float64:
		return map[string]string{spec.rowKeys[0]: strconv.Itoa(int(v))}
	case int:
		return map[string]string{spec.rowKeys[0]: strconv.Itoa(v)}
	case bool:
		if v {
			return map[string]string{spec.rowKeys[0]: "1"}
		}
		return map[string]string{spec.rowKeys[0]: "2"}
	}
	return map[string]string{spec.rowKeys[0]: "1"}
}

// --- newlineList: list stored as newline-separated text ------------------------

func decodeNewlineList(spec settingSpec, rows map[string]string) any {
	raw := rows[spec.rowKeys[0]]
	if raw == "" {
		return []string{}
	}
	parts := strings.Split(raw, "\n")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

func encodeNewlineList(spec settingSpec, value any) map[string]string {
	list, _ := value.([]string)
	if list == nil {
		// Try []any from JSON.
		if anyList, ok := value.([]any); ok {
			for _, item := range anyList {
				if s, ok := item.(string); ok {
					list = append(list, s)
				}
			}
		}
	}
	return map[string]string{spec.rowKeys[0]: strings.Join(list, "\n")}
}

// --- longAsBool: long row surfaced as bool -------------------------------------

func decodeLongAsBool(spec settingSpec, rows map[string]string) any {
	raw := rows[spec.rowKeys[0]]
	n, _ := strconv.ParseInt(raw, 10, 64)
	return n != 0
}

func encodeLongAsBool(spec settingSpec, value any) map[string]string {
	b, _ := value.(bool)
	if b {
		return map[string]string{spec.rowKeys[0]: "1"}
	}
	return map[string]string{spec.rowKeys[0]: "0"}
}

// --- listDefault: list with a non-empty default --------------------------------

func decodeListDefault(spec settingSpec, rows map[string]string) any {
	raw, ok := rows[spec.rowKeys[0]]
	if !ok {
		// Default: ServiceNotification.DEFAULT_ACTIONS.
		return []string{"start", "stop", "restart"}
	}
	var list []string
	if raw != "" {
		json.Unmarshal([]byte(raw), &list)
	}
	if list == nil {
		list = []string{}
	}
	return list
}

func encodeListDefault(spec settingSpec, value any) map[string]string {
	list, _ := value.([]string)
	if list == nil {
		list = []string{}
	}
	encoded, _ := json.Marshal(list)
	return map[string]string{spec.rowKeys[0]: string(encoded)}
}

// --- constant: computed, never stored ------------------------------------------

func decodeConstant(spec settingSpec) any {
	switch spec.bridgeKey {
	case "queryMode":
		return "ROOT"
	case "perAppManaged":
		return false
	case "perAppManagedList":
		return []string{}
	}
	return nil
}

// --- hostFact: published by Kotlin, read by Go ---------------------------------

func decodeHostFact(spec settingSpec, rows map[string]string) any {
	raw := rows[spec.rowKeys[0]]
	return raw == "true"
}

// --- defaults -----------------------------------------------------------------

func defaultValue(spec settingSpec) any {
	switch spec.kind {
	case kindBool:
		return false
	case kindInt:
		return 0
	case kindList:
		return []string{}
	default:
		return ""
	}
}

// camelToSnake converts camelCase to snake_case (matching SettingsSchema.kt).
func camelToSnake(name string) string {
	out := make([]byte, 0, len(name)+4)
	for _, c := range []byte(name) {
		if c >= 'A' && c <= 'Z' {
			out = append(out, '_', c+32)
		} else {
			out = append(out, c)
		}
	}
	return string(out)
}
