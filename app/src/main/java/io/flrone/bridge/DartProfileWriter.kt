package io.flrone.bridge

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.database.ProxyGroup
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Kotlin -> Dart write bridge for the profiles/groups document (ADR 0005 final
 * stage). Dart is the **only** writer of that document; every catalog mutation
 * — from the UI handlers, the subscription importer, the test runners or a
 * backup restore — funnels through the single `applyDocument` channel method.
 * There is deliberately no second write protocol and no Room mirror: Room's
 * profile/group tables are a migration source only once the document exists.
 *
 * Every method here is a thin row-mapper over [applyDocument]; callers on a
 * synchronous thread wrap the suspend call in `runBlocking` on an IO thread (see
 * ProfileManager/GroupRepo), so the caller's thread is never blocked. The
 * channel invoke itself is `@UiThread` (FlutterJNI), so [call] marshals it onto
 * the main thread with a post — never a wait — and the caller resumes on its own
 * dispatcher when Dart replies. When no Dart engine is attached (JVM tests,
 * bridge mode before attach) the calls return null/empty and the caller keeps
 * its in-memory entity — the write is a no-op rather than a crash, matching the
 * old bridge-mode behaviour.
 */
object DartProfileWriter {

    private const val APPLY = "applyDocument"
    private const val REMIGRATE = "reMigrateFromRoom"

    /** The small ack Dart replies to an apply, never the whole document. */
    data class WriteResult(
        val nextProfileId: Long,
        val nextGroupId: Long,
        /** Client id (negative) -> id Dart assigned, per table. */
        val profileIds: Map<Long, Long>,
        val groupIds: Map<Long, Long>,
    )

    data class MigrationResult(
        val migrated: Boolean,
        val profileCount: Int,
        val groupCount: Int,
    )

    @Volatile
    private var channel: MethodChannel? = null

    /**
     * Calls waiting for a Dart reply, as `fail(exception)` closures. [detach]
     * fails them explicitly: the old implementation only dropped the channel,
     * so a write in flight when the UI engine went away never resumed and its
     * `runBlocking(Dispatchers.IO)` caller parked a thread forever. A closure
     * keeps the cancellation type out of the set's signature.
     */
    private val pending: MutableSet<(Throwable) -> Unit> =
        Collections.newSetFromMap(ConcurrentHashMap<(Throwable) -> Unit, Boolean>())

    fun attach(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, "io.flrone/profiles_doc")
        DartProfileStore.invalidate()
    }

    fun detach() {
        channel = null
        val stuck = synchronized(pending) { pending.toList().also { pending.clear() } }
        for (fail in stuck) {
            fail(IllegalStateException("profiles_doc engine detached"))
        }
    }

    /** True while a Dart engine is attached to receive writes. */
    fun attached(): Boolean = channel != null

    // ---------------------------------------------------------------------------- row mapping

    /** A ProxyEntity as the Room-column-keyed map the Dart document stores. */
    fun profileRow(p: ProxyEntity): Map<String, Any?> = mapOf(
        "id" to p.id,
        "type" to p.type,
        "name" to p.name,
        "gid" to p.groupId,
        "user_order" to p.userOrder,
        "latency" to p.latency,
        "latency_at" to p.latencyAt,
        "dl_speed" to p.dlSpeed,
        "ul_speed" to p.ulSpeed,
        "test_country" to p.testCountry,
        "ip_out" to p.ipOut,
        "outbound_json" to p.outboundJson,
        "traffic_dl" to p.rx,
        "traffic_up" to p.tx,
        "test_error" to p.testError,
    )

    /** A ProxyGroup as the Room-column-keyed map the Dart document stores. */
    fun groupRow(g: ProxyGroup): Map<String, Any?> = mapOf(
        "id" to g.id,
        "archive" to g.archive,
        "skip_auto_update" to g.skipAutoUpdate,
        "name" to g.name,
        "url" to g.url,
        "info" to g.info,
        "sub_last_update" to g.subLastUpdate,
        "front_proxy_id" to g.frontProxyId,
        "landing_proxy_id" to g.landingProxyId,
        "column_width_json" to g.columnWidthJson,
        "scroll_last_profile" to g.scrollLastProfile,
        "auto_clear_unavailable" to g.autoClearUnavailable,
        "test_sort_by" to g.testSortBy,
        "traffic_sort_by" to g.trafficSortBy,
        "test_items_to_show" to g.testItemsToShow,
        "type_sort_by" to g.typeSortBy,
        "sub_options_json" to g.subOptions.toJsonString(),
        "sub_metadata_json" to g.subMetadata.toJsonString(),
        "sort_method" to g.sortMethod,
        "sort_descending" to g.sortDescending,
        "display_order" to g.displayOrder,
        "route_id" to g.routeId,
        "import_sub_route" to g.importSubRoute,
    )

    // ---------------------------------------------------------------------------- low level

    /**
     * The one and only write request. A single document edit may combine a
     * replace, deletes, row upserts, per-column patches and a reorder; Dart runs
     * them in order against its one in-memory copy and persists atomically.
     *
     * Returns the ack Dart wrote back, or null when no engine is attached.
     */
    suspend fun applyDocument(
        profiles: List<Map<String, Any?>> = emptyList(),
        groups: List<Map<String, Any?>> = emptyList(),
        replaceAll: Boolean = false,
        nextProfileId: Long? = null,
        nextGroupId: Long? = null,
        deleteProfileIds: Collection<Long> = emptyList(),
        deleteGroupIds: Collection<Long> = emptyList(),
        profilePatches: Map<Long, Map<String, Any?>> = emptyMap(),
        groupPatches: Map<Long, Map<String, Any?>> = emptyMap(),
        allocateIds: Boolean = false,
        reorderGroupId: Long? = null,
        reorderProfileIds: Collection<Long>? = null,
        reorderGroups: Boolean = false,
        trafficDeltas: Map<Long, Pair<Long, Long>> = emptyMap(),
    ): WriteResult? {
        val ch = channel ?: return null
        // Plain Map/List, not JSONObject: MethodChannel uses StandardMethodCodec,
        // which only accepts the codec's own primitives/maps/lists. Nulls are
        // legal map values here and mean "clear this Room column" on the Dart
        // side (Dart's normalizePlatformValue keeps them).
        val args = HashMap<String, Any?>().apply {
            put("replaceAll", replaceAll)
            put("profiles", profiles)
            put("groups", groups)
            put("deleteProfileIds", deleteProfileIds.toList())
            put("deleteGroupIds", deleteGroupIds.toList())
            put("allocateIds", allocateIds)
            if (profilePatches.isNotEmpty()) {
                put("profilePatches", profilePatches.mapKeys { (id, _) -> id.toString() })
            }
            if (groupPatches.isNotEmpty()) {
                put("groupPatches", groupPatches.mapKeys { (id, _) -> id.toString() })
            }
            if (reorderGroupId != null && reorderProfileIds != null) {
                put("reorderGroupId", reorderGroupId)
                put("reorderProfileIds", reorderProfileIds.toList())
            }
            if (reorderGroups) put("reorderGroups", true)
            if (trafficDeltas.isNotEmpty()) {
                put("trafficDeltas", trafficDeltas.mapValues { (_, delta) ->
                    listOf(delta.first, delta.second)
                })
            }
            if (nextProfileId != null) put("nextProfileId", nextProfileId)
            if (nextGroupId != null) put("nextGroupId", nextGroupId)
        }
        val raw = call<Map<*, *>>(APPLY, args) ?: return null
        // The document changed under Kotlin's read cache. Its mtime+length key
        // usually notices, but an equal-length edit inside the same millisecond
        // (rename a node to another name of the same length) does not: the next
        // read would answer the pre-write row, so a saved node looked like it
        // had not persisted. Invalidate explicitly; the next read re-parses.
        DartProfileStore.invalidate()
        return WriteResult(
            nextProfileId = (raw["nextProfileId"] as? Number)?.toLong() ?: 0L,
            nextGroupId = (raw["nextGroupId"] as? Number)?.toLong() ?: 0L,
            profileIds = idMap(raw["profileIds"]),
            groupIds = idMap(raw["groupIds"]),
        )
    }

    /** Asks Dart to rebuild a missing/corrupt document from Room (explicit recovery only). */
    suspend fun reMigrateFromRoom(): MigrationResult? {
        if (channel == null) return null
        val raw = call<Map<*, *>>(REMIGRATE, emptyMap<String, Any?>()) ?: return null
        DartProfileStore.invalidate()
        return MigrationResult(
            migrated = raw["migrated"] == true,
            profileCount = (raw["profileCount"] as? Number)?.toInt() ?: 0,
            groupCount = (raw["groupCount"] as? Number)?.toInt() ?: 0,
        )
    }

    // ---------------------------------------------------------------------------- typed writes

    /**
     * Inserts [profiles] as new rows in [gid], assigning them dense user_order
     * positions after the current members. Because Dart owns the id counter the
     * rows are sent with a temporary negative id and the real id is written back
     * into the entities from the ack. No-op (with the entities left untouched)
     * when no engine is attached.
     */
    suspend fun addProfiles(profiles: List<ProxyEntity>, gid: Long): List<ProxyEntity> {
        if (profiles.isEmpty() || channel == null) return profiles
        val existing = DartProfileStore.memberIds(gid)
        // Distinct temporary ids: -1, -2, ... preserved through the JSON round trip.
        var temp = -1L
        val rows = ArrayList<Map<String, Any?>>(profiles.size)
        profiles.forEachIndexed { index, p ->
            p.id = temp--
            p.groupId = gid
            p.userOrder = (existing.size + index).toLong()
            rows.add(profileRow(p))
        }
        val originalIds = profiles.map { it.id }
        val ack = try {
            applyDocument(profiles = rows, allocateIds = true)
        } catch (cancelled: CancellationException) {
            // Cancelled between the post and the reply: restore the caller's ids
            // so no negative temporary id escapes into an in-memory entity.
            profiles.forEachIndexed { i, p -> p.id = originalIds[i] }
            return profiles
        }
        if (ack == null) {
            // The engine detached mid-call: restore the caller's ids so no
            // negative temporary id escapes into an in-memory entity.
            profiles.forEachIndexed { i, p -> p.id = originalIds[i] }
            return profiles
        }
        val ids = ack.profileIds
        for (p in profiles) {
            ids[p.id]?.let { p.id = it }
        }
        return profiles
    }

    /**
     * Inserts groups with a temporary negative id (Dart assigns the real one),
     * writing the assigned id back into each entity. No-op when no engine is
     * attached (the caller keeps its temporary id in bridge mode).
     */
    suspend fun addGroups(groups: List<ProxyGroup>): List<ProxyGroup> {
        if (groups.isEmpty() || channel == null) return groups
        var temp = -1L
        val rows = ArrayList<Map<String, Any?>>(groups.size)
        for (g in groups) {
            g.id = temp--
            rows.add(groupRow(g))
        }
        val originalIds = groups.map { it.id }
        val ack = try {
            applyDocument(groups = rows, allocateIds = true)
        } catch (cancelled: CancellationException) {
            groups.forEachIndexed { i, g -> g.id = originalIds[i] }
            return groups
        }
        if (ack == null) {
            groups.forEachIndexed { i, g -> g.id = originalIds[i] }
            return groups
        }
        val ids = ack.groupIds
        for (g in groups) {
            ids[g.id]?.let { g.id = it }
        }
        return groups
    }

    /** Whole-row replacement (type, data, test results, traffic) by id. */
    suspend fun updateProfiles(profiles: Collection<ProxyEntity>) {
        if (profiles.isEmpty()) return
        applyDocument(profiles = profiles.map(::profileRow))
    }

    /** Whole-row replacement of groups by id. */
    suspend fun updateGroups(groups: Collection<ProxyGroup>) {
        if (groups.isEmpty()) return
        applyDocument(groups = groups.map(::groupRow))
    }

    /** Per-column updates; absent keys are left untouched by Dart. */
    suspend fun patchProfiles(patches: Map<Long, Map<String, Any?>>) {
        if (patches.isEmpty()) return
        applyDocument(profilePatches = patches)
    }

    suspend fun patchGroups(patches: Map<Long, Map<String, Any?>>) {
        if (patches.isEmpty()) return
        applyDocument(groupPatches = patches)
    }

    /** Atomically credits traffic deltas (rx, tx) in the Dart document. */
    suspend fun addTraffic(deltas: Map<Long, Pair<Long, Long>>) {
        if (deltas.isEmpty()) return
        applyDocument(trafficDeltas = deltas)
    }

    suspend fun deleteProfiles(ids: Collection<Long>) {
        if (ids.isEmpty()) return
        applyDocument(deleteProfileIds = ids)
    }

    suspend fun deleteGroups(ids: Collection<Long>) {
        if (ids.isEmpty()) return
        applyDocument(deleteGroupIds = ids)
    }

    suspend fun reorderGroup(gid: Long, ids: List<Long>) {
        applyDocument(reorderGroupId = gid, reorderProfileIds = ids)
    }

    /** Reorders groups by displayOrder to the given id sequence. Dart shifts the
     *  remaining groups after the listed ones, so only the target order crosses
     *  the boundary. */
    suspend fun reorderGroups(ids: List<Long>) {
        // Piggyback the desired order in the `reorderProfileIds` slot would be
        // wrong; instead send the full ordered rows so Dart's replace-by-id
        // updates displayOrder directly. All rows come from the live document.
        val ordered = ids.mapNotNull { DartProfileStore.group(it) }
        if (ordered.isEmpty()) return
        applyDocument(
            groups = ordered.mapIndexed { index, g ->
                val row = groupRow(g).toMutableMap()
                row["display_order"] = index.toLong()
                row
            },
        )
    }

    /** Full replacement (used by a backup restore that rewrites both tables). */
    suspend fun replaceAll(
        profiles: List<ProxyEntity>,
        groups: List<ProxyGroup>,
        nextProfileId: Long,
        nextGroupId: Long,
    ) {
        applyDocument(
            profiles = profiles.map(::profileRow),
            groups = groups.map(::groupRow),
            replaceAll = true,
            nextProfileId = nextProfileId,
            nextGroupId = nextGroupId,
        )
    }

    // ---------------------------------------------------------------------------- channel plumbing

    /**
     * Thread the write's platform message is invoked on.
     *
     * `MethodChannel.invokeMethod` is `@UiThread`: FlutterJNI.dispatchPlatformMessage
     * asserts the main looper and throws
     *
     *     Methods marked with @UiThread must be executed on the main thread.
     *     Current thread: DefaultDispatcher-worker-5
     *
     * The profile writers run on IO workers (GroupSort's queue, saveTestResult,
     * a subscription refresh), which is exactly where that exception came from:
     * node imports and test results were lost with it. Writes now marshal onto
     * the main thread (a post, never a blocking wait) while the caller keeps
     * suspending on its own dispatcher.
     *
     * Injectable so a JVM test can exercise both branches without a Looper.
     */
    @Volatile
    internal var isMainThread: () -> Boolean = {
        runCatching { Looper.myLooper() == Looper.getMainLooper() }.getOrDefault(true)
    }

    /** Posts [runnable] to the main looper; false when there is no main looper (JVM tests). */
    @Volatile
    internal var postToMain: (Runnable) -> Boolean = { runnable ->
        runCatching { Handler(Looper.getMainLooper()).post(runnable) }.getOrDefault(false)
    }

    /** Dart serialises the id maps with string keys; decode either representation. */
    private fun idMap(value: Any?): Map<Long, Long> {
        if (value !is Map<*, *>) return emptyMap()
        val out = HashMap<Long, Long>()
        value.forEach { (key, v) ->
            val client = (key as? Number)?.toLong() ?: key.toString().toLongOrNull() ?: return@forEach
            val real = (v as? Number)?.toLong() ?: return@forEach
            out[client] = real
        }
        return out
    }

    private suspend fun <T> call(method: String, args: Any?): T? =
        suspendCancellableCoroutine { cont ->
            val ch = channel
            if (ch == null) {
                cont.resume(null)
                return@suspendCancellableCoroutine
            }
            val fail: (Throwable) -> Unit = { error -> cont.resumeWithException(error) }
            pending.add(fail)
            fun settle() {
                pending.remove(fail)
            }
            cont.invokeOnCancellation { settle() }
            dispatchToMain(isMainThread(), postToMain) {
                if (!cont.isActive) {
                    settle()
                    return@dispatchToMain
                }
                // The engine may have been replaced between the channel read and
                // the main-thread post. Calling the old messenger would throw on
                // a destroyed engine and the caller would wait forever.
                if (channel !== ch) {
                    settle()
                    cont.resume(null)
                    return@dispatchToMain
                }
                runCatching {
                    ch.invokeMethod(method, args, object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            settle()
                            @Suppress("UNCHECKED_CAST")
                            cont.resume(result as T?)
                        }

                        override fun error(code: String, message: String?, details: Any?) {
                            settle()
                            cont.resumeWithException(
                                IllegalStateException("profiles_doc.$method: $code ${message.orEmpty()}")
                            )
                        }

                        override fun notImplemented() {
                            settle()
                            cont.resume(null)
                        }
                    })
                }.onFailure { failure ->
                    settle()
                    cont.resumeWithException(failure)
                }
            }
        }
}

/**
 * Runs [block] on the main thread: inline when already there, otherwise through
 * [post]; a [post] that cannot reach a main looper (JVM tests, a detached
 * engine) runs the block in place rather than losing the write.
 *
 * Top-level on purpose: it has no Android dependency, so a plain JVM test can
 * drive every branch without loading [DartProfileWriter] (whose default hooks
 * mention `Looper`/`Handler`, which the mockable android.jar cannot execute).
 */
internal inline fun dispatchToMain(
    isMain: Boolean,
    post: (Runnable) -> Boolean,
    crossinline block: () -> Unit,
) {
    if (isMain) {
        block()
    } else if (!post(Runnable { block() })) {
        block()
    }
}
