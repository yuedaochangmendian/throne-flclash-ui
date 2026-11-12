// The route actions: the kernel answers the routing screen directly (ADR 0002, phase 3c).
//
// Go is the sole writer of the route documents (route_store.go); Kotlin keeps a read-only
// view so `ConfigGenerator` and the group route picker still work. This file carries the
// whole domain the old Kotlin BboxRoutes owned: the profile list, the editor seed, the
// simple-address text format, batch add, reset, the rule round-trip and the global pool.
//
// Behaviour is ported value for value from BboxRoutes.kt and
// RouteProfile.appendSimpleAddressRule. Comments name the Kotlin source of any rule that is
// not self-evident, because the screens and the existing profiles were written against it.
//
// Two handlers stay in Kotlin on purpose: presets() and addPreset(). They read the bundled
// profile snapshot and fetch remote profiles, which needs the Android side's network and the
// RouteRepo snapshot — not route data this store owns.

package mobile

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// The stored ids of the four built-in match targets (desktop OutboundIds).
const (
	OutboundProxy      int64 = -1
	OutboundDirect     int64 = -2
	OutboundBlock      int64 = -3
	OutboundWarpBypass int64 = -5
)

// RuleType ids (RuleType.kt). Only the simple-address family is edited as text.
const (
	ruleTypeCustom           = 0
	ruleTypeSimpleAddrProxy  = 1
	ruleTypeSimpleAddrBypass = 2
	ruleTypeSimpleAddrBlock  = 3
	ruleTypeSimpleAddrWarp   = 10
)

// simpleAddressNames mirrors RouteProfile.SIMPLE_ADDRESS_NAMES (RouteRule.h:47-56).
var simpleAddressNames = map[int]string{
	ruleTypeSimpleAddrProxy:  "Simple Address Proxy",
	ruleTypeSimpleAddrBypass: "Simple Address Bypass",
	ruleTypeSimpleAddrBlock:  "Simple Address Block",
	ruleTypeSimpleAddrWarp:   "Simple Address Warp-bypass",
}

func isSimpleAddressType(ruleType int) bool {
	switch ruleType {
	case ruleTypeSimpleAddrProxy, ruleTypeSimpleAddrBypass, ruleTypeSimpleAddrBlock, ruleTypeSimpleAddrWarp:
		return true
	}
	return false
}

const (
	getRouteProfilesMethod      Method = "getRouteProfiles"
	getRouteProfileMethod       Method = "getRouteProfile"
	saveRouteProfileMethod      Method = "saveRouteProfile"
	deleteRouteProfileMethod    Method = "deleteRouteProfile"
	setCurrentRouteMethod       Method = "setCurrentRoute"
	getRouteRulesMethod         Method = "getRouteRules"
	saveRouteRulesMethod        Method = "saveRouteRules"
	batchAddRulesMethod         Method = "batchAddRules"
	resetRouteRulesMethod       Method = "resetRouteRules"
	getGlobalRulesMethod        Method = "getGlobalRules"
	saveGlobalRulesMethod       Method = "saveGlobalRules"
	setGlobalRuleDisabledMethod Method = "setGlobalRuleDisabled"
	deleteGlobalRuleMethod      Method = "deleteGlobalRule"
)

func init() {
	register(getRouteProfilesMethod, handleGetRouteProfiles)
	register(getRouteProfileMethod, handleGetRouteProfile)
	register(saveRouteProfileMethod, handleSaveRouteProfile)
	register(deleteRouteProfileMethod, handleDeleteRouteProfile)
	register(setCurrentRouteMethod, handleSetCurrentRoute)
	register(getRouteRulesMethod, handleGetRouteRules)
	register(saveRouteRulesMethod, handleSaveRouteRules)
	register(batchAddRulesMethod, handleBatchAddRules)
	register(resetRouteRulesMethod, handleResetRouteRules)
	register(getGlobalRulesMethod, handleGetGlobalRules)
	register(saveGlobalRulesMethod, handleSaveGlobalRules)
	register(setGlobalRuleDisabledMethod, handleSetGlobalRuleDisabled)
	register(deleteGlobalRuleMethod, handleDeleteGlobalRule)
}

// --- outbound names ----------------------------------------------------------

func outboundNameOf(id int64) string {
	switch id {
	case OutboundProxy:
		return "proxy"
	case OutboundBlock:
		return "block"
	case OutboundWarpBypass:
		return "warp-bypass"
	}
	return "direct"
}

// outboundIDOf is BboxRoutes.outboundId: four names, case-insensitive, warp_bypass as an
// alias. An unknown name is an error rather than a silent direct.
func outboundIDOf(name string) (int64, error) {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "proxy":
		return OutboundProxy, nil
	case "block":
		return OutboundBlock, nil
	case "warp-bypass", "warp_bypass":
		return OutboundWarpBypass, nil
	case "direct":
		return OutboundDirect, nil
	}
	return 0, fmt.Errorf("unknown outbound %q; use proxy, direct, block or warp-bypass", name)
}

func ruleTypeForOutbound(outbound int64) int {
	switch outbound {
	case OutboundProxy:
		return ruleTypeSimpleAddrProxy
	case OutboundWarpBypass:
		return ruleTypeSimpleAddrWarp
	case OutboundBlock:
		return ruleTypeSimpleAddrBlock
	}
	return ruleTypeSimpleAddrBypass
}

// --- the simple-address text format ------------------------------------------

// addressPrefixes is ADDRESS_PREFIXES, in the order simpleRulesText prints them.
var addressPrefixes = []string{"domain", "suffix", "keyword", "regex", "ruleset", "ip"}

func validAddressPrefix(prefix string) bool {
	for _, candidate := range addressPrefixes {
		if candidate == prefix {
			return true
		}
	}
	return false
}

// splitRuleLine splits `prefix:value -> outbound` the way BboxRoutes does: the arrow is the
// LAST `->`, and a line without one targets direct.
func splitRuleLine(line string) (rawLine, target string) {
	trimmed := strings.TrimSpace(line)
	if arrow := strings.LastIndex(trimmed, "->"); arrow > 0 {
		return strings.TrimSpace(trimmed[:arrow]), strings.TrimSpace(trimmed[arrow+2:])
	}
	return trimmed, "direct"
}

// storedValue lowercases the host-shaped prefixes and leaves the rest as written: sing-box
// lowercases a host itself but takes a regex literally, so lowercasing one changes its
// meaning (appendSimpleAddressRule makes the same distinction).
func storedValue(prefix, value string) string {
	switch prefix {
	case "domain", "suffix", "keyword":
		return strings.ToLower(value)
	}
	return value
}

// listColumnOf maps a prefix onto the stored column holding that list.
func listColumnOf(prefix string) string {
	switch prefix {
	case "domain":
		return "domain_json"
	case "suffix":
		return "domain_suffix_json"
	case "keyword":
		return "domain_keyword_json"
	case "regex":
		return "domain_regex_json"
	case "ruleset":
		return "rule_set_json"
	}
	return "ip_cidr_json"
}

// simpleRulesText renders the simple address rules as the editor's text: one
// `prefix:value -> outbound` line per value, in rule order then field order. Other rule kinds
// are left out — the text is a view of the simple subset, not the whole list.
func simpleRulesText(rules []row) string {
	var builder strings.Builder
	for _, rule := range rules {
		if !isSimpleAddressType(rowInt(rule, "type")) {
			continue
		}
		outbound := outboundNameOf(rowIntOr(rule, "outbound_id", OutboundDirect))
		for _, prefix := range addressPrefixes {
			for _, value := range jsonList(rowString(rule, listColumnOf(prefix))) {
				if builder.Len() > 0 {
					builder.WriteByte('\n')
				}
				builder.WriteString(prefix)
				builder.WriteByte(':')
				builder.WriteString(fmt.Sprint(value))
				builder.WriteString(" -> ")
				builder.WriteString(outbound)
			}
		}
	}
	return builder.String()
}

// idPattern is BboxRoutes.ID_RE: the integer ids inside endpoint_profile_ids.
func idPattern(text string) []int64 {
	out := make([]int64, 0, 4)
	start := -1
	for index, r := range text {
		isDigit := r >= '0' && r <= '9'
		isSign := r == '-' && start < 0
		if isDigit || isSign {
			if start < 0 {
				start = index
			}
			continue
		}
		if start >= 0 {
			if value, err := strconv.ParseInt(text[start:index], 10, 64); err == nil {
				out = append(out, value)
			}
			start = -1
		}
	}
	if start >= 0 {
		if value, err := strconv.ParseInt(text[start:], 10, 64); err == nil {
			out = append(out, value)
		}
	}
	return out
}

// --- profile list ------------------------------------------------------------

func handleGetRouteProfiles(_ json.RawMessage) (any, error) {
	routeStoreMu.Lock()
	defer routeStoreMu.Unlock()

	profiles, rules, err := readRouteState(true)
	if err != nil {
		return nil, err
	}
	current := currentRouteID(profiles)
	wire := make([]any, 0, len(profiles))
	for _, profile := range sortedProfiles(profiles) {
		id := rowInt64(profile, "id")
		mine := rulesOfProfile(rules, id)
		simple := 0
		for _, rule := range mine {
			if isSimpleAddressType(rowInt(rule, "type")) {
				simple++
			}
		}
		wire = append(wire, map[string]any{
			"id":              id,
			"name":            rowString(profile, "name"),
			"defaultOutbound": outboundNameOf(rowIntOr(profile, "default_outbound_id", OutboundDirect)),
			"current":         id == current,
			"isRemote":        rowBool(profile, "is_remote"),
			"isRaw":           rowBool(profile, "is_raw"),
			"ruleCount":       len(mine),
			"simpleRuleCount": simple,
		})
	}
	return map[string]any{"currentId": current, "profiles": wire}, nil
}

// readRouteState loads both documents, seeding the Default profile when the kernel has never
// written them. The seed is what makes the first launch show something the user can edit.
func readRouteState(seed bool) ([]row, []row, error) {
	profiles, err := readDocument(routeProfilesDoc)
	if err != nil {
		return nil, nil, err
	}
	rules, err := readDocument(routeRulesDoc)
	if err != nil {
		return nil, nil, err
	}
	if len(profiles) == 0 && seed {
		profiles = []row{defaultProfileRow()}
		rules = defaultProfileRules()
		if err := writeDocument(routeProfilesDoc, profiles); err != nil {
			return nil, nil, err
		}
		if err := writeDocument(routeRulesDoc, rules); err != nil {
			return nil, nil, err
		}
	}
	return profiles, rules, nil
}

// defaultProfileRow is RouteProfile.defaultProfile's name and default outbound.
func defaultProfileRow() row {
	return row{
		"id":                  int64(1),
		"name":                "Default",
		"default_outbound_id": OutboundDirect,
		"is_raw":              false,
	}
}

// defaultProfileRules is the one hijack-dns rule RouteProfile.defaultProfile carries.
func defaultProfileRules() []row {
	return []row{{
		"route_profile_id": int64(1),
		"rule_order":       0,
		"name":             "Route DNS",
		"action":           "hijack-dns",
		"protocol":         "dns",
		"type":             ruleTypeCustom,
	}}
}

// currentRouteID answers the `__current` marker, else the first usable profile.
func currentRouteID(profiles []row) int64 {
	for _, profile := range profiles {
		if flag, ok := profile["__current"].(bool); ok && flag {
			return rowInt64(profile, "id")
		}
	}
	for _, profile := range sortedProfiles(profiles) {
		if !rowBool(profile, "is_raw") {
			return rowInt64(profile, "id")
		}
	}
	return 0
}

func findProfile(profiles []row, id int64) row {
	for _, profile := range profiles {
		if rowInt64(profile, "id") == id {
			return profile
		}
	}
	return nil
}

func nextProfileID(profiles []row) int64 {
	next := int64(1)
	for _, profile := range profiles {
		if id := rowInt64(profile, "id"); id >= next {
			next = id + 1
		}
	}
	return next
}

// --- editor seed -------------------------------------------------------------

func handleGetRouteProfile(data json.RawMessage) (any, error) {
	var payload struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}
	routeStoreMu.Lock()
	defer routeStoreMu.Unlock()

	profiles, rules, err := readRouteState(true)
	if err != nil {
		return nil, err
	}
	var profile row
	if payload.ID > 0 {
		profile = findProfile(profiles, payload.ID)
		if profile == nil {
			return nil, fmt.Errorf("no route profile with id %d", payload.ID)
		}
	} else {
		profile = row{}
	}
	var mine []row
	if payload.ID > 0 {
		mine = rulesOfProfile(rules, payload.ID)
	}
	return map[string]any{
		"id":              rowInt64(profile, "id"),
		"name":            rowString(profile, "name"),
		"defaultOutbound": outboundNameOf(rowIntOr(profile, "default_outbound_id", OutboundDirect)),
		"isRemote":        rowBool(profile, "is_remote"),
		"remoteUrl":       rowString(profile, "remote_url"),
		"autoUpdate":      rowBool(profile, "auto_update"),
		"isRaw":           rowBool(profile, "is_raw"),
		"endpointIds":     idPattern(rowString(profile, "endpoint_profile_ids")),
		"rules":           simpleRulesText(mine),
		"ruleCount":       len(mine),
	}, nil
}

// --- profile save ------------------------------------------------------------

// pointers make "absent" distinguishable from "empty": the Kotlin handler only touched the
// fields the payload carried, so editing the rules must not blank the remote URL.
type saveProfilePayload struct {
	ID              int64   `json:"id"`
	Name            *string `json:"name"`
	DefaultOutbound *string `json:"defaultOutbound"`
	IsRemote        *bool   `json:"isRemote"`
	RemoteURL       *string `json:"remoteUrl"`
	AutoUpdate      *bool   `json:"autoUpdate"`
	EndpointIDs     []int64 `json:"endpointIds"`
	Rules           *string `json:"rules"`
}

func handleSaveRouteProfile(data json.RawMessage) (any, error) {
	var payload saveProfilePayload
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}
	routeStoreMu.Lock()
	defer routeStoreMu.Unlock()

	profiles, rules, err := readRouteState(true)
	if err != nil {
		return nil, err
	}
	var profile row
	if payload.ID > 0 {
		profile = findProfile(profiles, payload.ID)
		if profile == nil {
			return nil, fmt.Errorf("no route profile with id %d", payload.ID)
		}
		if rowBool(profile, "is_raw") {
			return nil, errors.New("this profile is read-only")
		}
	} else {
		profile = row{"is_raw": false}
	}
	if payload.Name != nil {
		profile["name"] = strings.TrimSpace(*payload.Name)
	}
	if payload.DefaultOutbound != nil {
		id, err := outboundIDOf(*payload.DefaultOutbound)
		if err != nil {
			return nil, err
		}
		profile["default_outbound_id"] = id
	}
	if payload.IsRemote != nil {
		profile["is_remote"] = *payload.IsRemote
	}
	if payload.RemoteURL != nil {
		profile["remote_url"] = strings.TrimSpace(*payload.RemoteURL)
	}
	if payload.AutoUpdate != nil {
		profile["auto_update"] = *payload.AutoUpdate
	}
	if payload.EndpointIDs != nil {
		encoded, err := json.Marshal(payload.EndpointIDs)
		if err != nil {
			return nil, err
		}
		profile["endpoint_profile_ids"] = string(encoded)
	}
	id := payload.ID
	if id <= 0 {
		id = nextProfileID(profiles)
	}
	profile["id"] = id

	if payload.Rules != nil {
		// Every simple rule is replaced, every other rule survives: the text is a view of
		// the simple subset. Values of one (prefix, outbound) fold into a single rule, and
		// an unparsable line rejects the whole save — BboxRoutes.save semantics.
		kept := make([]row, 0, len(rules))
		for _, rule := range rules {
			if rowInt64(rule, "route_profile_id") != id || !isSimpleAddressType(rowInt(rule, "type")) {
				kept = append(kept, rule)
			}
		}
		for _, line := range strings.Split(*payload.Rules, "\n") {
			trimmed := strings.TrimSpace(line)
			if trimmed == "" {
				continue
			}
			rawLine, target := splitRuleLine(trimmed)
			outbound, err := outboundIDOf(target)
			if err != nil {
				return nil, fmt.Errorf("bad rule line: %s", trimmed)
			}
			colon := strings.Index(rawLine, ":")
			if colon < 0 {
				return nil, fmt.Errorf("bad rule line: %s", trimmed)
			}
			prefix := strings.TrimSpace(rawLine[:colon])
			if !validAddressPrefix(prefix) {
				return nil, fmt.Errorf("bad rule line: %s", trimmed)
			}
			value := strings.TrimSpace(rawLine[colon+1:])
			if value == "" {
				return nil, fmt.Errorf("bad rule line: %s", trimmed)
			}
			kept = appendSimpleAddressRule(kept, id, prefix, storedValue(prefix, value), outbound)
		}
		rules = kept
	}

	if findProfile(profiles, id) == nil {
		profiles = append(profiles, profile)
	} else {
		for index, candidate := range profiles {
			if rowInt64(candidate, "id") == id {
				profiles[index] = profile
				break
			}
		}
	}
	if err := writeDocument(routeProfilesDoc, sortedProfiles(profiles)); err != nil {
		return nil, err
	}
	if err := writeDocument(routeRulesDoc, rules); err != nil {
		return nil, err
	}
	return id, nil
}

// appendSimpleAddressRule adds one value to the rule of that type, creating it when absent.
// It mirrors RouteProfile.appendSimpleAddressRule: the dedupe (`if stored !in values`) and
// the block type's `reject` action included.
func appendSimpleAddressRule(rules []row, profileID int64, prefix, value string, outbound int64) []row {
	ruleType := ruleTypeForOutbound(outbound)
	column := listColumnOf(prefix)
	for _, rule := range rules {
		if rowInt64(rule, "route_profile_id") != profileID || rowInt(rule, "type") != ruleType {
			continue
		}
		current := jsonList(rowString(rule, column))
		for _, existing := range current {
			if fmt.Sprint(existing) == value {
				return rules
			}
		}
		encoded, err := json.Marshal(append(current, value))
		if err != nil {
			return rules
		}
		rule[column] = string(encoded)
		return rules
	}
	created := singleValueRule(profileID, len(rulesOfProfile(rules, profileID)), prefix, value, outbound)
	return append(rules, created)
}

// singleValueRule builds a rule holding one value: the shape batchAddRules uses, one line one
// rule so the list can edit and delete it alone.
func singleValueRule(profileID int64, order int, prefix, value string, outbound int64) row {
	ruleType := ruleTypeForOutbound(outbound)
	rule := row{
		"route_profile_id": profileID,
		"rule_order":       order,
		"type":             ruleType,
		"name":             simpleAddressNames[ruleType],
	}
	if ruleType == ruleTypeSimpleAddrBlock {
		rule["action"] = "reject"
	} else {
		rule["outbound_id"] = outbound
	}
	if encoded, err := json.Marshal([]any{value}); err == nil {
		rule[listColumnOf(prefix)] = string(encoded)
	}
	return rule
}

// --- delete / current --------------------------------------------------------

func handleDeleteRouteProfile(data json.RawMessage) (any, error) {
	var payload struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}
	routeStoreMu.Lock()
	defer routeStoreMu.Unlock()

	profiles, rules, err := readRouteState(false)
	if err != nil {
		return nil, err
	}
	kept := make([]row, 0, len(profiles))
	removed := false
	for _, profile := range profiles {
		if rowInt64(profile, "id") == payload.ID {
			removed = true
			continue
		}
		kept = append(kept, profile)
	}
	if !removed {
		return nil, errRouteNotFound
	}
	if len(kept) == 0 {
		return nil, errors.New("cannot delete the last route profile")
	}
	remaining := make([]row, 0, len(rules))
	for _, rule := range rules {
		if rowInt64(rule, "route_profile_id") != payload.ID {
			remaining = append(remaining, rule)
		}
	}
	if err := writeDocument(routeProfilesDoc, kept); err != nil {
		return nil, err
	}
	if err := writeDocument(routeRulesDoc, remaining); err != nil {
		return nil, err
	}
	return nil, nil
}

func handleSetCurrentRoute(data json.RawMessage) (any, error) {
	var payload struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}
	routeStoreMu.Lock()
	defer routeStoreMu.Unlock()

	profiles, _, err := readRouteState(true)
	if err != nil {
		return nil, err
	}
	found := false
	for _, profile := range profiles {
		if rowInt64(profile, "id") == payload.ID && !rowBool(profile, "is_raw") {
			found = true
			profile["__current"] = true
		} else {
			delete(profile, "__current")
		}
	}
	if !found {
		return nil, fmt.Errorf("no usable route profile with id %d", payload.ID)
	}
	if err := writeDocument(routeProfilesDoc, sortedProfiles(profiles)); err != nil {
		return nil, err
	}
	return map[string]any{"currentId": payload.ID}, nil
}

// --- rules ------------------------------------------------------------------

func handleGetRouteRules(data json.RawMessage) (any, error) {
	var payload struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}
	routeStoreMu.Lock()
	defer routeStoreMu.Unlock()

	_, rules, err := readRouteState(false)
	if err != nil {
		return nil, err
	}
	return map[string]any{"rules": wireRules(rulesOfProfile(rules, payload.ID))}, nil
}

// stringColumns are the rule columns the editor round-trips as plain strings.
var ruleStringColumns = []string{
	"ip_version", "network", "protocol", "reject_method", "override_address",
	"override_port", "tls_fragment_fallback_delay", "tls_spoof", "tls_spoof_method", "strategy",
}

// listColumns are the rule columns the editor round-trips as arrays.
var ruleListColumns = []string{
	"inbound_json", "domain_json", "domain_suffix_json", "domain_keyword_json",
	"domain_regex_json", "source_ip_cidr_json", "ip_cidr_json", "source_port_json",
	"source_port_range_json", "port_json", "port_range_json", "process_name_json",
	"process_path_json", "process_path_regex_json", "package_name_json",
	"package_name_regex_json", "network_type_json", "wifi_ssid_json", "wifi_bssid_json",
	"rule_set_json", "sniffers_json",
}

// boolColumns are the rule columns the editor round-trips as booleans.
var ruleBoolColumns = []string{
	"source_ip_is_private", "ip_is_private", "tls_fragment", "tls_record_fragment",
	"invert", "no_drop", "sniff_override_dest", "network_is_expensive",
}

// wireRules renders stored rows as the editor's rule objects. Both the column-shaped names
// (BboxRoutes.ruleToMap's STRING/LIST/BOOL field groups) and the shorthand the routing screen
// reads are present, so neither caller has to guess which spelling it got.
func wireRules(rows []row) []any {
	out := make([]any, 0, len(rows))
	for _, r := range rows {
		wire := map[string]any{
			"name":        rowString(r, "name"),
			"type":        ruleTypeToken(rowInt(r, "type")),
			"disabled":    rowBool(r, "disabled"),
			"action":      rowString(r, "action"),
			"outbound_id": rowIntOr(r, "outbound_id", OutboundDirect),
		}
		for _, column := range ruleStringColumns {
			wire[column] = rowString(r, column)
		}
		for _, column := range ruleListColumns {
			wire[column] = jsonList(rowString(r, column))
		}
		for _, column := range ruleBoolColumns {
			wire[column] = rowBool(r, column)
		}
		// The shorthand names the routing screen reads.
		if column, ok := shorthandColumn("domain"); ok {
			wire["domain"] = wire[column]
		}
		if column, ok := shorthandColumn("domain_suffix"); ok {
			wire["domain_suffix"] = wire[column]
		}
		if column, ok := shorthandColumn("ip_cidr"); ok {
			wire["ip_cidr"] = wire[column]
		}
		if column, ok := shorthandColumn("process_name"); ok {
			wire["process_name"] = wire[column]
		}
		if column, ok := shorthandColumn("network_type"); ok {
			wire["network_type"] = wire[column]
		}
		out = append(out, wire)
	}
	return out
}

// ruleTypeToken is RuleType's token for an id (RuleType.values().firstOrNull { it.id == … }).
func ruleTypeToken(id int) string {
	switch id {
	case ruleTypeSimpleAddrProxy:
		return "simple_address_proxy"
	case ruleTypeSimpleAddrBypass:
		return "simple_address_bypass"
	case ruleTypeSimpleAddrBlock:
		return "simple_address_block"
	case ruleTypeSimpleAddrWarp:
		return "simple_address_warp_bypass"
	case 4:
		return "simple_process_name_proxy"
	case 5:
		return "simple_process_name_bypass"
	case 6:
		return "simple_process_name_block"
	case 7:
		return "simple_process_path_proxy"
	case 8:
		return "simple_process_path_bypass"
	case 9:
		return "simple_process_path_block"
	case 11:
		return "simple_process_name_warp_bypass"
	case 12:
		return "simple_process_path_warp_bypass"
	}
	return "custom"
}

func ruleTypeID(token string) (int, bool) {
	switch token {
	case "simple_address_proxy":
		return ruleTypeSimpleAddrProxy, true
	case "simple_address_bypass":
		return ruleTypeSimpleAddrBypass, true
	case "simple_address_block":
		return ruleTypeSimpleAddrBlock, true
	case "simple_address_warp_bypass":
		return ruleTypeSimpleAddrWarp, true
	case "simple_process_name_proxy":
		return 4, true
	case "simple_process_name_bypass":
		return 5, true
	case "simple_process_name_block":
		return 6, true
	case "simple_process_path_proxy":
		return 7, true
	case "simple_process_path_bypass":
		return 8, true
	case "simple_process_path_block":
		return 9, true
	case "simple_process_name_warp_bypass":
		return 11, true
	case "simple_process_path_warp_bypass":
		return 12, true
	case "custom":
		return ruleTypeCustom, true
	}
	return ruleTypeCustom, false
}

// shorthandColumn maps the routing screen's short field names onto the stored columns.
func shorthandColumn(key string) (string, bool) {
	switch key {
	case "domain":
		return "domain_json", true
	case "domain_suffix":
		return "domain_suffix_json", true
	case "ip_cidr":
		return "ip_cidr_json", true
	case "process_name":
		return "process_name_json", true
	case "network_type":
		return "network_type_json", true
	}
	return "", false
}

func handleSaveRouteRules(data json.RawMessage) (any, error) {
	var payload struct {
		ID    int64            `json:"id"`
		Rules []map[string]any `json:"rules"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}
	routeStoreMu.Lock()
	defer routeStoreMu.Unlock()

	profiles, rules, err := readRouteState(true)
	if err != nil {
		return nil, err
	}
	target := findProfile(profiles, payload.ID)
	if target == nil {
		return nil, fmt.Errorf("no route profile with id %d", payload.ID)
	}
	if rowBool(target, "is_raw") {
		return nil, errors.New("this profile is read-only")
	}
	previous := rulesOfProfile(rules, payload.ID)
	kept := make([]row, 0, len(rules))
	for _, rule := range rules {
		if rowInt64(rule, "route_profile_id") != payload.ID {
			kept = append(kept, rule)
		}
	}
	for index, rule := range payload.Rules {
		var preserve row
		if index < len(previous) {
			preserve = previous[index]
		}
		kept = append(kept, ruleRowFromWire(payload.ID, index, rule, preserve))
	}
	if err := writeDocument(routeRulesDoc, kept); err != nil {
		return nil, err
	}
	return map[string]any{"rules": wireRules(rulesOfProfile(kept, payload.ID))}, nil
}

// ruleRowFromWire turns one editor rule into a stored row.
//
// [preserve] carries the row this rule already had (nil for a new one): every column the
// editor does not send is copied from it rather than reset, so a rule with port ranges,
// keyword lists or TLS options does not come back with those conditions wiped.
func ruleRowFromWire(profileID int64, order int, rule map[string]any, preserve row) row {
	out := row{}
	for key, value := range preserve {
		if key == "__current" {
			continue
		}
		out[key] = value
	}
	for key, value := range rule {
		switch key {
		case "name", "action":
			out[key] = fmt.Sprint(value)
		case "type":
			if token, ok := value.(string); ok {
				ruleType, known := ruleTypeID(token)
				if !known && token != "" {
					// An unknown token is a custom rule, which is what BboxRoutes did.
					ruleType = ruleTypeCustom
				}
				out["type"] = ruleType
			} else {
				out["type"] = intOf(value)
			}
		case "disabled", "invert", "no_drop", "sniff_override_dest", "network_is_expensive",
			"tls_fragment", "tls_record_fragment", "source_ip_is_private", "ip_is_private":
			out[key] = boolOf(value)
		case "outbound_id":
			out[key] = int64Of(value)
		default:
			if strings.HasSuffix(key, "_json") {
				if encoded, err := json.Marshal(value); err == nil {
					out[key] = string(encoded)
				}
				continue
			}
			if column, ok := shorthandColumn(key); ok {
				if encoded, err := json.Marshal(value); err == nil {
					out[column] = string(encoded)
				}
				continue
			}
			out[key] = value
		}
	}
	out["route_profile_id"] = profileID
	out["rule_order"] = order
	return out
}

// --- batch add / reset -------------------------------------------------------

func handleBatchAddRules(data json.RawMessage) (any, error) {
	var payload struct {
		ID   int64  `json:"id"`
		Text string `json:"text"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}
	routeStoreMu.Lock()
	defer routeStoreMu.Unlock()

	profiles, rules, err := readRouteState(true)
	if err != nil {
		return nil, err
	}
	target := findProfile(profiles, payload.ID)
	if target == nil || rowBool(target, "is_raw") {
		return nil, fmt.Errorf("no usable route profile with id %d", payload.ID)
	}
	added := 0
	for _, line := range strings.Split(payload.Text, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		rawLine, destination := splitRuleLine(trimmed)
		outbound, err := outboundIDOf(destination)
		if err != nil {
			return nil, fmt.Errorf("bad rule line: %s", trimmed)
		}
		colon := strings.Index(rawLine, ":")
		if colon < 0 {
			return nil, fmt.Errorf("bad rule line: %s", trimmed)
		}
		prefix := strings.TrimSpace(rawLine[:colon])
		if !validAddressPrefix(prefix) {
			return nil, fmt.Errorf("bad rule line: %s", trimmed)
		}
		value := strings.TrimSpace(rawLine[colon+1:])
		if value == "" {
			return nil, fmt.Errorf("bad rule line: %s", trimmed)
		}
		// One rule per line, unlike save's text which folds a type together.
		rules = append(rules, singleValueRule(payload.ID, len(rulesOfProfile(rules, payload.ID)),
			prefix, storedValue(prefix, value), outbound))
		added++
	}
	if added == 0 {
		return nil, errors.New("no rule lines to add")
	}
	if err := writeDocument(routeRulesDoc, rules); err != nil {
		return nil, err
	}
	return map[string]any{"added": added, "rules": wireRules(rulesOfProfile(rules, payload.ID))}, nil
}

func handleResetRouteRules(data json.RawMessage) (any, error) {
	var payload struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}
	routeStoreMu.Lock()
	defer routeStoreMu.Unlock()

	profiles, rules, err := readRouteState(true)
	if err != nil {
		return nil, err
	}
	target := findProfile(profiles, payload.ID)
	if target == nil || rowBool(target, "is_raw") {
		return nil, fmt.Errorf("no usable route profile with id %d", payload.ID)
	}
	kept := make([]row, 0, len(rules))
	for _, rule := range rules {
		if rowInt64(rule, "route_profile_id") != payload.ID {
			kept = append(kept, rule)
		}
	}
	// The Default chain's own rules (RouteProfile.defaultProfile).
	for index, template := range defaultProfileRules() {
		reset := row{}
		for key, value := range template {
			reset[key] = value
		}
		reset["route_profile_id"] = payload.ID
		reset["rule_order"] = index
		kept = append(kept, reset)
	}
	if err := writeDocument(routeRulesDoc, kept); err != nil {
		return nil, err
	}
	return map[string]any{"rules": wireRules(rulesOfProfile(kept, payload.ID))}, nil
}

// --- global pool -------------------------------------------------------------

const globalRulesDoc = "global_route_rules"

func handleGetGlobalRules(data json.RawMessage) (any, error) {
	var payload struct {
		ProfileID int64 `json:"profileId"`
	}
	_ = json.Unmarshal(data, &payload)

	routeStoreMu.Lock()
	defer routeStoreMu.Unlock()
	return globalRulesLocked(payload.ProfileID)
}

// globalRulesLocked answers the pool for [profileID] (0 = no per-profile state).
// The caller holds routeStoreMu.
func globalRulesLocked(profileID int64) (any, error) {
	disabled := map[int64]bool{}
	if profileID > 0 {
		profiles, err := readDocument(routeProfilesDoc)
		if err != nil {
			return nil, err
		}
		if profile := findProfile(profiles, profileID); profile != nil {
			for _, id := range idPattern(rowString(profile, "disabled_global_rule_json")) {
				disabled[id] = true
			}
		}
	}
	rows, err := readDocument(globalRulesDoc)
	if err != nil {
		return nil, err
	}
	wire := wireRules(rows)
	for index, entry := range wire {
		id := rowInt64(rows[index], "id")
		entry.(map[string]any)["id"] = id
		entry.(map[string]any)["enabled"] = !disabled[id]
	}
	return map[string]any{"rules": wire}, nil
}

func handleSaveGlobalRules(data json.RawMessage) (any, error) {
	var payload struct {
		Rules []map[string]any `json:"rules"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}
	routeStoreMu.Lock()
	defer routeStoreMu.Unlock()

	rows := make([]row, 0, len(payload.Rules))
	for index, rule := range payload.Rules {
		stored := ruleRowFromWire(0, index, rule, nil)
		delete(stored, "route_profile_id")
		if raw, ok := rule["id"]; ok {
			stored["id"] = int64Of(raw)
		} else {
			stored["id"] = int64(index + 1)
		}
		rows = append(rows, stored)
	}
	if err := writeDocument(globalRulesDoc, rows); err != nil {
		return nil, err
	}
	return globalRulesLocked(0)
}

func handleSetGlobalRuleDisabled(data json.RawMessage) (any, error) {
	var payload struct {
		ProfileID int64   `json:"profileId"`
		IDs       []int64 `json:"ids"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}
	routeStoreMu.Lock()
	defer routeStoreMu.Unlock()

	profiles, _, err := readRouteState(true)
	if err != nil {
		return nil, err
	}
	profile := findProfile(profiles, payload.ProfileID)
	if profile == nil {
		return nil, fmt.Errorf("no route profile with id %d", payload.ProfileID)
	}
	encoded, err := json.Marshal(payload.IDs)
	if err != nil {
		return nil, err
	}
	profile["disabled_global_rule_json"] = string(encoded)
	if err := writeDocument(routeProfilesDoc, sortedProfiles(profiles)); err != nil {
		return nil, err
	}
	return nil, nil
}

func handleDeleteGlobalRule(data json.RawMessage) (any, error) {
	var payload struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}
	routeStoreMu.Lock()
	defer routeStoreMu.Unlock()

	rows, err := readDocument(globalRulesDoc)
	if err != nil {
		return nil, err
	}
	kept := make([]row, 0, len(rows))
	for _, r := range rows {
		if rowInt64(r, "id") != payload.ID {
			kept = append(kept, r)
		}
	}
	if err := writeDocument(globalRulesDoc, kept); err != nil {
		return nil, err
	}
	return nil, nil
}
