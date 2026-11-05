package io.throne.bbox.bridge

import io.nekohasekai.sagernet.bg.CoreServiceClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/**
 * Domain resolution for the diagnostics screen: `dns.resolve` hands a list of names to the core
 * process, which resolves them through the running box's `dns-direct` transport, and answers
 * `running = false` when no box is up (see `DomainResolver` for why the phone's resolver is never
 * used as a stand-in).
 *
 * The lookup blocks in :bg for up to ~10 s, so the call goes through [CoreServiceClient] on the IO
 * dispatcher rather than the channel thread.
 */
object BboxResolve {

    /** Resolves [domains] and returns `{running, results: [{domain, addresses, error}]}`. */
    suspend fun resolve(domains: List<String>): Map<String, Any?> = withContext(Dispatchers.IO) {
        val reply = CoreServiceClient.call { service -> service.resolveDomains(domains.toTypedArray()) }
        parse(reply)
    }

    /** The JSON reply as the map the UI reads; an unusable answer degrades to `running = false`. */
    internal fun parse(reply: String?): Map<String, Any?> {
        val root = reply?.takeIf { it.isNotBlank() }?.let { runCatching { JSONObject(it) }.getOrNull() }
            ?: return mapOf("running" to false, "results" to emptyList<Any?>())
        val results = root.optJSONArray("results") ?: JSONArray()
        val rows = ArrayList<Map<String, Any?>>(results.length())
        for (index in 0 until results.length()) {
            val row = results.optJSONObject(index) ?: continue
            val addresses = row.optJSONArray("addresses") ?: JSONArray()
            rows.add(
                mapOf(
                    "domain" to row.optString("domain"),
                    "addresses" to List(addresses.length()) { position -> addresses.optString(position) },
                    "error" to row.optString("error"),
                )
            )
        }
        return mapOf("running" to root.optBoolean("running"), "results" to rows)
    }
}
