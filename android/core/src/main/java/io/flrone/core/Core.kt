// The JNI face of the self-owned kernel bridge (libcore.so + the Go shared
// library). Kernel control itself goes Dart -> dart:ffi; this object covers the
// Android duties only: the fd push and the platform callbacks.
package io.flrone.core

object Core {

    init {
        System.loadLibrary("core")
    }

    /**
     * Feed the VpnService fd and its [TunInterface] to the kernel before the
     * core starts (the bettbox flow): establish() -> fd -> startTun(fd, tun).
     */
    external fun startTun(fd: Int, tun: TunInterface)

    external fun stopTun()

    /**
     * Closes a kernel Instance the host adopted from Dart. A stop from the
     * widget/tile/notification has no Dart isolate to answer it once the Flutter
     * engine is gone, so the host owns the numeric handle until then.
     */
    external fun closeInstance(handle: Long)

    /**
     * The Bettbox speed test against the Dart-owned instance, through the
     * numeric handle Dart registered over `ffi.handle` — the FFI twin of
     * `Mobile.startBettboxSpeedTest`, which needs the AAR's `Instance` object
     * that FFI mode never has. 1 started, 0 busy (a test is already running),
     * -1 the handle has no live instance.
     */
    external fun startBettboxSpeedTest(handle: Long, params: String): Int

    /** speedtest.net's server list, nearest first; "[]" without a live instance. */
    external fun bettboxSpeedTestServers(handle: Long, outbound: String, search: String): String

    /** The running box's outbound tags, the picker's list; "[]" likewise. */
    external fun bettboxSpeedTestOutbounds(handle: Long): String

    /**
     * A TunOptions handle as JSON (mtu, addresses, routes, dns, packages, http
     * proxy) — the fields VpnService.Builder needs when the kernel asks for the
     * VPN mid-start through CorePlatform.openTun.
     */
    external fun tunSpecJson(handle: Long): String

    /** 0 = resume, 1 = suspend, 2 = doze-suspend. */
    external fun suspend(suspended: Int)

    /** Register the platform-wide duties implementation (once). */
    external fun setPlatform(platform: CorePlatform)

    /** Report a default-interface change to a Go InterfaceUpdateListener. */
    external fun updateDefaultInterface(
        listener: Long,
        name: String,
        index: Int,
        isExpensive: Boolean,
        isConstrained: Boolean,
    )

    external fun updateNetworkPath(listener: Long, path: String)

    /** ExchangeContext completions (the local-DNS transport's answers, called while the call blocks). */
    external fun exchangeSuccess(handle: Long, result: String)

    external fun exchangeRawSuccess(handle: Long, result: ByteArray)

    external fun exchangeErrorCode(handle: Long, code: Int)

    external fun exchangeErrnoCode(handle: Long, code: Int)

    external fun exchangeOnCancel(handle: Long, callback: Any?)
}
