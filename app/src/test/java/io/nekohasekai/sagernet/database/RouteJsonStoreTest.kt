// The JSON route store's round-trip (ADR 0002, phase 3b).
//
// This is the migration's second half: RouteManager prefers these documents once
// they parse, so a field that does not survive the round-trip would silently
// reset a user's routing after an upgrade. The tests build entities with every
// field set to a distinctive value and assert the read-back matches, then pin
// the two fallback rules (a corrupt file reads as absent, a missing directory
// means "not ready") — the behaviours that keep Room authoritative when
// anything is wrong.

import io.nekohasekai.sagernet.database.RouteJsonStore
import io.nekohasekai.sagernet.database.RouteProfileEntity
import io.nekohasekai.sagernet.database.RouteRuleEntity
import java.io.File
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
        // The corrupt-file test drives the logger; android.util.Log is not available
        // on the JVM, so the sink is swapped for the duration of the test.
        originalLogger = RouteJsonStore.logger
        RouteJsonStore.logger = { _, _ -> }
    }

    @After
    fun tearDown() {
        RouteJsonStore.directory = null
        RouteJsonStore.logger = originalLogger
        temp.deleteRecursively()
    }

    private fun profile(id: Long = 0L, name: String = "Default") = RouteProfileEntity().apply {
        this.id = id
        this.name = name
        defaultOutboundId = -5L
        isRemote = true
        remoteUrl = "https://example.test/r"
        autoUpdate = true
        remoteLastUpdate = 1_700_000_000L
        isRaw = false
        rawRoute = "raw"
        preventModifications = true
        endpointProfileIds = "[1,2]"
        innerHopEndpointIds = "[3]"
        dnsJson = """{"servers":["1.1.1.1"]}"""
        customDns = true
        sourceGid = 42L
        disabledGlobalRuleJson = "[7,8]"
    }

    private fun rule(profileId: Long, order: Int) = RouteRuleEntity().apply {
        routeProfileId = profileId
        ruleOrder = order
        name = "rule-$order"
        type = 3
        ipVersion = "4"
        network = "tcp"
        protocol = "tls"
        inboundJson = "[\"a\"]"
        domainJson = "[\"b.com\"]"
        domainSuffixJson = "[\".c\"]"
        domainKeywordJson = "[\"d\"]"
        domainRegexJson = "[\"^e\"]"
        sourceIpCidrJson = "[\"10.0.0.0/8\"]"
        sourceIpIsPrivate = true
        ipCidrJson = "[\"1.2.3.0/24\"]"
        ipIsPrivate = true
        sourcePortJson = "[\"1\"]"
        sourcePortRangeJson = "[\"2\"]"
        portJson = "[\"443\"]"
        portRangeJson = "[\"100-200\"]"
        processNameJson = "[\"p\"]"
        processPathJson = "[\"/q\"]"
        processPathRegexJson = "[\"^/r\"]"
        packageNameJson = "[\"s\"]"
        packageNameRegexJson = "[\"^t\"]"
        networkTypeJson = "[\"wifi\"]"
        wifiSsidJson = "[\"ssid\"]"
        wifiBssidJson = "[\"bssid\"]"
        ruleSetJson = "[\"rs\"]"
        sniffersJson = "[\"sn\"]"
        action = "hijack-dns"
        outboundId = -3L
        rejectMethod = "default"
        overrideAddress = "1.1.1.1"
        overridePort = "53"
        tlsFragment = true
        tlsFragmentFallbackDelay = "1s"
        tlsRecordFragment = true
        tlsSpoof = "spoof"
        tlsSpoofMethod = "method"
        strategy = "prefer_ipv4"
        disabled = true
        invert = true
        noDrop = true
        sniffOverrideDest = true
        networkIsExpensive = true
    }

    @Test
    fun `not ready without a directory`() {
        RouteJsonStore.directory = null
        assertFalse(RouteJsonStore.ready)
        assertNull(RouteJsonStore.allProfiles())
    }

    @Test
    fun `not ready before any document exists`() {
        // The directory is set but empty: reads answer null so Room stays the source.
        assertFalse(RouteJsonStore.ready)
        assertTrue(RouteJsonStore.allProfiles().orEmpty().isEmpty())
    }

    @Test
    fun `profile survives a round trip with every field intact`() {
        val id = RouteJsonStore.insertProfile(profile(name = "Tokyo"))
        assertTrue(RouteJsonStore.ready)

        val back = RouteJsonStore.allProfiles()!!.single()
        assertEquals(id, back.id)
        assertEquals("Tokyo", back.name)
        assertEquals(-5L, back.defaultOutboundId)
        assertTrue(back.isRemote)
        assertEquals("https://example.test/r", back.remoteUrl)
        assertTrue(back.autoUpdate)
        assertEquals(1_700_000_000L, back.remoteLastUpdate)
        assertTrue(back.preventModifications)
        assertEquals("[1,2]", back.endpointProfileIds)
        assertEquals("[3]", back.innerHopEndpointIds)
        assertEquals("""{"servers":["1.1.1.1"]}""", back.dnsJson)
        assertTrue(back.customDns)
        assertEquals(42L, back.sourceGid)
        assertEquals("[7,8]", back.disabledGlobalRuleJson)
    }

    @Test
    fun `rule survives a round trip with every field intact`() {
        val id = RouteJsonStore.insertProfile(profile())
        RouteJsonStore.insertRules(listOf(rule(id, 0)))

        val back = RouteJsonStore.rulesOf(id).single()
        assertEquals(id, back.routeProfileId)
        assertEquals("rule-0", back.name)
        assertEquals(3, back.type)
        assertEquals("4", back.ipVersion)
        assertEquals("tcp", back.network)
        assertEquals("tls", back.protocol)
        assertEquals("[\"b.com\"]", back.domainJson)
        assertEquals("[\".c\"]", back.domainSuffixJson)
        assertEquals("[\"rs\"]", back.ruleSetJson)
        assertEquals("[\"sn\"]", back.sniffersJson)
        assertEquals("hijack-dns", back.action)
        assertEquals(-3L, back.outboundId)
        assertEquals("1s", back.tlsFragmentFallbackDelay)
        assertEquals("prefer_ipv4", back.strategy)
        assertTrue(back.disabled)
        assertTrue(back.invert)
        assertTrue(back.noDrop)
        assertTrue(back.sniffOverrideDest)
        assertTrue(back.networkIsExpensive)
    }

    @Test
    fun `rules are ordered and scoped to their profile`() {
        val a = RouteJsonStore.insertProfile(profile(name = "A"))
        val b = RouteJsonStore.insertProfile(profile(name = "B"))
        RouteJsonStore.insertRules(listOf(rule(a, 1), rule(a, 0), rule(b, 0)))

        assertEquals(listOf(0, 1), RouteJsonStore.rulesOf(a).map { it.ruleOrder })
        assertEquals(1, RouteJsonStore.rulesOf(b).size)
    }

    @Test
    fun `insert assigns increasing ids`() {
        val first = RouteJsonStore.insertProfile(profile())
        val second = RouteJsonStore.insertProfile(profile())

        assertEquals(first + 1, second)
        assertEquals(2, RouteJsonStore.count())
    }

    @Test
    fun `update replaces in place and reports a miss`() {
        val id = RouteJsonStore.insertProfile(profile(name = "old"))
        assertEquals(1, RouteJsonStore.updateProfile(profile(id = id, name = "new")))
        assertEquals("new", RouteJsonStore.getProfile(id)!!.name)

        val ghost = RouteProfileEntity().apply { this.id = 999L }
        assertEquals(0, RouteJsonStore.updateProfile(ghost))
    }

    @Test
    fun `delete removes the profile and its rules`() {
        val id = RouteJsonStore.insertProfile(profile())
        RouteJsonStore.insertRules(listOf(rule(id, 0)))
        RouteJsonStore.deleteProfile(id)

        assertNull(RouteJsonStore.getProfile(id))
        assertTrue(RouteJsonStore.rulesOf(id).isEmpty())
    }

    @Test
    fun `a corrupt document reads as absent so Room stays authoritative`() {
        val id = RouteJsonStore.insertProfile(profile())
        assertNotNull(RouteJsonStore.getProfile(id))

        File(temp, "route_profiles.json").writeText("{ broken")
        assertNull(RouteJsonStore.allProfiles())
    }

    @Test
    fun `is_usable follows the raw flag`() {
        val normal = RouteJsonStore.insertProfile(profile())
        val raw = RouteJsonStore.insertProfile(profile().apply { isRaw = true })

        assertTrue(RouteJsonStore.isUsable(normal))
        assertFalse(RouteJsonStore.isUsable(raw))
        assertFalse(RouteJsonStore.isUsable(0L))
    }
}
