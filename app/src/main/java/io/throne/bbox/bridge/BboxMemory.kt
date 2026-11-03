package io.throne.bbox.bridge

import android.os.Build

/**
 * System-level memory trimming on Android — the platform half of Bettbox's background-GC strategy.
 *
 * The core is sing-box/Xray compiled into this process, so there is no "core GC" call to make the way
 * Bettbox's desktop core has. What Android can do is hint the ART runtime ([gc]) and ask it to trim
 * the heap back to the OS ([purgeMemory]) when the system reports memory pressure.
 *
 * Bettbox trims malloc arenas with `mallopt`; bionic exports `mallopt` as a plain libc symbol with no
 * `Java_` binding, so it cannot be reached through JNI static registration without a native shim. The
 * ART [dalvik.system.VMRuntime.trimHeap] this invokes serves the same purpose — it releases the heap
 * the runtime holds onto after a burst of traffic — and is stable since API 21, hidden only from the
 * SDK surface.
 */
object BboxMemory {

    /** A soft hint: ART decides when it actually collects. */
    fun gc() {
        runCatching { Runtime.getRuntime().gc() }
    }

    /**
     * Releases the heap back to the OS. A no-op below SDK 28, mirroring the floor Bettbox sets before
     * it trims arenas; above it the trim runs through reflection so a future removal degrades to a
     * no-op instead of a crash.
     */
    fun purgeMemory() {
        if (Build.VERSION.SDK_INT < 28) return
        runCatching {
            val vmRuntime = Class.forName("dalvik.system.VMRuntime")
            val runtime = vmRuntime.getMethod("getRuntime").invoke(null)
            vmRuntime.getMethod("trimHeap").invoke(runtime)
        }
    }
}
