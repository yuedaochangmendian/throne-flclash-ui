// Profiles and groups, as JSON documents owned by the kernel (ADR 0002, phase 3d).
//
// The route documents (route_store.go) proved the pattern: Go is the only writer, Kotlin keeps
// a read-only view, and the row shape is Room's column names verbatim. This file extends that
// to the two remaining Room tables the profile domain needs — `profiles` (ProxyEntity) and
// `groups` (ProxyGroup) — so the profile action handlers (phase 3d PR-3/PR-4) can read and
// write without touching Room.
//
// The column set is deliberately exhaustive: every @ColumnInfo name from ProxyEntity and
// ProxyGroup appears here and in the Kotlin read-only views. A missing column is a silent
// data-loss bug on round-trip, so the lists must stay in lock-step.
package mobile

import (
	"sort"
	"sync"
)

const (
	profilesDoc = "profiles"
	groupsDoc   = "groups"
)

// profileStoreMu serialises every read-modify-write on the profile/group documents. Separate
// from routeStoreMu so a slow route save cannot block a profile read.
var profileStoreMu sync.Mutex

// --- profiles ----------------------------------------------------------------

// sortedProfilesById orders by id, the order ProxyEntity.Dao.all() returns.
func sortedProfilesById(rows []row) []row {
	out := append([]row(nil), rows...)
	sort.SliceStable(out, func(a, b int) bool {
		return rowInt64(out[a], "id") < rowInt64(out[b], "id")
	})
	return out
}

// profilesOfGroup filters by gid, preserving the user_order sort the DAO applies.
func profilesOfGroup(rows []row, groupID int64) []row {
	kept := make([]row, 0, 16)
	for _, r := range rows {
		if rowInt64(r, "gid") == groupID {
			kept = append(kept, r)
		}
	}
	sort.SliceStable(kept, func(a, b int) bool {
		return rowInt64(kept[a], "user_order") < rowInt64(kept[b], "user_order")
	})
	return kept
}

// findProfileByID returns the row with the given id, or nil.
func findProfileByID(rows []row, id int64) row {
	for _, r := range rows {
		if rowInt64(r, "id") == id {
			return r
		}
	}
	return nil
}

// --- groups ------------------------------------------------------------------

// sortedGroups orders by display_order then id, matching ProxyGroup.Dao.allGroups().
func sortedGroups(rows []row) []row {
	out := append([]row(nil), rows...)
	sort.SliceStable(out, func(a, b int) bool {
		oa, ob := rowInt64(out[a], "display_order"), rowInt64(out[b], "display_order")
		if oa != ob {
			return oa < ob
		}
		return rowInt64(out[a], "id") < rowInt64(out[b], "id")
	})
	return out
}

// findGroupByID returns the row with the given id, or nil.
func findGroupByID(rows []row, id int64) row {
	for _, r := range rows {
		if rowInt64(r, "id") == id {
			return r
		}
	}
	return nil
}

// nextGroupID returns MAX(id) + 1, matching Room's autoGenerate.
func nextGroupID(rows []row) int64 {
	var max int64
	for _, r := range rows {
		if id := rowInt64(r, "id"); id > max {
			max = id
		}
	}
	return max + 1
}

// nextGroupDisplayOrder returns MAX(display_order) + 1, matching
// ProxyGroup.Dao.nextDisplayOrder().
func nextGroupDisplayOrder(rows []row) int64 {
	var max int64
	for _, r := range rows {
		if order := rowInt64(r, "display_order"); order > max {
			max = order
		}
	}
	return max + 1
}
