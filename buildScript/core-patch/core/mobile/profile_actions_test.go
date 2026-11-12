// Ordering rules for the Room groups table (ADR 0002, phase 3d follow-up).
//
// The kernel renumbers display_order in Room, so a reorder that disagrees with
// GroupRepo.setDisplayOrder breaks the tab order: the DAO sorts by display_order,
// so a 1-based run leaves a hole and an omitted group keeps its old number in the
// middle of the new sequence.
package mobile

import (
	"reflect"
	"testing"
)

func group(id int64, order int64) roomGroup {
	return roomGroup{id: id, order: order}
}

func TestOrderedGroupIDsIsZeroBased(t *testing.T) {
	groups := []roomGroup{group(1, 0), group(2, 1)}
	got := orderedGroupIDs(groups, []int64{2, 1})
	if !reflect.DeepEqual(got, []int64{2, 1}) {
		t.Fatalf("want [2 1], got %v", got)
	}
}

func TestOrderedGroupIDsAppendsOmittedGroups(t *testing.T) {
	groups := []roomGroup{group(1, 0), group(2, 1), group(3, 2)}
	got := orderedGroupIDs(groups, []int64{3})
	if !reflect.DeepEqual(got, []int64{3, 1, 2}) {
		t.Fatalf("want [3 1 2], got %v", got)
	}
}

func TestOrderedGroupIDsDropsUnknownAndDuplicateIDs(t *testing.T) {
	groups := []roomGroup{group(1, 0), group(2, 1)}
	got := orderedGroupIDs(groups, []int64{99, 2, 2, 1})
	if !reflect.DeepEqual(got, []int64{2, 1}) {
		t.Fatalf("duplicates and unknown ids must not shift the order: %v", got)
	}
}

func TestOrderedGroupIDsLeavesNoHoles(t *testing.T) {
	groups := []roomGroup{group(1, 5), group(2, 9), group(3, 42)}
	got := orderedGroupIDs(groups, []int64{1, 2, 3})
	if !reflect.DeepEqual(got, []int64{1, 2, 3}) {
		t.Fatalf("want [1 2 3], got %v", got)
	}
}

func TestOrderedGroupIDsWithEmptyInputKeepsStoredOrder(t *testing.T) {
	groups := []roomGroup{group(7, 0), group(4, 1)}
	got := orderedGroupIDs(groups, nil)
	if !reflect.DeepEqual(got, []int64{7, 4}) {
		t.Fatalf("an empty request must keep the stored order: %v", got)
	}
}
