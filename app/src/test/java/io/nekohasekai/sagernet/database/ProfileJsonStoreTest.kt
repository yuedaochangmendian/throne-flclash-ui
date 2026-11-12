// The read-only profile document view (ADR 0002, phase 3d).
//
// Go is the only writer, so this side's contract is narrow and worth pinning: it must
// read a document the kernel wrote, map every column onto the entity, and answer null — never
// throw — when the file is absent or corrupt, because null is what makes callers fall
// back to Room instead of losing the user's profiles.

import io.nekohasekai.sagernet.database.ProfileJsonStore
import java.io.File
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class ProfileJsonStoreTest {

    private lateinit var temp: File
    private lateinit var originalLogger: (String, Throwable?) -> Unit

    @Before
    fun setUp() {
        temp = File.createTempFile("profile-json", "").let { probe ->
            probe.delete()
            probe.mkdirs()
            probe
        }
        ProfileJsonStore.directory = temp
        originalLogger = ProfileJsonStore.logger
        ProfileJsonStore.logger = { _, _ -> }
    }

    @After
    fun tearDown() {
        ProfileJsonStore.directory = null
        ProfileJsonStore.logger = originalLogger
        temp.deleteRecursively()
    }

    /** Writes a document the way the kernel does: a versioned envelope around rows. */
    private fun write(name: String, rows: List<Map<String, Any?>>) {
        val payload = JSONObject().apply {
            put("version", 1)
            put("name", name)
            put("rows", org.json.JSONArray(rows))
        }
        File(temp, "$name.json").writeText(payload.toString())
    }

    private fun profileRow(id: Long, name: String = "Tokyo", gid: Long = 1L) = mapOf<String, Any?>(
        "id" to id,
        "type" to "socks",
        "name" to name,
        "gid" to gid,
        "user_order" to 0L,
        "latency" to 120,
        "latency_at" to 1_700_000_000L,
        "dl_speed" to "12.34Mbps",
        "ul_speed" to "5.67Mbps",
        "test_country" to "JP",
        "ip_out" to "203.0.113.1",
        "outbound_json" to """{"server":"example.test"}""",
        "traffic_dl" to 1024L,
        "traffic_up" to 512L,
        "test_error" to null,
    )

    @Test
    fun `not ready without a directory`() {
        ProfileJsonStore.directory = null
        assertFalse(ProfileJsonStore.ready)
        assertNull(ProfileJsonStore.all())
    }

    @Test
    fun `not ready before the kernel writes anything`() {
        assertFalse(ProfileJsonStore.ready)
        assertTrue(ProfileJsonStore.all().orEmpty().isEmpty())
    }

    @Test
    fun `a profile written by the kernel maps every column`() {
        write("profiles", listOf(profileRow(7, "Tokyo")))
        assertTrue(ProfileJsonStore.ready)

        val profile = ProfileJsonStore.all()!!.single()
        assertEquals(7L, profile.id)
        assertEquals("socks", profile.type)
        assertEquals("Tokyo", profile.name)
        assertEquals(1L, profile.groupId)
        assertEquals(0L, profile.userOrder)
        assertEquals(120, profile.latency)
        assertEquals(1_700_000_000L, profile.latencyAt)
        assertEquals("12.34Mbps", profile.dlSpeed)
        assertEquals("5.67Mbps", profile.ulSpeed)
        assertEquals("JP", profile.testCountry)
        assertEquals("203.0.113.1", profile.ipOut)
        assertEquals("""{"server":"example.test"}""", profile.outboundJson)
        assertEquals(1024L, profile.rx)
        assertEquals(512L, profile.tx)
    }

    @Test
    fun `profiles are filtered by group and ordered by user_order`() {
        write("profiles", listOf(
            profileRow(1, "A", gid = 1L).plus("user_order" to 1L),
            profileRow(2, "B", gid = 1L).plus("user_order" to 0L),
            profileRow(3, "C", gid = 2L),
        ))

        val group1 = ProfileJsonStore.byGroup(1L)
        assertEquals(2, group1.size)
        assertEquals(listOf(2L, 1L), group1.map { it.id })

        val group2 = ProfileJsonStore.byGroup(2L)
        assertEquals(1, group2.size)
    }

    @Test
    fun `count and ids follow the document`() {
        write("profiles", listOf(profileRow(9), profileRow(3)))

        assertEquals(2L, ProfileJsonStore.count())
        assertEquals(listOf(3L, 9L), ProfileJsonStore.allIds())
    }

    @Test
    fun `a corrupt document reads as absent so Room stays authoritative`() {
        write("profiles", listOf(profileRow(1)))
        assertNotNull(ProfileJsonStore.getById(1))

        File(temp, "profiles.json").writeText("{ broken")
        assertNull(ProfileJsonStore.all())
    }

    @Test
    fun `a document with no rows array reads as absent`() {
        File(temp, "profiles.json").writeText("""{"version":1,"name":"profiles"}""")
        assertNull(ProfileJsonStore.all())
    }

    @Test
    fun `a newer document version still reads`() {
        val payload = JSONObject().apply {
            put("version", 2)
            put("name", "profiles")
            put("rows", org.json.JSONArray(listOf(profileRow(5))))
        }
        File(temp, "profiles.json").writeText(payload.toString())

        assertEquals(5L, ProfileJsonStore.all()!!.single().id)
    }

    @Test
    fun `null name and speeds map to null not empty string`() {
        write("profiles", listOf(profileRow(1) + mapOf<String, Any?>(
            "name" to null, "dl_speed" to null, "ul_speed" to null,
            "test_country" to null, "ip_out" to null, "test_error" to null,
        )))

        val profile = ProfileJsonStore.all()!!.single()
        assertNull(profile.name)
        assertNull(profile.dlSpeed)
        assertNull(profile.ulSpeed)
        assertNull(profile.testCountry)
        assertNull(profile.ipOut)
        assertNull(profile.testError)
    }
}
