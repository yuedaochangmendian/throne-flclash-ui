// Profile row helpers for the Room-backed action handlers (ADR 0002, phase 3d).
//
// The profile actions read and write the Room `profiles`/`groups` tables over
// SQLite (room_db.go); Room is the single authority, so there is no document
// store here. Only the two row helpers the read handlers share survive.
package mobile

import "sort"

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
