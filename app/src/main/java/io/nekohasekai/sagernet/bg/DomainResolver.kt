package io.nekohasekai.sagernet.bg

import io.nekohasekai.sagernet.ktx.readableMessage
import io.throneproj.mobile.Mobile
import io.throneproj.mobile.ResolveRequest
import org.json.JSONArray
import org.json.JSONObject

/**
 * Domain resolution through the running box, the core's ResolveDomains RPC.
 *
 * The core pins lookups to its `dns-direct` transport: the OS resolver is what a kill switch
 * blocks, and a running Tun answers it from fakeip, so asking the system would report the
 * tunnel's own fake addresses back as the answer. When no instance runs the core would build a
 * probe box from a full config; this bridge has no config to hand it, so [resolve] answers
 * `running = false` instead of quietly resolving against the phone's resolver and presenting that
 * as the tunnel's answer.
 *
 * The call blocks: the core resolves 16 domains at a time at 5 s each, and [MAX_DOMAINS] keeps the
 * worst case near ten seconds. It runs in :bg, never on the channel thread.
 */
object DomainResolver {

    /** 32 domains: two waves of the core's 16-wide pool, so a dead resolver still answers in time. */
    const val MAX_DOMAINS = 32

    /** One lookup, already shaped for the bridge. */
    data class Resolved(val domain: String, val addresses: List<String>, val error: String)

    fun resolve(domains: List<String>): String {
        val wanted = domains.map { it.trim() }.filter { it.isNotEmpty() }.distinct().take(MAX_DOMAINS)
        if (wanted.isEmpty()) return wire(running = false, results = emptyList())
        val running = CoreRuntime.running ?: return wire(running = false, results = emptyList())
        val results = try {
            val request = ResolveRequest()
            wanted.forEach(request::addDomain)
            val iterator = Mobile.resolveDomains(running.instance, CoreRuntime.platform, request)
            buildList {
                while (iterator.hasNext()) {
                    val item = iterator.next()
                    val addresses = ArrayList<String>()
                    val resolved = item.addresses()
                    while (resolved.hasNext()) addresses.add(resolved.next())
                    add(Resolved(item.domain, addresses, item.error.orEmpty()))
                }
            }
        } catch (e: Exception) {
            // A refused lookup is one result's error, not a failed screen: every requested domain
            // answers with the reason so the caller can show it next to the name.
            wanted.map { Resolved(it, emptyList(), e.readableMessage) }
        }
        return wire(running = true, results = results)
    }

    /** The reply the bridge parses. `running` is false when nothing runs or no domain was given. */
    internal fun wire(running: Boolean, results: List<Resolved>): String {
        val array = JSONArray()
        for (result in results) {
            array.put(JSONObject().apply {
                put("domain", result.domain)
                put("addresses", JSONArray(result.addresses))
                put("error", result.error)
            })
        }
        return JSONObject().apply {
            put("running", running)
            put("results", array)
        }.toString()
    }
}
