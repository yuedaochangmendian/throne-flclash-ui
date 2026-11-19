package io.flrone.bridge

import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.database.ProxyGroup
import io.nekohasekai.sagernet.database.SubUserInfo
import io.nekohasekai.sagernet.database.SubscriptionOptions
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Read-only Kotlin view of the Dart-owned `profiles.json` document (ADR 0005
 * final stage).
 *
 * Dart is the storage authority for profiles and groups. This object is the
 * Kotlin *reader* that `ConfigGenerator` / `CoreConfigs` / `BboxKernel` use to
 * build `ProxyEntity` / `ProxyGroup` synchronously — those paths cannot call
 * back into Dart, so they read the same file Dart writes. It never writes the
 * document: every mutation crosses the `io.flrone/profiles_doc` channel to
 * Dart (see BboxProfiles / the parse-only handlers).
 *
 * The document is the Room profile/group tables re-typed as JSON with the exact
 * column names, so mapping here is a straight field copy (no second naming
 * layer to drift). The envelope also carries `nextProfileId` / `nextGroupId`
 * so an id Kotlin allocates (a new node before its link is known) cannot
 * collide with one Dart will hand out.
 *
 * After the one-time migration this file is the ONLY source for profiles and
 * groups; there is no Room fallback. If it is missing or corrupt the getters
 * throw [ProfilesDocumentUnavailable] with a clear message — silently reading
 * stale Room rows would hide a failed migration and lose writes. Recovery is
 * explicit: Dart's `reMigrateFromRoom` channel method rebuilds a broken/absent
 * document from Room (which is kept read-only as the migration source). Room
 * still owns settings/routes and is never written here.
 *
 * Parsed rows are cached by file mtime+length (like RouteJsonStore), because
 * buildStartOptions and the catalog can read the same snapshot many times in a
 * second. A Dart write changes both, so the next read re-parses.
 */

/** Thrown when the document Dart owns is absent or unreadable — there is no
 * silent Room fallback; the caller must surface a clear error and (optionally)
 * ask Dart to re-migrate from Room. */
class ProfilesDocumentUnavailable(message: String, cause: Throwable? = null) :
    IllegalStateException(message, cause)
object DartProfileStore {

    private const val FILE_NAME = "profiles.json"
    private const val VERSION = 1

    /** The documents directory; the host sets it at attach from `data.path`. */
    @Volatile
    var directory: File? = null
        set(value) {
            field = value
            synchronized(cacheLock) { cached = null }
        }

    /** Diagnostics sink, injectable so JVM tests can exercise the corrupt path. */
    @Volatile
    var logger: (String, Throwable?) -> Unit = { message, error ->
        if (error != null) {
            io.nekohasekai.sagernet.ktx.Logs.w(message, error)
        } else {
            io.nekohasekai.sagernet.ktx.Logs.w(message)
        }
    }

    private class Snapshot(
        val stamp: Long,
        val profiles: List<ProxyEntity>,
        val groups: List<ProxyGroup>,
        val nextProfileId: Long,
        val nextGroupId: Long,
    )

    private val cacheLock = Any()
    private var cached: Snapshot? = null

    private fun file(): File? = directory?.let { File(it, FILE_NAME) }

    /**
     * True only when the document exists **and parses**. A missing/corrupt file
     * makes this false; callers then throw [ProfilesDocumentUnavailable] rather
     * than silently reading stale Room rows.
     */
    fun available(): Boolean = snapshot() != null

    /**
     * Whether the handover happened: the document file exists on disk. Unlike
     * [available] this is true even for a corrupt file, which is the signal to
     * callers that Room must NOT be used as a silent fallback — the read goes
     * through this object and throws [ProfilesDocumentUnavailable] instead.
     * False only before the one-time migration (file genuinely absent).
     */
    fun documentExists(): Boolean = file()?.isFile == true

    /** The reason [available] is false, for diagnostics and UI error messages. */
    fun unavailableReason(): String {
        val file = file()
        return when {
            directory == null -> "profiles document directory is not set"
            file == null || !file.isFile -> "profiles.json is missing (migration has not run)"
            else -> "profiles.json is unreadable or corrupt"
        }
    }

    /** The parsed snapshot, or null when the document is absent/corrupt. */
    private fun snapshot(): Snapshot? {
        val file = file()
        if (file == null || !file.isFile) return null
        synchronized(cacheLock) {
            // The stamp belongs inside the lock: computing it before the lock
            // lets a reader that lost the race cache a snapshot under the
            // pre-write stamp, so a same-millisecond, equal-length edit would
            // keep answering the old rows even after invalidate().
            val stamp = file.lastModified() * 31 + file.length()
            val hit = cached
            if (hit != null && hit.stamp == stamp) return hit
            val parsed = try {
                parse(file.readText(), stamp)
            } catch (e: Exception) {
                logger("unreadable profiles.json; catalog/config will report it as unavailable", e)
                return null
            }
            cached = parsed
            return parsed
        }
    }

    private fun parse(text: String, stamp: Long): Snapshot? {
        val root = JSONObject(text)
        if (root.optInt("version", -1) != VERSION) {
            logger("unsupported profiles.json version ${root.optInt("version")}", null)
            return null
        }
        val profiles = root.optJSONArray("profiles")?.mapProfiles().orEmpty()
        val groups = root.optJSONArray("groups")?.mapGroups().orEmpty()
        val maxProfile = profiles.maxOfOrNull { it.id } ?: 0L
        val maxGroup = groups.maxOfOrNull { it.id } ?: 0L
        return Snapshot(
            stamp = stamp,
            profiles = profiles,
            groups = groups,
            nextProfileId = maxOf(root.optLong("nextProfileId", maxProfile + 1), maxProfile + 1),
            nextGroupId = maxOf(root.optLong("nextGroupId", maxGroup + 1), maxGroup + 1),
        )
    }

    // --- row mapping: JSON column name -> entity field ---------------------

    internal fun profileOf(obj: JSONObject): ProxyEntity? {
        val id = obj.optLong("id", 0L).takeIf { it > 0L } ?: return null
        return ProxyEntity(
            id = id,
            type = obj.optString("type"),
            name = obj.optStringOrNull("name"),
            groupId = obj.optLong("gid", 0L),
            userOrder = obj.optLong("user_order", 0L),
            latency = obj.optInt("latency", 0),
            latencyAt = obj.optLong("latency_at", 0L),
            dlSpeed = obj.optStringOrNull("dl_speed"),
            ulSpeed = obj.optStringOrNull("ul_speed"),
            testCountry = obj.optStringOrNull("test_country"),
            ipOut = obj.optStringOrNull("ip_out"),
            outboundJson = obj.optString("outbound_json"),
            rx = obj.optLong("traffic_dl", 0L),
            tx = obj.optLong("traffic_up", 0L),
            testError = obj.optStringOrNull("test_error"),
        )
    }

    internal fun groupOf(obj: JSONObject): ProxyGroup? {
        val id = obj.optLong("id", 0L).takeIf { it > 0L } ?: return null
        val group = ProxyGroup(
            id = id,
            archive = obj.optBoolean("archive", false),
            skipAutoUpdate = obj.optBoolean("skip_auto_update", false),
            name = obj.optString("name"),
            url = obj.optString("url"),
            info = obj.optString("info"),
            subLastUpdate = obj.optLong("sub_last_update", 0L),
            frontProxyId = obj.optLong("front_proxy_id", -1L),
            landingProxyId = obj.optLong("landing_proxy_id", -1L),
            columnWidthJson = obj.optString("column_width_json"),
            scrollLastProfile = obj.optInt("scroll_last_profile", -1),
            autoClearUnavailable = obj.optBoolean("auto_clear_unavailable", false),
            testSortBy = obj.optInt("test_sort_by", 0),
            trafficSortBy = obj.optInt("traffic_sort_by", 0),
            testItemsToShow = obj.optInt("test_items_to_show", 0),
            typeSortBy = obj.optInt("type_sort_by", 0),
            sortMethod = obj.optInt("sort_method", 0),
            sortDescending = obj.optBoolean("sort_descending", false),
            displayOrder = obj.optLong("display_order", 0L),
            routeId = obj.optLong("route_id", -1L),
            importSubRoute = obj.optBoolean("import_sub_route", false),
        )
        // The two opaque codecs stay in Kotlin, which owns their model. A column
        // written before the typed JSON existed is skipped, giving the codec's
        // own defaults (both parse() handle blank/null as "empty").
        val subOptions = obj.optString("sub_options_json", "")
        if (subOptions.isNotEmpty()) group.subOptions = SubscriptionOptions.parse(subOptions)
        val subMetadata = obj.optString("sub_metadata_json", "")
        if (subMetadata.isNotEmpty()) group.subMetadata = SubUserInfo.parse(subMetadata)
        return group
    }

    // --- public read API ---------------------------------------------------

    /** The live snapshot, or a throw with a clear message. No Room fallback. */
    private fun requireSnapshot(): Snapshot =
        snapshot() ?: throw ProfilesDocumentUnavailable(unavailableReason())

    /** Every profile from the Dart-owned document. */
    fun profiles(): List<ProxyEntity> = requireSnapshot().profiles

    /** Every group in tab order from the Dart-owned document. */
    fun groups(): List<ProxyGroup> = requireSnapshot().groups.sortedBy { it.displayOrder }

    /** One profile by id, or null when absent. */
    fun profile(id: Long): ProxyEntity? {
        if (id <= 0L) return null
        return requireSnapshot().profiles.firstOrNull { it.id == id }
    }

    /** One group by id, or null when absent. */
    fun group(id: Long): ProxyGroup? {
        if (id <= 0L) return null
        return requireSnapshot().groups.firstOrNull { it.id == id }
    }

    /** Profiles of a group in list order (user_order, id). */
    fun members(groupId: Long): List<ProxyEntity> =
        profiles().filter { it.groupId == groupId }
            .sortedWith(compareBy<ProxyEntity>({ it.userOrder }, { it.id }))

    /** Member ids of a group in list order. */
    fun memberIds(groupId: Long): List<Long> = members(groupId).map { it.id }

    /** Profiles by id, in the order requested (skipping missing ones). */
    fun profiles(ids: Collection<Long>): List<ProxyEntity> {
        if (ids.isEmpty()) return emptyList()
        val wanted = ids.toSet()
        return profiles().filter { it.id in wanted }
    }

    /** The id Dart will hand out for the next profile, from the document counters. */
    fun nextProfileId(): Long = requireSnapshot().nextProfileId

    // --- test / diagnostics ------------------------------------------------

    /** Forgets the cached snapshot. Tests call this; a production write changes
     * the file stamp so the cache self-invalidates. */
    fun invalidate() {
        synchronized(cacheLock) { cached = null }
    }
}

private fun JSONArray.mapProfiles(): List<ProxyEntity> {
    val out = ArrayList<ProxyEntity>(length())
    for (i in 0 until length()) {
        val obj = optJSONObject(i) ?: continue
        DartProfileStore.profileOf(obj)?.let(out::add)
    }
    return out
}

private fun JSONArray.mapGroups(): List<ProxyGroup> {
    val out = ArrayList<ProxyGroup>(length())
    for (i in 0 until length()) {
        val obj = optJSONObject(i) ?: continue
        DartProfileStore.groupOf(obj)?.let(out::add)
    }
    return out
}

/** JSONObject.NULL and an absent key both mean "no value" for a nullable column. */
private fun JSONObject.optStringOrNull(key: String): String? {
    if (isNull(key)) return null
    val value = opt(key) ?: return null
    val text = value.toString()
    return text.ifEmpty { null }
}
