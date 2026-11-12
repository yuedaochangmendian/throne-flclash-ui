// Reading a stored number must not narrow it (ADR 0002, phase 3d).
//
// `intOf` answers int64 because every caller puts the value into the
// map[string]any a handler returns, and Dart reads a JSON number as num. An int
// return would need a bound check whose upper half is unreachable on 64-bit
// builds and whose lower half only exists on the 32-bit ABIs — a conversion
// carrying a hazard for no gain. CodeQL flagged exactly that, three times,
// across attempts to bound it; widening the type is what removed the hazard.
//
// The float64 branch still needs a clamp: Go leaves an out-of-range
// float-to-int conversion undefined, and JSON has no integer type, so a
// hand-edited document can hold 1e30.
package mobile

import (
	"math"
	"testing"
)

func TestIntOfKeepsLargeValues(t *testing.T) {
	// Larger than a 32-bit int: the old narrowing would have wrapped it
	// negative on armeabi-v7a and i686.
	const large = int64(1) << 40
	if got := intOf(large); got != large {
		t.Fatalf("a large int64 must survive intact, got %d", got)
	}
	if got := intOf(-large); got != -large {
		t.Fatalf("a large negative int64 must survive intact, got %d", got)
	}
}

func TestIntOfKeepsOrdinaryValues(t *testing.T) {
	cases := []struct {
		name  string
		value any
		want  int64
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

func TestFloatToInt64Clamps(t *testing.T) {
	if got := floatToInt64(math.MaxFloat64); got != math.MaxInt64 {
		t.Fatalf("a huge float must saturate, got %d", got)
	}
	if got := floatToInt64(-math.MaxFloat64); got != math.MinInt64 {
		t.Fatalf("a huge negative float must saturate, got %d", got)
	}
	// NaN and the infinities have no integer value; zero is the honest answer
	// and keeps the form from rendering a garbage setting.
	if got := floatToInt64(math.NaN()); got != 0 {
		t.Fatalf("NaN must read as 0, got %d", got)
	}
	if got := floatToInt64(math.Inf(1)); got != 0 {
		t.Fatalf("+Inf must read as 0, got %d", got)
	}
	if got := floatToInt64(math.Inf(-1)); got != 0 {
		t.Fatalf("-Inf must read as 0, got %d", got)
	}
	if got := floatToInt64(900); got != 900 {
		t.Fatalf("an ordinary float must convert, got %d", got)
	}
}
