// Profile read and simple-write actions, answered from the JSON documents (ADR 0002, phase 3d).
//
// These handlers read and write `profiles.json` and `route_rules.json` — the two documents Go
// already owns — and return the same wire shapes the Kotlin handlers produced. Methods that
// need the Kotlin outbound model (share links, full config generation, outbound parsing,
// subscription fetching) stay on the channel: Go cannot call into Kotlin, and reimplementing
// the outbound model here is out of scope.
package mobile

import (
	"encoding/json"
	"errors"
	"fmt"
)

// The method names the Dart ActionMethod enum uses.
const (
	profileStatsMethod   Method = "profileStats"
	profileNodeInfoMethod Method = "profileNodeInfo"
	profileNodeConfigMethod Method = "profileNodeConfig"
	profileNodeTuningInfoMethod Method = "profileNodeTuningInfo"
	profileReorderMethod Method = "profileReorder"
	profileNodeDeleteMethod Method = "profileNodeDelete"
	profileClearTestResultsMethod Method = "profileClearTestResults"
	profileClearTrafficMethod Method = "profileClearTraffic"
)

func init() {
	register(profileStatsMethod, handleProfileStats)
	register(profileNodeInfoMethod, handleProfileNodeInfo)
	register(profileNodeConfigMethod, handleProfileNodeConfig)
	register(profileNodeTuningInfoMethod, handleProfileNodeTuningInfo)
	register(profileReorderMethod, handleProfileReorder)
	register(profileNodeDeleteMethod, handleProfileNodeDelete)
	register(profileClearTestResultsMethod, handleProfileClearTestResults)
	register(profileClearTrafficMethod, handleProfileClearTraffic)
}

// --- stats -------------------------------------------------------------------

// handleProfileStats returns the counts the dashboard card shows: group membership size
// and the routing rules currently in force. Mirrors BboxProfiles.stats.
func handleProfileStats(data json.RawMessage) (any, error) {
	var payload struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}
	profileStoreMu.Lock()
	defer profileStoreMu.Unlock()

	profiles, err := readDocument(profilesDoc)
	if err != nil {
		return nil, err
	}
	members := profilesOfGroup(profiles, payload.ID)

	// The rule count is the current route profile's rules, matching
	// SagerDatabase.routeDao.rulesOf(DataStore.currentRouteId).
	rules, err := readDocument(routeRulesDoc)
	if err != nil {
		return nil, err
	}
	routeProfiles, err := readDocument(routeProfilesDoc)
	if err != nil {
		return nil, err
	}
	var currentID int64
	for _, rp := range routeProfiles {
		if rowBool(rp, "__current") {
			currentID = rowInt64(rp, "id")
			break
		}
	}
	ruleCount := 0
	if currentID > 0 {
		ruleCount = len(rulesOfProfile(rules, currentID))
	}

	return map[string]any{
		"groups":   1,
		"outbounds": len(members),
		"rules":    ruleCount,
	}, nil
}

// --- node info ---------------------------------------------------------------

// handleProfileNodeInfo returns the editor seed for one node: its name, type and content.
// The content is the outbound JSON; the Dart side formats it. Mirrors BboxProfiles.nodeInfo
// minus the share-link generation, which needs the Kotlin outbound model.
func handleProfileNodeInfo(data json.RawMessage) (any, error) {
	var payload struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}
	profileStoreMu.Lock()
	defer profileStoreMu.Unlock()

	profiles, err := readDocument(profilesDoc)
	if err != nil {
		return nil, err
	}
	profile := findProfileByID(profiles, payload.ID)
	if profile == nil {
		return nil, fmt.Errorf("no proxy with id %d", payload.ID)
	}
	return map[string]any{
		"id":      rowInt64(profile, "id"),
		"name":    rowString(profile, "name"),
		"type":    rowString(profile, "type"),
		"content": rowString(profile, "outbound_json"),
	}, nil
}

// --- node config -------------------------------------------------------------

// handleProfileNodeConfig returns the typed form's seed: the node's canonical JSON.
// The xray/endpoint flags are derived from the type field. Mirrors BboxProfiles.nodeConfig
// minus ProfileJson.text formatting.
func handleProfileNodeConfig(data json.RawMessage) (any, error) {
	var payload struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}
	profileStoreMu.Lock()
	defer profileStoreMu.Unlock()

	profiles, err := readDocument(profilesDoc)
	if err != nil {
		return nil, err
	}
	profile := findProfileByID(profiles, payload.ID)
	if profile == nil {
		return nil, fmt.Errorf("no proxy with id %d", payload.ID)
	}
	profileType := rowString(profile, "type")
	return map[string]any{
		"id":   rowInt64(profile, "id"),
		"name": rowString(profile, "name"),
		"json": rowString(profile, "outbound_json"),
		// The type strings that indicate an Xray-style or endpoint outbound.
		"xray":     isXrayType(profileType),
		"endpoint": isEndpointType(profileType),
	}, nil
}

// isXrayType reports whether the outbound type uses Xray-style features. The Kotlin
// Outbound.isXray() is overridden by Xray-specific subclasses; the type name is the
// reliable discriminator in the stored JSON.
func isXrayType(t string) bool {
	switch t {
	case "vless", "xhttp", "wireguard", "hysteria", "hysteria2", "tuic":
		return true
	}
	return false
}

// isEndpointType reports whether the outbound is an endpoint (Masque).
func isEndpointType(t string) bool {
	return t == "masque"
}

// --- node tuning info ---------------------------------------------------------

// handleProfileNodeTuningInfo returns the mux/tls override state for one node. The Kotlin
// version uses Java reflection to find the multiplex and tls fields; here we read them
// from the outbound JSON. Mirrors BboxProfiles.nodeTuningInfo's wire shape.
func handleProfileNodeTuningInfo(data json.RawMessage) (any, error) {
	var payload struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}
	profileStoreMu.Lock()
	defer profileStoreMu.Unlock()

	profiles, err := readDocument(profilesDoc)
	if err != nil {
		return nil, err
	}
	profile := findProfileByID(profiles, payload.ID)
	if profile == nil {
		return nil, fmt.Errorf("no proxy with id %d", payload.ID)
	}

	raw := rowString(profile, "outbound_json")
	var outbound map[string]any
	if raw == "" {
		return nil, errors.New("profile has no outbound JSON")
	}
	if err := json.Unmarshal([]byte(raw), &outbound); err != nil {
		return nil, fmt.Errorf("parse outbound JSON: %w", err)
	}

	mux, hasMux := outbound["multiplex"].(map[string]any)
	tls, hasTls := outbound["tls"].(map[string]any)

	// Distinguish standard multiplex from Xray multiplex by the presence of the
	// `concurrency` field (XrayMultiplex) vs `protocol` (Multiplex).
	hasXrayMux := false
	if hasMux {
		if _, ok := mux["concurrency"]; ok {
			hasXrayMux = true
			hasMux = false
		}
	}

	result := map[string]any{
		"id":        payload.ID,
		"hasMux":    hasMux,
		"hasXrayMux": hasXrayMux,
		"hasTls":    hasTls,
	}

	if hasMux {
		result["muxState"] = muxState(mux)
		result["muxProtocol"] = stringOf(mux["protocol"])
		result["muxMaxStreams"] = intOf(mux["max_streams"])
		result["muxMaxConnections"] = intOf(mux["max_connections"])
		result["muxMinStreams"] = intOf(mux["min_streams"])
		result["muxPadding"] = boolOf(mux["padding"])
		if brutal, ok := mux["brutal"].(map[string]any); ok {
			result["muxBrutal"] = boolOf(brutal["enabled"])
			result["muxBrutalUp"] = intOf(brutal["up_mbps"])
			result["muxBrutalDown"] = intOf(brutal["down_mbps"])
		} else {
			result["muxBrutal"] = false
			result["muxBrutalUp"] = 0
			result["muxBrutalDown"] = 0
		}
	} else {
		result["muxState"] = 0
		result["muxProtocol"] = ""
		result["muxMaxStreams"] = 0
		result["muxMaxConnections"] = 0
		result["muxMinStreams"] = 0
		result["muxPadding"] = false
		result["muxBrutal"] = false
		result["muxBrutalUp"] = 0
		result["muxBrutalDown"] = 0
	}

	if hasXrayMux {
		result["xrayMuxState"] = muxState(mux)
		result["xrayMuxConcurrency"] = intOf(mux["concurrency"])
		result["xrayMuxMaxConnections"] = intOf(mux["maxConnections"])
		result["xrayMuxXudpConcurrency"] = intOf(mux["xudpConcurrency"])
		result["xrayMuxXudpProxyUDP443"] = boolOf(mux["xudpProxyUDP443"])
	} else {
		result["xrayMuxState"] = 0
		result["xrayMuxConcurrency"] = 0
		result["xrayMuxMaxConnections"] = 0
		result["xrayMuxXudpConcurrency"] = 0
		result["xrayMuxXudpProxyUDP443"] = false
	}

	if hasTls {
		result["fragmentState"] = triState(tls, "fragment_unspecified", "fragment")
		result["fragmentFallbackDelay"] = stringOf(tls["fragment_fallback_delay"])
		result["recordFragment"] = boolOf(tls["record_fragment"])
		result["tlsTricksState"] = triState(tls, "tls_tricks_unspecified", "tls_tricks")
	} else {
		result["fragmentState"] = 0
		result["fragmentFallbackDelay"] = ""
		result["recordFragment"] = false
		result["tlsTricksState"] = 0
	}

	return result, nil
}

// muxState returns 0 (default), 1 (on) or 2 (off) from the `enabled` field, matching
// Multiplex.getMuxState().
func muxState(m map[string]any) int {
	if enabled, ok := m["enabled"].(bool); ok {
		if enabled {
			return 1
		}
		return 2
	}
	return 0
}

// triState returns 0 (unspecified), 1 (on) or 2 (off) from a pair of boolean fields,
// matching the Kotlin `when { unspecified -> 0; flag -> 1; else -> 2 }` pattern.
func triState(m map[string]any, unspecifiedKey, flagKey string) int {
	if boolOf(m[unspecifiedKey]) {
		return 0
	}
	if boolOf(m[flagKey]) {
		return 1
	}
	return 2
}

// --- write actions (phase 3d, PR-4) ------------------------------------------
//
// These are the mutations Go can own: direct row edits on the JSON documents. Operations
// that need OutboundFactory, parseOutbounds, subscription fetching or BboxBridge.refresh
// stay on the channel.

// handleProfileReorder updates display_order on the groups document to match the given id
// order. Mirrors BboxProfiles.reorder -> GroupRepo.setDisplayOrder.
func handleProfileReorder(data json.RawMessage) (any, error) {
	var payload struct {
		IDs []int64 `json:"ids"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}
	profileStoreMu.Lock()
	defer profileStoreMu.Unlock()

	groups, err := readDocument(groupsDoc)
	if err != nil {
		return nil, err
	}
	for i, id := range payload.IDs {
		for _, g := range groups {
			if rowInt64(g, "id") == id {
				g["display_order"] = int64(i + 1)
				break
			}
		}
	}
	if err := writeDocument(groupsDoc, sortedGroups(groups)); err != nil {
		return nil, err
	}
	return nil, nil
}

// handleProfileNodeDelete removes one profile row. Mirrors BboxProfiles.deleteNode ->
// ProfileManager.deleteProfile. The group itself stays.
func handleProfileNodeDelete(data json.RawMessage) (any, error) {
	var payload struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}
	profileStoreMu.Lock()
	defer profileStoreMu.Unlock()

	profiles, err := readDocument(profilesDoc)
	if err != nil {
		return nil, err
	}
	kept := make([]row, 0, len(profiles))
	removed := false
	for _, p := range profiles {
		if rowInt64(p, "id") == payload.ID {
			removed = true
			continue
		}
		kept = append(kept, p)
	}
	if !removed {
		return nil, fmt.Errorf("no proxy with id %d", payload.ID)
	}
	if err := writeDocument(profilesDoc, sortedProfilesById(kept)); err != nil {
		return nil, err
	}
	return nil, nil
}

// handleProfileClearTestResults resets every member's test fields in the given group.
// Mirrors BboxProfiles.clearGroupTestResults -> ProfileManager.clearGroupTestResults.
func handleProfileClearTestResults(data json.RawMessage) (any, error) {
	var payload struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}
	profileStoreMu.Lock()
	defer profileStoreMu.Unlock()

	profiles, err := readDocument(profilesDoc)
	if err != nil {
		return nil, err
	}
	for _, p := range profiles {
		if rowInt64(p, "gid") != payload.ID {
			continue
		}
		p["latency"] = 0
		p["latency_at"] = int64(0)
		p["dl_speed"] = nil
		p["ul_speed"] = nil
		p["test_country"] = nil
		p["ip_out"] = nil
		p["test_error"] = nil
	}
	if err := writeDocument(profilesDoc, profiles); err != nil {
		return nil, err
	}
	return nil, nil
}

// handleProfileClearTraffic resets every member's traffic counters in the given group.
// Mirrors BboxProfiles.clearGroupTraffic -> ProfileManager.resetTraffic.
func handleProfileClearTraffic(data json.RawMessage) (any, error) {
	var payload struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}
	profileStoreMu.Lock()
	defer profileStoreMu.Unlock()

	profiles, err := readDocument(profilesDoc)
	if err != nil {
		return nil, err
	}
	for _, p := range profiles {
		if rowInt64(p, "gid") != payload.ID {
			continue
		}
		p["traffic_dl"] = int64(0)
		p["traffic_up"] = int64(0)
	}
	if err := writeDocument(profilesDoc, profiles); err != nil {
		return nil, err
	}
	return nil, nil
}
