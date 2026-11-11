package io.flrone.bridge

import io.flrone.core.Core
import io.nekohasekai.sagernet.bg.CoreRuntime
import io.nekohasekai.sagernet.ktx.Logs
import io.throneproj.mobile.Instance
import io.throneproj.mobile.Mobile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/**
 * The Bettbox speed test, over the kernel's own implementation.
 *
 * `core/mobile/speedtest.go` (patched in by `buildScript/core-patch`) runs the
 * test inside the core process against the running instance's outbounds, so a
 * measurement uses exactly the hop the user selected — the same claim Bettbox's
 * mihomo-side tester makes. This object only shapes the JSON for Dart: the four
 * `Mobile.*Bettbox*` calls are the whole contract.
 *
 * The test needs a started instance: without one there is no outbound to dial
 * through, and "Direct" is the honest answer rather than a guess. Which driver
 * owns that instance decides the call shape: the service holds an `Instance`
 * object for the AAR's gobind calls, while in FFI mode Dart owns the instance
 * and only its numeric handle reaches here over `ffi.handle` — that side goes
 * through the C ABI in `io.flrone.core.Core`, whose symbols
 * (`core/mobile/speedtest_bridge.go`) resolve the instance from the handle.
 */
object BboxSpeedTest {

    /** The instance to test through, in the shape its driver provides. */
    private sealed interface TestTarget {
        /** The service-built core: a live `Instance` object for the gobind calls. */
        data class Service(val instance: Instance) : TestTarget

        /** The Dart-built core: a numeric handle for the C ABI calls. */
        data class Ffi(val handle: Long) : TestTarget
    }

    private fun testTarget(): TestTarget? {
        CoreRuntime.running?.let { return TestTarget.Service(it.instance) }
        val handle = BboxKernel.kernelHandle
        return if (handle != 0L) TestTarget.Ffi(handle) else null
    }

    private fun requireTarget(): TestTarget =
        testTarget() ?: error("Start the VPN first: the speed test measures through the running core")

    /** Starts a test; false when one is already running or the core is down. */
    suspend fun start(paramsJson: String): Boolean = withContext(Dispatchers.IO) {
        when (val target = requireTarget()) {
            is TestTarget.Service -> Mobile.startBettboxSpeedTest(target.instance, paramsJson)
            // 1 started, 0 busy, -1 the handle outlived its instance (the core
            // died under the button) — reported as the same VPN-first message.
            is TestTarget.Ffi -> when (Core.startBettboxSpeedTest(target.handle, paramsJson)) {
                1 -> true
                0 -> false
                else -> error("Start the VPN first: the speed test measures through the running core")
            }
        }
    }

    /** The live snapshot, `{state, running}`; the UI polls it while a test runs. */
    suspend fun query(): Map<String, Any?> = withContext(Dispatchers.IO) {
        val raw = Mobile.queryBettboxSpeedTest()
        val json = runCatching { JSONObject(raw) }.getOrElse {
            Logs.w(it)
            return@withContext mapOf("state" to emptyMap<String, Any?>(), "running" to false)
        }
        mapOf(
            "state" to (json.optJSONObject("state")?.toMap() ?: emptyMap<String, Any?>()),
            "running" to json.optBoolean("running"),
        )
    }

    suspend fun cancel(): Boolean = withContext(Dispatchers.IO) {
        Mobile.cancelBettboxSpeedTest()
    }

    /** speedtest.net's server list, nearest first; `[]` when the list cannot be read. */
    suspend fun servers(outbound: String, search: String): List<Any?> = withContext(Dispatchers.IO) {
        val target = testTarget() ?: return@withContext emptyList<Any?>()
        val raw = when (target) {
            is TestTarget.Service -> Mobile.bettboxSpeedTestServers(target.instance, outbound, search)
            is TestTarget.Ffi -> Core.bettboxSpeedTestServers(target.handle, outbound, search)
        }
        runCatching { JSONArray(raw).toList() }.getOrElse {
            Logs.w(it)
            emptyList()
        }
    }

    /** The running box's outbound tags, the picker's list. */
    suspend fun outbounds(): List<String> = withContext(Dispatchers.IO) {
        val target = testTarget() ?: return@withContext emptyList<String>()
        val raw = when (target) {
            is TestTarget.Service -> Mobile.bettboxSpeedTestOutbounds(target.instance)
            is TestTarget.Ffi -> Core.bettboxSpeedTestOutbounds(target.handle)
        }
        runCatching {
            val array = JSONArray(raw)
            buildList { for (i in 0 until array.length()) add(array.getString(i)) }
        }.getOrElse {
            Logs.w(it)
            emptyList()
        }
    }

    // ------------------------------------------------------------------ JSON → wire

    /** A JSONObject flattened to the map shapes the Dart side normalizes. */
    private fun JSONObject.toMap(): Map<String, Any?> {
        val out = LinkedHashMap<String, Any?>(length())
        for (key in keys()) {
            out[key] = toWire(opt(key))
        }
        return out
    }

    private fun JSONArray.toList(): List<Any?> = buildList {
        for (i in 0 until length()) add(toWire(opt(i)))
    }

    private fun toWire(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> value.toMap()
        is JSONArray -> value.toList()
        else -> value
    }
}
