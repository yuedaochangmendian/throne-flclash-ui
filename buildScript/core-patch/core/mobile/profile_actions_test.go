// Ordering rules for the groups document (ADR 0002, phase 3d follow-up).
//
// The kernel is the only writer of groups.json, so a reorder that disagrees with
// GroupRepo.setDisplayOrder breaks the tab order without any error: GroupJsonStore
// sorts by display_order, so a 1-based run leaves a hole and an omitted group keeps
// its old number in the middle of the new sequence.
package mobile

import "testing"

func groupRow(id int64, order int64) row {
	return row{"id": id, "display_order": order}
}

func orders(groups []row) map[int64]int64 {
	out := make(map[int64]int64, len(groups))
	for _, group := range groups {
		out[rowInt64(group, "id")] = rowInt64(group, "display_order")
	}
	return out
}

func TestApplyGroupOrderIsZeroBased(t *testing.T) {
	groups := []row{groupRow(1, 0), groupRow(2, 1)}
	applyGroupOrder(groups, []int64{2, 1})

	got := orders(groups)
	if got[2] != 0 || got[1] != 1 {
		t.Fatalf("want 2->0 and 1->1, got %v", got)
	}
}

func TestApplyGroupOrderAppendsOmittedGroups(t *testing.T) {
	// Three stored groups, caller names only the third: the other two follow in
	// their current stored order instead of keeping their stale numbers.
	groups := []row{groupRow(1, 0), groupRow(2, 1), groupRow(3, 2)}
	applyGroupOrder(groups, []int64{3})

	got := orders(groups)
	if got[3] != 0 {
		t.Errorf("named group: want 0, got %d", got[3])
	}
	if got[1] != 1 || got[2] != 2 {
		t.Errorf("omitted groups: want 1->1, 2->2, got %v", got)
	}
}

func TestApplyGroupOrderDropsUnknownAndDuplicateIDs(t *testing.T) {
	groups := []row{groupRow(1, 0), groupRow(2, 1)}
	applyGroupOrder(groups, []int64{99, 2, 2, 1})

	got := orders(groups)
	if got[2] != 0 || got[1] != 1 {
		t.Fatalf("duplicates and unknown ids must not shift the numbering: %v", got)
	}
}

func TestApplyGroupOrderLeavesNoHoles(t *testing.T) {
	groups := []row{groupRow(1, 5), groupRow(2, 9), groupRow(3, 42)}
	applyGroupOrder(groups, []int64{1, 2, 3})

	got := orders(groups)
	for id, want := range map[int64]int64{1: 0, 2: 1, 3: 2} {
		if got[id] != want {
			t.Fatalf("id %d: want %d, got %d (all: %v)", id, want, got[id], got)
		}
	}
}

func TestApplyGroupOrderWithEmptyInputKeepsStoredOrder(t *testing.T) {
	groups := []row{groupRow(7, 0), groupRow(4, 1)}
	applyGroupOrder(groups, nil)

	got := orders(groups)
	if got[7] != 0 || got[4] != 1 {
		t.Fatalf("an empty request must not renumber: %v", got)
	}
}
