// The read-only route document view (ADR 0002, phase 3c).
//
// Go is the only writer now, so this side's contract is narrower and worth pinning: it must
// read a document the kernel wrote, map every column onto the entity, and answer null — never
// throw — when the file is absent or corrupt, because null is what makes RouteManager fall
// back to Room instead of losing the user's routing.

import io.nekohasekai.sagernet.database.RouteJsonStore
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

class RouteJsonStoreTest {

    private lateinit var temp: File
    private lateinit var originalLogger: (String, Throwable?) -> Unit

    @Before
    fun setUp() {
        temp = File.createTempFile("route-json", "").let { probe ->
            probe.delete()
            probe.mkdirs()
            probe
        }
        RouteJsonStore.directory = temp
        // The corrupt-file test drives the logger; android.util.Log is not available on the
        // JVM, so the sink is swapped for the duration of the test.
        originalLogger = RouteJsonStore.logger
        RouteJsonStore.logger = { _, _ -> }
    }

    @After
    fun tearDown() {
        RouteJsonStore.directory = null
        RouteJsonStore.logger = originalLogger
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

    private fun profileRow(id: Long, name: String = "Default") = mapOf<String, Any?>(
        "id" to id,
        "name" to name,
        "default_outbound_id" to -5L,
        "is_remote" to 1,
        "remote_url" to "https://example.test/r",
        "auto_update" to 1,
        "remote_last_update" to 1_700_000_000L,
        "is_raw" to 0,
        "raw_route" to "raw",
        "prevent_modifications" to 1,
        "endpoint_profile_ids" to "[1,2]",
        "inner_hop_endpoint_ids" to "[3]",
        "dns_json" to """{"servers":["1.1.1.1"]}""",
        "custom_dns" to 1,
        "source_gid" to 42L,
        "disabled_global_rule_json" to "[7,8]",
    )

    private fun ruleRow(profileId: Long, order: Int, name: String = "rule") = mapOf<String, Any?>(
        "route_profile_id" to profileId,
        "rule_order" to order,
        "name" to name,
        "type" to 3,
        "ip_version" to "4",
        "network" to "tcp",
        "protocol" to "tls",
        "domain_json" to """["b.com"]""",
        "rule_set_json" to """["rs"]""",
        "sniffers_json" to """["sn"]""",
        "action" to "hijack-dns",
        "outbound_id" to -3L,
        "strategy" to "prefer_ipv4",
        "disabled" to 1,
        "invert" to 1,
        "network_is_expensive" to 1,
    )

    @Test
    fun `not ready without a directory`() {
        RouteJsonStore.directory = null
        assertFalse(RouteJsonStore.ready)
        assertNull(RouteJsonStore.allProfiles())
    }

    @Test
    fun `not ready before the kernel writes anything`() {
        assertFalse(RouteJsonStore.ready)
        assertTrue(RouteJsonStore.allProfiles().orEmpty().isEmpty())
    }

    @Test
    fun `a profile written by the kernel maps every column`() {
        write("route_profiles", listOf(profileRow(7, "Tokyo")))
        assertTrue(RouteJsonStore.ready)

        val profile = RouteJsonStore.allProfiles()!!.single()
        assertEquals(7L, profile.id)
        assertEquals("Tokyo", profile.name)
        assertEquals(-5L, profile.defaultOutboundId)
        assertTrue(profile.isRemote)
        assertEquals("https://example.test/r", profile.remoteUrl)
        assertTrue(profile.autoUpdate)
        assertEquals(1_700_000_000L, profile.remoteLastUpdate)
        assertTrue(profile.preventModifications)
        assertEquals("[1,2]", profile.endpointProfileIds)
        assertEquals("[3]", profile.innerHopEndpointIds)
        assertEquals("""{"servers":["1.1.1.1"]}""", profile.dnsJson)
        assertTrue(profile.customDns)
        assertEquals(42L, profile.sourceGid)
        assertEquals("[7,8]", profile.disabledGlobalRuleJson)
    }

    @Test
    fun `a rule written by the kernel maps every column`() {
        write("route_profiles", listOf(profileRow(1)))
        write("route_rules", listOf(ruleRow(1, 0, "mine")))

        val rule = RouteJsonStore.rulesOf(1).single()
        assertEquals("mine", rule.name)
        assertEquals(3, rule.type)
        assertEquals("4", rule.ipVersion)
        assertEquals("tcp", rule.network)
        assertEquals("""["b.com"]""", rule.domainJson)
        assertEquals("""["rs"]""", rule.ruleSetJson)
        assertEquals("""["sn"]""", rule.sniffersJson)
        assertEquals("hijack-dns", rule.action)
        assertEquals(-3L, rule.outboundId)
        assertEquals("prefer_ipv4", rule.strategy)
        assertTrue(rule.disabled)
        assertTrue(rule.invert)
        assertTrue(rule.networkIsExpensive)
    }

    @Test
    fun `rules are ordered and scoped to their profile`() {
        write("route_profiles", listOf(profileRow(1), profileRow(2)))
        write(
            "route_rules",
            listOf(ruleRow(1, 1), ruleRow(1, 0), ruleRow(2, 0)),
        )

        assertEquals(listOf(0, 1), RouteJsonStore.rulesOf(1).map { it.ruleOrder })
        assertEquals(1, RouteJsonStore.rulesOf(2).size)
        assertEquals(3, RouteJsonStore.allRules()!!.size)
    }

    @Test
    fun `count and ids follow the document`() {
        write("route_profiles", listOf(profileRow(9), profileRow(3)))

        assertEquals(2L, RouteJsonStore.count())
        assertEquals(listOf(3L, 9L), RouteJsonStore.allIds())
    }

    @Test
    fun `is_usable follows the raw flag`() {
        write(
            "route_profiles",
            listOf(profileRow(1).plus("is_raw" to 0), profileRow(2).plus("is_raw" to 1)),
        )

        assertTrue(RouteJsonStore.isUsable(1))
        assertFalse(RouteJsonStore.isUsable(2))
        assertFalse(RouteJsonStore.isUsable(0))
    }

    @Test
    fun `a corrupt document reads as absent so Room stays authoritative`() {
        write("route_profiles", listOf(profileRow(1)))
        assertNotNull(RouteJsonStore.getProfile(1))

        File(temp, "route_profiles.json").writeText("{ broken")
        assertNull(RouteJsonStore.allProfiles())
    }

    @Test
    fun `a document with no rows array reads as absent`() {
        File(temp, "route_profiles.json").writeText("""{"version":1,"name":"route_profiles"}""")
        assertNull(RouteJsonStore.allProfiles())
    }

    @Test
    fun `a newer document version still reads`() {
        // The columns are additive; refusing a newer file would strand a user who downgraded
        // a build, which is worse than reading the columns this build knows.
        val payload = JSONObject().apply {
            put("version", 2)
            put("name", "route_profiles")
            put("rows", org.json.JSONArray(listOf(profileRow(5))))
        }
        File(temp, "route_profiles.json").writeText(payload.toString())

        assertEquals(5L, RouteJsonStore.allProfiles()!!.single().id)
    }

    // --- the global rule pool ---------------------------------------------------
    //
    // It is the one document whose reader was missing: the kernel has owned the pool all
    // along, but RouteManager answered ConfigGenerator from the Room table the one-time seed
    // filled and nothing has written since. These pin the document path that replaces it.

    /** A pool row as the kernel writes it: `id`, no `route_profile_id`. */
    private fun globalRuleRow(id: Long, order: Int, name: String = "global") = mapOf<String, Any?>(
        "id" to id,
        "rule_order" to order,
        "name" to name,
        "type" to 0,
        "domain_suffix_json" to """["ads.example"]""",
        "action" to "reject",
        "outbound_id" to -1L,
    )

    @Test
    fun `the global pool maps id onto ruleId`() {
        // The kernel writes `id`; GlobalRouteRuleEntity's primary key is `rule_id`. Getting
        // this wrong would make every pool rule look like id 0 and the per-profile disable
        // set could never match.
        write("global_route_rules", listOf(globalRuleRow(11, 0), globalRuleRow(12, 1)))

        val pool = RouteJsonStore.allGlobalRules()!!
        assertEquals(listOf(11L, 12L), pool.map { it.ruleId })
        assertEquals(listOf(0, 1), pool.map { it.ruleOrder })
        assertEquals("reject", pool.first().action)
        assertEquals("""["ads.example"]""", pool.first().domainSuffixJson)
    }

    @Test
    fun `a missing global pool reads as absent so Room stays authoritative`() {
        // No document at all: null is what makes RouteManager fall back rather than answer an
        // empty pool, which would silently drop rules the user still has.
        assertNull(RouteJsonStore.allGlobalRules())
    }

    @Test
    fun `a corrupt global pool reads as absent`() {
        File(temp, "global_route_rules.json").writeText("{ broken")
        assertNull(RouteJsonStore.allGlobalRules())
    }

    @Test
    fun `the global pool alone makes the store ready`() {
        // ready gates the reader, so a tree whose only document is the pool must still count:
        // the three documents are written by the same hand-over.
        write("global_route_rules", listOf(globalRuleRow(1, 0)))
        assertTrue(RouteJsonStore.ready)
    }
}
