// The UI documents reader/writer (ADR 0002, phase 3e).
//
// UiDocuments reads the Go-owned JSON documents (ui_settings, preferences, host_facts)
// and writes them in bridge mode. The contract is narrow: read a document the kernel
// wrote, answer empty on absent/corrupt, and write atomically.

package io.flrone.bridge

import java.io.File
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class UiDocumentsTest {

    private lateinit var temp: File
    private lateinit var originalLogger: (String, Throwable?) -> Unit

    @Before
    fun setUp() {
        temp = File.createTempFile("ui-docs", "").let { probe ->
            probe.delete()
            probe.mkdirs()
            probe
        }
        UiDocuments.directory = temp
        originalLogger = UiDocuments.logger
        UiDocuments.logger = { _, _ -> }
    }

    @After
    fun tearDown() {
        UiDocuments.directory = null
        UiDocuments.logger = originalLogger
        temp.deleteRecursively()
    }

    private fun write(name: String, rows: Map<String, Any?>) {
        val payload = JSONObject().apply {
            put("version", 1)
            put("name", name)
            put("rows", JSONObject(rows))
        }
        File(temp, "$name.json").writeText(payload.toString())
    }

    @Test
    fun `not ready without a directory`() {
        UiDocuments.directory = null
        assertFalse(UiDocuments.ready)
    }

    @Test
    fun `not ready before any document exists`() {
        assertFalse(UiDocuments.ready)
    }

    @Test
    fun `reads ui_settings written by the kernel`() {
        write("ui_settings", mapOf("fontSize" to 14, "fontFamily" to "Roboto"))
        assertTrue(UiDocuments.ready)

        val settings = UiDocuments.readUiSettings()
        assertEquals(14, settings["fontSize"])
        assertEquals("Roboto", settings["fontFamily"])
    }

    @Test
    fun `reads preferences written by the kernel`() {
        write("preferences", mapOf("theme" to "dark", "locale" to "en"))
        assertTrue(UiDocuments.ready)

        val prefs = UiDocuments.readPreferences()
        assertEquals("dark", prefs["theme"])
        assertEquals("en", prefs["locale"])
    }

    @Test
    fun `a corrupt document reads as empty`() {
        write("ui_settings", mapOf("fontSize" to 14))
        assertEquals(14, UiDocuments.readUiSettings()["fontSize"])

        File(temp, "ui_settings.json").writeText("{ broken")
        assertTrue(UiDocuments.readUiSettings().isEmpty())
    }

    @Test
    fun `write then read round-trips`() {
        UiDocuments.writeUiSettings(mapOf("fontSize" to 18, "fontFollowTheme" to true))
        val settings = UiDocuments.readUiSettings()
        assertEquals(18, settings["fontSize"])
        assertEquals(true, settings["fontFollowTheme"])
    }

    @Test
    fun `write then read round-trips preferences`() {
        UiDocuments.writePreferences(mapOf("theme" to "light", "count" to 42))
        val prefs = UiDocuments.readPreferences()
        assertEquals("light", prefs["theme"])
        assertEquals(42, prefs["count"])
    }

    @Test
    fun `host facts round-trip`() {
        UiDocuments.writeHostFacts(mapOf("batteryExempt" to true))
        val facts = UiDocuments.readHostFacts()
        assertEquals(true, facts["batteryExempt"])
    }

    @Test
    fun `seedUiDocuments skips existing files`() {
        write("ui_settings", mapOf("fontSize" to 99))
        // Seed should not overwrite.
        val seeded = RoomToJsonMigration.seedUiDocuments(temp, """{"fontSize":14}""", null)
        assertFalse(seeded)
        assertEquals(99, UiDocuments.readUiSettings()["fontSize"])
    }

    @Test
    fun `seedUiDocuments creates missing files`() {
        val seeded = RoomToJsonMigration.seedUiDocuments(temp, """{"fontSize":14}""", """{"theme":"dark"}""")
        assertTrue(seeded)
        assertEquals(14, UiDocuments.readUiSettings()["fontSize"])
        assertEquals("dark", UiDocuments.readPreferences()["theme"])
    }
}
