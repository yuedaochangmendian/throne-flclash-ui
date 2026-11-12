// Codec unit tests for the settings schema (ADR 0002, phase 3e).
//
// These test the pure-Go codec archetypes — the split-key encodings that must be
// preserved byte-for-byte. Run with `go test ./core/mobile/` in the assembled core tree.
package mobile

import (
	"testing"
)

func TestDecodeSignedPair(t *testing.T) {
	// clashApiEnabled: flag = row > 0.
	spec := settingSpec{bridgeKey: "clashApiEnabled", kind: kindBool, codec: codecSignedPair, rowKeys: []string{"core_box_clash_api"}}
	if got := decodeRow(spec, map[string]string{"core_box_clash_api": "9090"}); got != true {
		t.Errorf("enabled with positive row: got %v, want true", got)
	}
	if got := decodeRow(spec, map[string]string{"core_box_clash_api": "-9090"}); got != false {
		t.Errorf("disabled with negative row: got %v, want false", got)
	}

	// clashApiPort: |row|, default 9090 when 0.
	portSpec := settingSpec{bridgeKey: "clashApiPort", kind: kindInt, codec: codecSignedPair, rowKeys: []string{"core_box_clash_api"}}
	if got := decodeRow(portSpec, map[string]string{"core_box_clash_api": "9090"}); got != 9090 {
		t.Errorf("port from positive row: got %v, want 9090", got)
	}
	if got := decodeRow(portSpec, map[string]string{"core_box_clash_api": "-9090"}); got != 9090 {
		t.Errorf("port from negative row: got %v, want 9090", got)
	}
	if got := decodeRow(portSpec, map[string]string{"core_box_clash_api": "0"}); got != 9090 {
		t.Errorf("port default: got %v, want 9090", got)
	}

	// boxApiPort default is 9091.
	boxPortSpec := settingSpec{bridgeKey: "boxApiPort", kind: kindInt, codec: codecSignedPair, rowKeys: []string{"core_box_api_port"}}
	if got := decodeRow(boxPortSpec, map[string]string{"core_box_api_port": "0"}); got != 9091 {
		t.Errorf("boxApi port default: got %v, want 9091", got)
	}
}

func TestEncodeSignedPair(t *testing.T) {
	spec := settingSpec{bridgeKey: "clashApiEnabled", kind: kindBool, codec: codecSignedPair, rowKeys: []string{"core_box_clash_api"}}
	// Enable: positive.
	writes := encodeWire(spec, true, map[string]string{"core_box_clash_api": "-9090"})
	if writes["core_box_clash_api"] != "9090" {
		t.Errorf("enable: got %q, want 9090", writes["core_box_clash_api"])
	}
	// Disable: negative.
	writes = encodeWire(spec, false, map[string]string{"core_box_clash_api": "9090"})
	if writes["core_box_clash_api"] != "-9090" {
		t.Errorf("disable: got %q, want -9090", writes["core_box_clash_api"])
	}
}

func TestDecodeSignedMinutes(t *testing.T) {
	// subAutoUpdateEnabled: flag = row > 0.
	spec := settingSpec{bridgeKey: "subAutoUpdateEnabled", kind: kindBool, codec: codecSignedMinutes, rowKeys: []string{"sub_auto_update"}}
	if got := decodeRow(spec, map[string]string{"sub_auto_update": "120"}); got != true {
		t.Errorf("enabled: got %v, want true", got)
	}
	if got := decodeRow(spec, map[string]string{"sub_auto_update": "-1"}); got != false {
		t.Errorf("disabled: got %v, want false", got)
	}

	// subAutoUpdateMinutes: |row|, default 30.
	minSpec := settingSpec{bridgeKey: "subAutoUpdateMinutes", kind: kindInt, codec: codecSignedMinutes, rowKeys: []string{"sub_auto_update"}}
	if got := decodeRow(minSpec, map[string]string{"sub_auto_update": "120"}); got != 120 {
		t.Errorf("minutes: got %v, want 120", got)
	}
	if got := decodeRow(minSpec, map[string]string{"sub_auto_update": "-1"}); got != 30 {
		t.Errorf("minutes default: got %v, want 30", got)
	}

	// routeAutoUpdateMinutes default is 1440.
	routeMinSpec := settingSpec{bridgeKey: "routeAutoUpdateMinutes", kind: kindInt, codec: codecSignedMinutes, rowKeys: []string{"route_auto_update"}}
	if got := decodeRow(routeMinSpec, map[string]string{"route_auto_update": "-1"}); got != 1440 {
		t.Errorf("route minutes default: got %v, want 1440", got)
	}
}

func TestDecodeInvertedBool(t *testing.T) {
	spec := settingSpec{bridgeKey: "allowBypass", kind: kindBool, codec: codecInvertedBool, rowKeys: []string{"disable_private_range_bypass"}}
	if got := decodeRow(spec, map[string]string{"disable_private_range_bypass": "true"}); got != false {
		t.Errorf("inverted true: got %v, want false", got)
	}
	if got := decodeRow(spec, map[string]string{"disable_private_range_bypass": "false"}); got != true {
		t.Errorf("inverted false: got %v, want true", got)
	}
}

func TestDecodeAddressPair(t *testing.T) {
	spec := settingSpec{bridgeKey: "allowLan", kind: kindBool, codec: codecAddressPair, rowKeys: []string{"inbound_address"}}
	if got := decodeRow(spec, map[string]string{"inbound_address": "::"}); got != true {
		t.Errorf("LAN address: got %v, want true", got)
	}
	if got := decodeRow(spec, map[string]string{"inbound_address": "127.0.0.1"}); got != false {
		t.Errorf("loopback: got %v, want false", got)
	}
}

func TestEncodeAddressPair(t *testing.T) {
	spec := settingSpec{bridgeKey: "allowLan", kind: kindBool, codec: codecAddressPair, rowKeys: []string{"inbound_address"}}
	writes := encodeWire(spec, true, map[string]string{})
	if writes["inbound_address"] != "::" {
		t.Errorf("enable LAN: got %q, want ::", writes["inbound_address"])
	}
	writes = encodeWire(spec, false, map[string]string{})
	if writes["inbound_address"] != "127.0.0.1" {
		t.Errorf("disable LAN: got %q, want 127.0.0.1", writes["inbound_address"])
	}
}

func TestDecodeNewlineList(t *testing.T) {
	spec := settingSpec{bridgeKey: "perAppList", kind: kindList, codec: codecNewlineList, rowKeys: []string{"individual"}}
	got := decodeRow(spec, map[string]string{"individual": "com.a\ncom.b\n\n  com.c  "})
	list, ok := got.([]string)
	if !ok || len(list) != 3 {
		t.Fatalf("newline list: got %v, want 3 items", got)
	}
	if list[0] != "com.a" || list[1] != "com.b" || list[2] != "com.c" {
		t.Errorf("newline list items: got %v", list)
	}
}

func TestDecodeLongAsBool(t *testing.T) {
	spec := settingSpec{bridgeKey: "startWithoutRuleSets", kind: kindBool, codec: codecLongAsBool, rowKeys: []string{"startWithoutRuleSets"}}
	if got := decodeRow(spec, map[string]string{"startWithoutRuleSets": "1"}); got != true {
		t.Errorf("long 1: got %v, want true", got)
	}
	if got := decodeRow(spec, map[string]string{"startWithoutRuleSets": "0"}); got != false {
		t.Errorf("long 0: got %v, want false", got)
	}
}

func TestDecodeConstant(t *testing.T) {
	querySpec := settingSpec{bridgeKey: "queryMode", kind: kindText, codec: codecConstant}
	if got := decodeRow(querySpec, map[string]string{}); got != "ROOT" {
		t.Errorf("queryMode: got %v, want ROOT", got)
	}
	managedSpec := settingSpec{bridgeKey: "perAppManaged", kind: kindBool, codec: codecConstant}
	if got := decodeRow(managedSpec, map[string]string{}); got != false {
		t.Errorf("perAppManaged: got %v, want false", got)
	}
}

func TestDecodeDirectCoercion(t *testing.T) {
	// Bool from "true"/"false".
	boolSpec := settingSpec{bridgeKey: "adblockEnable", kind: kindBool, codec: codecDirect, rowKeys: []string{"adblock_enable"}}
	if got := decodeRow(boolSpec, map[string]string{"adblock_enable": "true"}); got != true {
		t.Errorf("direct bool true: got %v", got)
	}
	if got := decodeRow(boolSpec, map[string]string{"adblock_enable": "false"}); got != false {
		t.Errorf("direct bool false: got %v", got)
	}

	// Int from decimal string.
	intSpec := settingSpec{bridgeKey: "rulesetMirror", kind: kindInt, codec: codecDirect, rowKeys: []string{"rulesetMirror"}}
	if got := decodeRow(intSpec, map[string]string{"rulesetMirror": "42"}); got != 42 {
		t.Errorf("direct int: got %v, want 42", got)
	}

	// Missing row returns default.
	if got := decodeRow(boolSpec, map[string]string{}); got != false {
		t.Errorf("missing bool default: got %v, want false", got)
	}
}

func TestCamelToSnake(t *testing.T) {
	tests := map[string]string{
		"adblockEnable":  "adblock_enable",
		"serviceMode":    "service_mode",
		"logBufSize":     "log_buf_size",
		"simpleKey":      "simple_key",
		"already_snake":  "already_snake",
	}
	for input, want := range tests {
		if got := camelToSnake(input); got != want {
			t.Errorf("camelToSnake(%q) = %q, want %q", input, got, want)
		}
	}
}
