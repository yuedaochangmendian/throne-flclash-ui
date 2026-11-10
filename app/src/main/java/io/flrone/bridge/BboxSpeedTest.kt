package io.flrone.bridge

import io.nekohasekai.sagernet.bg.CoreRuntime
import io.nekohasekai.sagernet.ktx.Logs
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
 * through, and "Direct" is the honest answer rather than a guess.
 */
object BboxSpeedTest {

    /** Starts a test; false when one is already running or the core is down. */
    suspend fun start(paramsJson: String): Boolean = withContext(Dispatchers.IO) {
        val running = CoreRuntime.running
        if (running == null) error("Start the VPN first: the speed test measures through the running core")
        Mobile.startBettboxSpeedTest(running.instance, paramsJson)
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
        val running = CoreRuntime.running
        if (running == null) return@withContext emptyList<Any?>()
        val raw = Mobile.bettboxSpeedTestServers(running.instance, outbound, search)
        runCatching { JSONArray(raw).toList() }.getOrElse {
            Logs.w(it)
            emptyList()
        }
    }

    /** The running box's outbound tags, the picker's list. */
    suspend fun outbounds(): List<String> = withContext(Dispatchers.IO) {
        val running = CoreRuntime.running ?: return@withContext emptyList<String>()
        val raw = Mobile.bettboxSpeedTestOutbounds(running.instance)
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
