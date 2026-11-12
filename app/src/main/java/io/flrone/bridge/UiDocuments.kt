package io.flrone.bridge

import org.json.JSONObject
import java.io.File

/**
 * Read/write access to the Go-owned UI documents (ADR 0002, phase 3e).
 *
 * `ui_settings.json` and `preferences.json` live under `<basePath>/documents/` alongside the
 * route and profile documents. Go is the writer once the action bus is attached; this object
 * is the Kotlin reader (for `ready`, backup, `settingsWire`) and the fallback writer when the
 * bus is not attached (bridge mode).
 *
 * The wire shape is a flat JSON object (camelCase keys → typed values), enveloped as
 * `{version: 1, name: "...", rows: {...}}` matching the other document stores.
 */
object UiDocuments {

    /** Where the documents live; the host sets it once the kernel base path is known. */
    @Volatile
    var directory: File? = null

    /**
     * Diagnostics sink. Injected rather than calling android.util.Log directly: the JVM
     * unit tests exercise the corrupt-file path, and an unmocked Log.w would fail them.
     */
    @Volatile
    var logger: (String, Throwable?) -> Unit = { message, error ->
        if (error != null) {
            io.nekohasekai.sagernet.ktx.Logs.w(message, error)
        } else {
            io.nekohasekai.sagernet.ktx.Logs.w(message)
        }
    }

    /** Reads `ui_settings.json` (the shell overlay layer). Missing or corrupt → empty map. */
    fun readUiSettings(): Map<String, Any?> = read("ui_settings")

    /** Reads `preferences.json` (UI preferences). Missing or corrupt → empty map. */
    fun readPreferences(): Map<String, Any?> = read("preferences")

    /** Writes `ui_settings.json` atomically. */
    fun writeUiSettings(values: Map<String, Any?>) = write("ui_settings", values)

    /** Writes `preferences.json` atomically. */
    fun writePreferences(values: Map<String, Any?>) = write("preferences", values)

    /** Reads `host_facts.json` (Kotlin-published facts like batteryExempt). */
    fun readHostFacts(): Map<String, Any?> = read("host_facts")

    /** Writes `host_facts.json` (called on attach and resume). */
    fun writeHostFacts(values: Map<String, Any?>) = write("host_facts", values)

    /** True when either UI document exists (the seed has run). */
    val ready: Boolean
        get() {
            val dir = directory ?: return false
            return File(dir, "ui_settings.json").isFile || File(dir, "preferences.json").isFile
        }

    // --- internals ----------------------------------------------------------

    private fun read(name: String): Map<String, Any?> {
        val dir = directory ?: return emptyMap()
        val file = File(dir, "$name.json")
        if (!file.isFile) return emptyMap()
        return try {
            val root = JSONObject(file.readText())
            val rows = root.optJSONObject("rows") ?: return emptyMap()
            rows.keys().asSequence().associateWith { key ->
                when (val v = rows.get(key)) {
                    JSONObject.NULL -> null
                    else -> v
                }
            }
        } catch (e: Exception) {
            logger("unreadable $name.json; falling back to defaults", e)
            emptyMap()
        }
    }

    private fun write(name: String, values: Map<String, Any?>) {
        val dir = directory ?: return
        if (!dir.isDirectory && !dir.mkdirs()) return
        val payload = JSONObject().apply {
            put("version", 1)
            put("name", name)
            put("rows", JSONObject().apply {
                values.forEach { (key, value) ->
                    if (value != null) put(key, value) else put(key, JSONObject.NULL)
                }
            })
        }.toString()
        val temp = File(dir, "$name.json.${System.nanoTime()}.tmp")
        temp.writeText(payload)
        if (!temp.renameTo(File(dir, "$name.json"))) {
            File(dir, "$name.json").writeText(payload)
            temp.delete()
        }
    }
}
