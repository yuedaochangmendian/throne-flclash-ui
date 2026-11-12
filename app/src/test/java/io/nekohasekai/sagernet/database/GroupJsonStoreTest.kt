// The read-only group document view (ADR 0002, phase 3d).
//
// Go is the only writer, so this side's contract is narrow and worth pinning: it must
// read a document the kernel wrote, map every column onto the entity, and answer null — never
// throw — when the file is absent or corrupt, because null is what makes callers fall
// back to Room instead of losing the user's groups.

import io.nekohasekai.sagernet.database.GroupJsonStore
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

class GroupJsonStoreTest {

    private lateinit var temp: File
    private lateinit var originalLogger: (String, Throwable?) -> Unit

    @Before
    fun setUp() {
        temp = File.createTempFile("group-json", "").let { probe ->
            probe.delete()
            probe.mkdirs()
            probe
        }
        GroupJsonStore.directory = temp
        originalLogger = GroupJsonStore.logger
        GroupJsonStore.logger = { _, _ -> }
    }

    @After
    fun tearDown() {
        GroupJsonStore.directory = null
        GroupJsonStore.logger = originalLogger
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

    private fun groupRow(id: Long, name: String = "Default") = mapOf<String, Any?>(
        "id" to id,
        "archive" to 0,
        "skip_auto_update" to 0,
        "name" to name,
        "url" to "",
        "info" to "",
        "sub_last_update" to 0L,
        "front_proxy_id" to -1L,
        "landing_proxy_id" to -1L,
        "column_width_json" to "",
        "scroll_last_profile" to -1,
        "auto_clear_unavailable" to 0,
        "test_sort_by" to 0,
        "traffic_sort_by" to 0,
        "test_items_to_show" to 0,
        "type_sort_by" to 0,
        "sub_options_json" to "{}",
        "sub_metadata_json" to "{}",
        "sort_method" to 0,
        "sort_descending" to 0,
        "display_order" to 1L,
        "route_id" to -1L,
        "import_sub_route" to 0,
    )

    @Test
    fun `not ready without a directory`() {
        GroupJsonStore.directory = null
        assertFalse(GroupJsonStore.ready)
        assertNull(GroupJsonStore.all())
    }

    @Test
    fun `not ready before the kernel writes anything`() {
        assertFalse(GroupJsonStore.ready)
        assertTrue(GroupJsonStore.all().orEmpty().isEmpty())
    }

    @Test
    fun `a group written by the kernel maps every column`() {
        write("groups", listOf(groupRow(7, "My Group")))
        assertTrue(GroupJsonStore.ready)

        val group = GroupJsonStore.all()!!.single()
        assertEquals(7L, group.id)
        assertEquals("My Group", group.name)
        assertEquals("", group.url)
        assertFalse(group.archive)
        assertFalse(group.skipAutoUpdate)
        assertEquals(0L, group.subLastUpdate)
        assertEquals(-1L, group.frontProxyId)
        assertEquals(-1L, group.landingProxyId)
        assertEquals(-1, group.scrollLastProfile)
        assertEquals(1L, group.displayOrder)
        assertEquals(-1L, group.routeId)
        assertFalse(group.importSubRoute)
    }

    @Test
    fun `groups are ordered by display_order then id`() {
        write("groups", listOf(
            groupRow(3, "C").plus("display_order" to 2L),
            groupRow(1, "A").plus("display_order" to 1L),
            groupRow(2, "B").plus("display_order" to 1L),
        ))

        val groups = GroupJsonStore.all()!!
        assertEquals(listOf(1L, 2L, 3L), groups.map { it.id })
    }

    @Test
    fun `count and ids follow the document`() {
        write("groups", listOf(groupRow(9), groupRow(3)))

        assertEquals(2L, GroupJsonStore.count())
        assertEquals(listOf(3L, 9L), GroupJsonStore.allIds())
    }

    @Test
    fun `a corrupt document reads as absent so Room stays authoritative`() {
        write("groups", listOf(groupRow(1)))
        assertNotNull(GroupJsonStore.getById(1))

        File(temp, "groups.json").writeText("{ broken")
        assertNull(GroupJsonStore.all())
    }

    @Test
    fun `a document with no rows array reads as absent`() {
        File(temp, "groups.json").writeText("""{"version":1,"name":"groups"}""")
        assertNull(GroupJsonStore.all())
    }

    @Test
    fun `boolean columns map from 0 and 1`() {
        write("groups", listOf(groupRow(1) + mapOf<String, Any?>(
            "archive" to 1, "skip_auto_update" to 1, "auto_clear_unavailable" to 1,
            "sort_descending" to 1, "import_sub_route" to 1,
        )))

        val group = GroupJsonStore.all()!!.single()
        assertTrue(group.archive)
        assertTrue(group.skipAutoUpdate)
        assertTrue(group.autoClearUnavailable)
        assertTrue(group.sortDescending)
        assertTrue(group.importSubRoute)
    }

    // The regression this file exists for: before the directory was mounted, the kernel's
    // reorder wrote groups.json and no reader ever saw it, so the tab order silently
    // stayed put. These pin the two halves of that fix -- the store sees a kernel write,
    // and display_order is what orders the list.
    @Test
    fun `a kernel reorder is visible through the store`() {
        write("groups", listOf(
            groupRow(1, "A").plus("display_order" to 0L),
            groupRow(2, "B").plus("display_order" to 1L),
        ))
        assertEquals(listOf(1L, 2L), GroupJsonStore.all()!!.map { it.id })

        // The kernel renumbers 0..n-1 after a reorder; B first now.
        write("groups", listOf(
            groupRow(1, "A").plus("display_order" to 1L),
            groupRow(2, "B").plus("display_order" to 0L),
        ))
        assertEquals(listOf(2L, 1L), GroupJsonStore.all()!!.map { it.id })
    }

    @Test
    fun `reports ready when the kernel has written the document`() {
        assertFalse(GroupJsonStore.ready)
        write("groups", listOf(groupRow(1)))
        assertTrue(GroupJsonStore.ready)
    }
}
