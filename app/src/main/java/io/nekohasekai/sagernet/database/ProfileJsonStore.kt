package io.nekohasekai.sagernet.database

import org.json.JSONObject
import java.io.File

/**
 * A READ-ONLY view of the profile documents the kernel owns (ADR 0002, phase 3d).
 *
 * Same pattern as [RouteJsonStore]: Go writes, Kotlin reads. The row shape is Room's
 * `profiles` table columns verbatim, so a reader that switches from Room to this view sees
 * identical values.
 *
 * There are deliberately NO write methods here. If a write is ever needed on this side it
 * goes through the action bus to the kernel, not through a second file writer.
 *
 * A missing or unparseable document answers null so every caller falls back to Room. That is
 * the property that makes the switch safe: it can skip itself, it cannot lose data.
 */
object ProfileJsonStore {

    private const val PROFILES = "profiles"

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
            return File(dir, "$PROFILES.json").isFile
        }

    fun all(): List<ProxyEntity>? = readRows(PROFILES)?.mapNotNull(::rowToEntity)

    fun getById(id: Long): ProxyEntity? = all()?.firstOrNull { it.id == id }

    fun byGroup(groupId: Long): List<ProxyEntity> =
        all()?.filter { it.groupId == groupId }?.sortedBy { it.userOrder }.orEmpty()

    fun count(): Long = all()?.size?.toLong() ?: 0L

    fun allIds(): List<Long> = all()?.map { it.id }?.sorted().orEmpty()

    // --- row -> entity ----------------------------------------------------------

    /**
     * Column mapping is the full ProxyEntity @ColumnInfo set. Every column must appear here;
     * a missing one silently loses data on round-trip. The field names follow
     * `ProxyEntity.kt` exactly — check both files together when adding a column.
     */
    private fun rowToEntity(row: JSONObject) = ProxyEntity().apply {
        id = row.optLong("id")
        type = row.optString("type")
        name = row.optString("name").ifEmpty { null }
        groupId = row.optLong("gid", 0L)
        userOrder = row.optLong("user_order", 0L)
        latency = row.optInt("latency", 0)
        latencyAt = row.optLong("latency_at", 0L)
        dlSpeed = row.optString("dl_speed").ifEmpty { null }
        ulSpeed = row.optString("ul_speed").ifEmpty { null }
        testCountry = row.optString("test_country").ifEmpty { null }
        ipOut = row.optString("ip_out").ifEmpty { null }
        outboundJson = row.optString("outbound_json")
        rx = row.optLong("traffic_dl", 0L)
        tx = row.optLong("traffic_up", 0L)
        testError = row.optString("test_error").ifEmpty { null }
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
