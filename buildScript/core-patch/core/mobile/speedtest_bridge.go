// The Bettbox speed test's handle-based C ABI, companion to speedtest.go.
//
// The gobind calls in speedtest.go reach Kotlin through the ThroneCore AAR,
// where the JVM already holds an `Instance` object. The Dart-owned FFI
// instance has no such object — Kotlin only holds the numeric handle Dart
// registered over `ffi.handle` — so these three exports resolve the instance
// from that handle themselves, the same way the generated bridge does for
// `throne_Mobile_startURLTest`. Query and cancel need no instance: their state
// is process-wide, and the same libthrone.so answers whichever side calls.
//
// The symbols are declared for the JNI shim in
// `android/core/src/main/cpp/speedtest_symbols.h`; this file is hand-written,
// outside the bindgen output, so a regenerated bridge never drops them.
package mobile

/*
#include <stdlib.h>
*/
import "C"

//export throne_Mobile_startBettboxSpeedTest
func throne_Mobile_startBettboxSpeedTest(current C.int64_t, params *C.char) C.int {
	defer guardExport("throne_Mobile_startBettboxSpeedTest")
	instance, ok := handleGet(int64(current)).(*Instance)
	if !ok {
		// -1: no live instance behind the handle — the VPN is off or the core
		// died, which the caller reports as its own message rather than
		// "already running".
		return -1
	}
	if StartBettboxSpeedTest(instance, C.GoString(params)) {
		return 1
	}
	return 0
}

//export throne_Mobile_bettboxSpeedTestServers
func throne_Mobile_bettboxSpeedTestServers(current C.int64_t, outbound *C.char, search *C.char) *C.char {
	defer guardExport("throne_Mobile_bettboxSpeedTestServers")
	instance, ok := handleGet(int64(current)).(*Instance)
	if !ok {
		return C.CString("[]")
	}
	return C.CString(BettboxSpeedTestServers(instance, C.GoString(outbound), C.GoString(search)))
}

//export throne_Mobile_bettboxSpeedTestOutbounds
func throne_Mobile_bettboxSpeedTestOutbounds(current C.int64_t) *C.char {
	defer guardExport("throne_Mobile_bettboxSpeedTestOutbounds")
	instance, ok := handleGet(int64(current)).(*Instance)
	if !ok {
		return C.CString("[]")
	}
	return C.CString(BettboxSpeedTestOutbounds(instance))
}
