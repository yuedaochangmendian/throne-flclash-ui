package io.flrone.bridge

import io.nekohasekai.sagernet.database.RouteManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The method-channel action table (ADR 0002, phase 3b-2).
 *
 * `ThroneBoxBridge.onMethodCall` used to hold every data-plane handler inline as a
 * 136-arm `when`. This object keeps the handlers in one registry keyed by the same
 * dotted names, so the bridge only has to forward: `BboxActions.invoke(name, args)`.
 *
 * Two things follow from that, and both are the reason for the change:
 *
 *  * the wire contract becomes one table instead of one giant expression, which is
 *    what makes the eventual move to the Go action dispatcher a matter of supplying
 *    a different implementation rather than rewriting the bridge;
 *  * a handler can be registered per domain, so `routes.*` (this phase) can move
 *    while every other name still falls through to the bridge's own arms.
 *
 * Returning [Unhandled] rather than throwing is deliberate: the bridge falls back to
 * its existing arms for anything not in the table, so the migration is incremental
 * and a name added to one side cannot break the other.
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

    // --- routes ---------------------------------------------------------------
    //
    // Every handler here is a thin adapter: the payload shapes are the ones the
    // Dart side already sends, and the work stays in BboxRoutes (which now reads
    // the JSON documents through RouteManager).

    init {
        register("routes.list") { BboxRoutes.list() }
        register("routes.get") { args -> BboxRoutes.get(args.long("id")) }
        register("routes.save") { args ->
            @Suppress("UNCHECKED_CAST")
            BboxRoutes.save(args["value"] as? Map<String, Any?> ?: args)
        }
        register("routes.delete") {
            BboxRoutes.delete(it.long("id"))
            null
        }
        register("routes.setCurrent") { args -> BboxRoutes.setCurrent(args.long("id")) }
        register("routes.presets") { BboxRoutes.presets() }
        register("routes.addPreset") { args ->
            BboxRoutes.addPreset(
                args.string("country"),
                args["autoUpdate"] != false,
            )
        }
        register("routes.rules") { args -> BboxRoutes.rules(args.long("id")) }
        register("routes.saveRules") { args ->
            BboxRoutes.saveRules(args.long("id"), args.ruleList("rules"))
        }
        register("routes.globalRules") { args -> BboxRoutes.globalRules(args.long("profileId")) }
        register("routes.saveGlobalRules") { args ->
            BboxRoutes.saveGlobalRules(args.ruleList("rules"))
        }
        register("routes.setGlobalRuleDisabled") { args ->
            BboxRoutes.setGlobalRuleDisabled(
                args.long("profileId"),
                args.idList("ids"),
            )
        }
        register("routes.deleteGlobalRule") {
            BboxRoutes.deleteGlobalRule(it.long("id"))
            null
        }
        register("routes.batchAddRules") { args ->
            BboxRoutes.batchAddRules(args.long("id"), args.string("text"))
        }
        register("routes.resetRules") { args -> BboxRoutes.resetRules(args.long("id")) }
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
// The channel hands numbers over as Int/Double/Long depending on the platform
// codec, so a plain `as Long` cast is the kind of bug that only shows on one
// device. These helpers normalize once, here.

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

private fun Map<String, Any?>.ruleList(key: String): List<Map<String, Any?>> =
    (this[key] as? List<*>).orEmpty().mapNotNull { item ->
        @Suppress("UNCHECKED_CAST")
        item as? Map<String, Any?>
    }

private fun Map<String, Any?>.idList(key: String): List<Long> =
    (this[key] as? List<*>).orEmpty().mapNotNull { (it as? Number)?.toLong() }
