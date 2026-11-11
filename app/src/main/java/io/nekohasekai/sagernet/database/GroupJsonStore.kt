package io.nekohasekai.sagernet.database

import io.nekohasekai.sagernet.outbound.json.JsonInput
import org.json.JSONObject
import java.io.File

/**
 * A READ-ONLY view of the group documents the kernel owns (ADR 0002, phase 3d).
 *
 * Same pattern as [RouteJsonStore] and [ProfileJsonStore]: Go writes, Kotlin reads.
 * The row shape is Room's `groups` table columns verbatim.
 *
 * There are deliberately NO write methods here. If a write is ever needed on this side it
 * goes through the action bus to the kernel, not through a second file writer.
 *
 * A missing or unparseable document answers null so every caller falls back to Room.
 */
object GroupJsonStore {

    private const val GROUPS = "groups"

    /** Where the documents live; the host sets it once the kernel base path is known. */
    @Volatile
    var directory: File? = null

    /**
     * Diagnostics sink. Injected rather than calling android.util.Log directly: the JVM
     * unit tests exercise the corrupt-file path, and an unmocked Log.w would fail them for
     * a reason that has nothing to do with the behaviour under test.
     */
    @Volatile
    var logger: (String, Throwable?) -> Unit = { message, error ->
        if (error != null) {
            io.nekohasekai.sagernet.ktx.Logs.w(message, error)
        } else {
            io.nekohasekai.sagernet.ktx.Logs.w(message)
        }
    }

    /** True when the kernel has written the document set. */
    val ready: Boolean
        get() {
            val dir = directory ?: return false
            return File(dir, "$GROUPS.json").isFile
        }

    /** All groups sorted by display_order then id, matching `ProxyGroup.Dao.allGroups()`. */
    fun all(): List<ProxyGroup>? = readRows(GROUPS)
        ?.mapNotNull(::rowToEntity)
        ?.sortedWith(compareBy({ it.displayOrder }, { it.id }))

    fun getById(id: Long): ProxyGroup? = all()?.firstOrNull { it.id == id }

    fun count(): Long = all()?.size?.toLong() ?: 0L

    fun allIds(): List<Long> = all()?.map { it.id }?.sorted().orEmpty()

    // --- row -> entity ----------------------------------------------------------

    /**
     * Column mapping is the full ProxyGroup @ColumnInfo set. Every column must appear here;
     * a missing one silently loses data on round-trip. The field names follow
     * `ProxyGroup.kt` exactly — check both files together when adding a column.
     */
    private fun rowToEntity(row: JSONObject) = ProxyGroup().apply {
        id = row.optLong("id")
        archive = row.optInt("archive") != 0
        skipAutoUpdate = row.optInt("skip_auto_update") != 0
        name = row.optString("name")
        url = row.optString("url")
        info = row.optString("info")
        subLastUpdate = row.optLong("sub_last_update", 0L)
        frontProxyId = row.optLong("front_proxy_id", -1L)
        landingProxyId = row.optLong("landing_proxy_id", -1L)
        columnWidthJson = row.optString("column_width_json")
        scrollLastProfile = row.optInt("scroll_last_profile", -1)
        autoClearUnavailable = row.optInt("auto_clear_unavailable") != 0
        testSortBy = row.optInt("test_sort_by", 0)
        trafficSortBy = row.optInt("traffic_sort_by", 0)
        testItemsToShow = row.optInt("test_items_to_show", 0)
        typeSortBy = row.optInt("type_sort_by", 0)
        subOptions = SubscriptionOptions.fromJson(JsonInput.parseObject(row.optString("sub_options_json", "{}")))
        subMetadata = SubUserInfo.fromJson(JsonInput.parseObject(row.optString("sub_metadata_json", "{}")))
        sortMethod = row.optInt("sort_method", 0)
        sortDescending = row.optInt("sort_descending") != 0
        displayOrder = row.optLong("display_order", 0L)
        routeId = row.optLong("route_id", -1L)
        importSubRoute = row.optInt("import_sub_route") != 0
    }

    /** Rows of one document, or null when it is absent/unreadable (caller falls back). */
    private fun readRows(name: String): List<JSONObject>? {
        val dir = directory ?: return null
        val file = File(dir, "$name.json")
        if (!file.isFile) return null
        return try {
            val root = JSONObject(file.readText())
            val rows = root.optJSONArray("rows") ?: return null
            buildList { for (i in 0 until rows.length()) rows.optJSONObject(i)?.let { add(it) } }
        } catch (e: Exception) {
            logger("unreadable $name.json; falling back to Room", e)
            null
        }
    }
}
