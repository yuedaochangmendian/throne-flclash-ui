// Narrowing a stored number to int must saturate, not wrap (ADR 0002, phase 3d).
//
// Two Android ABIs are 32-bit, where int cannot hold every int64. A plain
// conversion would turn a large stored value into a negative one, and the forms
// would render a number the user never typed. CodeQL flagged the original
// conversion; this pins the replacement.
package mobile

import (
	"strconv"
	"testing"
)

func TestIntOfSaturatesInsteadOfWrapping(t *testing.T) {
	// 1<<40 is representable in int64 but not in a 32-bit int.
	if got := intOf(int64(1) << 40); got <= 0 {
		t.Fatalf("a huge positive int64 must clamp positive, got %d (int is %d bits)", got, strconv.IntSize)
	}
	if got := intOf(int64(-1) << 40); got >= 0 {
		t.Fatalf("a huge negative int64 must clamp negative, got %d", got)
	}
	// The float64 branch has the same hazard: a value past the int range.
	if got := intOf(float64(1) * (1 << 40)); got <= 0 {
		t.Fatalf("a huge float64 must clamp positive, got %d", got)
	}
}

func TestIntOfKeepsOrdinaryValues(t *testing.T) {
	cases := []struct {
		name  string
		value any
		want  int
	}{
		{"int64 zero", int64(0), 0},
		{"int64", int64(300), 300},
		{"int64 negative", int64(-7), -7},
		{"float64", float64(900), 900},
		{"int", 42, 42},
		{"non-numeric", "nope", 0},
		{"nil", nil, 0},
	}
	for _, c := range cases {
		if got := intOf(c.value); got != c.want {
			t.Fatalf("%s: want %d, got %d", c.name, c.want, got)
		}
	}
}

func TestNarrowToIntRefusesNaN(t *testing.T) {
	nan := 0.0
	nan = nan / nan
	if got := narrowToInt(nan); got != 0 {
		t.Fatalf("NaN must read as 0, got %d", got)
	}
}
