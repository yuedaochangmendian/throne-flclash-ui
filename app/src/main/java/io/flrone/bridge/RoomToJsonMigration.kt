package io.flrone.bridge

import android.database.Cursor
import android.util.Base64
import androidx.sqlite.db.SupportSQLiteDatabase
import io.nekohasekai.sagernet.database.SagerDatabase
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * One-time seed of the kernel's route documents from Room (ADR 0002, phase 3c).
 *
 * From phase 3c the Go kernel is the only writer of `route_profiles.json` and
 * `route_rules.json`; Android keeps a read-only view (`RouteJsonStore`) because
 * `ConfigGenerator` needs a synchronous answer and cannot call into Go.
 *
 * This is the hand-over, not a sync: it runs once, only when the documents do not exist, and
 * it copies each table by column name so ids, rule order, JSON blobs and nulls survive
 * verbatim. Old-version compatibility is deliberately dropped — there is no round-trip back
 * into Room, and no merge on later launches.
 */
object RoomToJsonMigration {

    /** The route tables the kernel owns. Profiles and groups stay in Room: the kernel
     * reads and writes that database directly over SQLite (see room_db.go), so no
     * document seed is needed for them. */
    private val tables = listOf("route_profiles", "route_rules", "global_route_rules")

    /**
     * Writes [tables] into [dir] when it is empty. Returns false when the seed had already
     * run, so a caller cannot accidentally overwrite the kernel's live documents.
     */
    fun seed(dir: File): Boolean {
        val marker = File(dir, "route_profiles.json")
        if (marker.isFile) return false
        // Opening through Room first (rather than the raw handle) forces any pending
        // migration to run, so the columns read here are the ones the entities expect.
        val db = SagerDatabase.instance.openHelper.readableDatabase
        if (!dir.isDirectory && !dir.mkdirs()) return false
        for (table in tables) {
            val file = File(dir, "$table.json")
            if (file.isFile) continue
            val payload = JSONObject().apply {
                put("version", 1)
                put("name", table)
                put("rows", dumpTable(db, table))
            }.toString()
            val temp = File(dir, "$table.json.${System.nanoTime()}.tmp")
            temp.writeText(payload)
            if (!temp.renameTo(file)) {
                file.writeText(payload)
                temp.delete()
            }
        }
        return true
    }

    /**
     * Seeds the UI documents from SharedPreferences (ADR 0002, phase 3e). Per-file skip:
     * an upgrade from a routes-seeded build adds just the new docs. Returns true when
     * at least one document was written.
     */
    fun seedUiDocuments(dir: File, settingsJson: String?, preferencesJson: String?): Boolean {
        if (!dir.isDirectory && !dir.mkdirs()) return false
        var seeded = false
        // ui_settings.json: the shell overlay layer.
        val uiFile = File(dir, "ui_settings.json")
        if (!uiFile.isFile && settingsJson != null) {
            val payload = JSONObject().apply {
                put("version", 1)
                put("name", "ui_settings")
                put("rows", JSONObject(settingsJson))
            }.toString()
            val temp = File(dir, "ui_settings.json.${System.nanoTime()}.tmp")
            temp.writeText(payload)
            if (!temp.renameTo(uiFile)) {
                uiFile.writeText(payload)
                temp.delete()
            }
            seeded = true
        }
        // preferences.json: UI preferences.
        val prefFile = File(dir, "preferences.json")
        if (!prefFile.isFile && preferencesJson != null) {
            val payload = JSONObject().apply {
                put("version", 1)
                put("name", "preferences")
                put("rows", JSONObject(preferencesJson))
            }.toString()
            val temp = File(dir, "preferences.json.${System.nanoTime()}.tmp")
            temp.writeText(payload)
            if (!temp.renameTo(prefFile)) {
                prefFile.writeText(payload)
                temp.delete()
            }
            seeded = true
        }
        return seeded
    }

    private fun dumpTable(db: SupportSQLiteDatabase, table: String): JSONArray {
        val out = JSONArray()
        // The table names are compile-time constants in this object, never user input.
        val cursor = db.query("SELECT * FROM `$table`")
        cursor.use { c ->
            val columns = c.columnNames
            while (c.moveToNext()) {
                val row = JSONObject()
                for (i in columns.indices) {
                    row.put(columns[i], valueOf(c, i))
                }
                out.put(row)
            }
        }
        return out
    }

    private fun valueOf(cursor: Cursor, index: Int): Any? = when (cursor.getType(index)) {
        Cursor.FIELD_TYPE_NULL -> JSONObject.NULL
        Cursor.FIELD_TYPE_INTEGER -> cursor.getLong(index)
        Cursor.FIELD_TYPE_FLOAT -> cursor.getDouble(index)
        // Blobs are base64: room's route tables have none today, but a future column must not
        // make the seed fail silently.
        Cursor.FIELD_TYPE_BLOB -> cursor.getBlob(index)?.let {
            Base64.encodeToString(it, Base64.NO_WRAP)
        }
        else -> cursor.getString(index)
    }
}
