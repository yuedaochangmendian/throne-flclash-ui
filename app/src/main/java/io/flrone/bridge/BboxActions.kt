package io.flrone.bridge

import io.nekohasekai.sagernet.database.RouteManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The method-channel action table (ADR 0002, phase 3b-2).
 *
 * `ThroneBoxBridge.onMethodCall` used to hold every data-plane handler inline as a 136-arm
 * `when`. This object keeps handlers in a registry keyed by the same dotted names, so the
 * bridge only forwards and the wire contract is one table instead of one giant expression.
 *
 * Returning [Unhandled] rather than throwing is deliberate: the bridge falls back to its own
 * arms for anything not registered, so a domain can move without touching the rest.
 *
 * ADR 0002 phase 3c moved the route DATA to the Go kernel (which is now its only writer), so
 * the profile and rule handlers are gone from here. What stays is the three entries that are
 * not route data:
 *
 *  * `routes.presets` / `routes.addPreset` read the bundled profile snapshot and fetch remote
 *    profiles — Android-side network and the RouteRepo snapshot, not something the kernel owns;
 *  * `routes.ruleSets` searches the local rule-set catalog that `RouteManager` builds from the
 *    installed rule-set files.
 */
object BboxActions {

    /** Marker type: "this registry has no handler for that name". */
    object Unhandled

    private typealias Handler = suspend (Map<String, Any?>) -> Any?

    private val handlers = LinkedHashMap<String, Handler>()

    /** Registers [handler] under [method]; a duplicate replaces the earlier one. */
    fun register(method: String, handler: Handler) {
        handlers[method] = handler
    }

    /** The names this registry answers; used by the contract audit. */
    val methods: Set<String> get() = handlers.keys

    /** Runs [method] with [args], or [Unhandled] when nothing is registered for it. */
    suspend fun invoke(method: String, args: Map<String, Any?>): Any? =
        handlers[method]?.invoke(args) ?: Unhandled

    init {
        register("routes.ruleSets") { args ->
            val query = args.string("query").trim()
            val limit = requireLong(args["limit"]).toInt().let { if (it > 0) it else 100 }
            val catalog = withContext(Dispatchers.IO) { RouteManager.catalog() }
            mapOf(
                "total" to catalog.size,
                "entries" to catalog.search(query, limit).map { (name, url) ->
                    mapOf("name" to name, "url" to url)
                },
            )
        }
    }
}

// --- argument coercion --------------------------------------------------------
//
// The channel hands numbers over as Int/Double/Long depending on the platform codec, so a
// plain `as Long` cast is the kind of bug that only shows on one device. Normalised once.

private fun requireLong(value: Any?): Long = when (value) {
    is Long -> value
    is Int -> value.toLong()
    is Number -> value.toLong()
    is String -> value.toLongOrNull() ?: -1L
    else -> -1L
}

private fun requireString(value: Any?): String = value?.toString().orEmpty()

private fun Map<String, Any?>.long(key: String): Long = requireLong(this[key])

private fun Map<String, Any?>.string(key: String): String = requireString(this[key])
