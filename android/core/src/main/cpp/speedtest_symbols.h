// Hand-written companion of the generated bridge_symbols.h: the Bettbox speed
// test entry points that take the running instance as a numeric handle. They
// live outside the generated header on purpose — bindgen reads the upstream
// jar and cannot know the core patch's own functions — so a regenerated
// bridge_symbols.h never drops them. The Go side of the contract is
// `buildScript/core-patch/core/mobile/speedtest_bridge.go`.
#ifndef SPEEDTEST_SYMBOLS_H
#define SPEEDTEST_SYMBOLS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Starts one test on the instance behind [current]; 1 started, 0 busy (a test
   is already running), -1 the handle has no live instance. */
int throne_Mobile_startBettboxSpeedTest(int64_t current, const char *params);

/* speedtest.net's server list, nearest first; "[]" when nothing can be read.
   The caller frees the result with throne_free. */
char *throne_Mobile_bettboxSpeedTestServers(int64_t current, const char *outbound, const char *search);

/* The running box's outbound tags, the picker's list; "[]" without a live
   instance. The caller frees the result with throne_free. */
char *throne_Mobile_bettboxSpeedTestOutbounds(int64_t current);

#ifdef __cplusplus
}
#endif

#endif // SPEEDTEST_SYMBOLS_H
