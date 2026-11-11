package io.flrone.bridge

import android.database.Cursor
import android.util.Base64
import androidx.sqlite.db.SupportSQLiteDatabase
import io.nekohasekai.sagernet.database.SagerDatabase
import org.json.JSONArray
import org.json.JSONObject

/**
 * One-time Room v20 -> JSON document export (ADR 0002, phase 2).
 *
 * The data plane is moving to Go/Dart, which cannot open an Android Room
 * database. Rather than hand-map seven entities field by field (a missed column
 * would silently lose user data on upgrade), this dumps each table by column
 * name: ids, JSON blobs, nulls and future columns all survive verbatim.
 *
 * Room is NEVER written or deleted here. The export is read-only and idempotent
 * — the caller may run it again after a failed write. `data.documents` hands the
 * result to Dart, which writes the files atomically via `DocumentStore`.
 */
object RoomToJsonMigration {

    /** The seven tables of schema v20, in a stable order. */
    val tables = listOf(
        "profiles",
        "groups",
        "route_profiles",
        "route_rules",
        "global_route_rules",
        "settings",
        "markers",
    )

    /**
     * Reads every table into a JSON string keyed by table name.
     *
     * Opening the database through Room first (rather than SQLiteDatabase
     * directly) forces any pending migration to run, so the columns we see are
     * the ones the compiled entities expect.
     */
    fun export(): String {
        // Force Room to open/migrate before we touch the raw handle.
        val db = SagerDatabase.instance.openHelper.readableDatabase
        val root = JSONObject()
        for (table in tables) {
            root.put(table, dumpTable(db, table))
        }
        return root.toString()
    }

    private fun dumpTable(db: SupportSQLiteDatabase, table: String): JSONArray {
        val out = JSONArray()
        // The table names are compile-time constants in this object, never user
        // input, so an interpolated name is safe here.
        val cursor = db.query("SELECT * FROM `$table`")
        cursor.use { c ->
            val columns = c.columnNames
            while (c.moveToNext()) {
                val row = JSONObject()
                for (i in columns.indices) {
                    // put() with null removes the key; putOpt keeps nulls, which
                    // matters: a null column and a missing column are different
                    // to the DAO that will read this document back.
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
        Cursor.FIELD_TYPE_BLOB -> cursor.getBlob(index)?.let {
            Base64.encodeToString(it, Base64.NO_WRAP)
        }
        else -> cursor.getString(index)
    }
}
