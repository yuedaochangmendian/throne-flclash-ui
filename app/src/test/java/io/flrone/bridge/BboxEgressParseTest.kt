package io.flrone.bridge

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The three parsers added when "Lookup provider" was wired up, plus the ordering
 * that makes the setting actually do something. Pure functions: no OkHttp, no
 * Android runtime, no DataStore needed here.
 */
class BboxEgressParseTest {

    @Test
    fun `ipApi maps its query-as fields`() {
        val info = BboxEgress.parseIpApi(
            JSONObject(
                """
                {"status":"success","query":"203.0.113.7","countryCode":"DE",
                 "country":"Germany","regionName":"Berlin","city":"Berlin",
                 "isp":"Example ISP","org":"Example Org","as":"AS12345 Example AS"}
                """.trimIndent(),
            ),
        )

        assertEquals("203.0.113.7", info.ip)
        assertEquals("DE", info.country)
        assertEquals("Germany", info.countryName)
        assertEquals("Berlin", info.city)
        assertEquals("Example ISP", info.isp)
        assertEquals("AS12345", info.asn)
        assertFalse(info.isEmpty)
    }

    @Test
    fun `ipApi failure is an empty answer, not a half-filled one`() {
        val info = BboxEgress.parseIpApi(
            JSONObject("""{"status":"fail","message":"rate limited"}"""),
        )

        assertTrue(info.isEmpty)
        assertNull(info.ip)
        assertNull(info.asn)
    }

    @Test
    fun `ipApiCo splits org into the AS number and the operator`() {
        val info = BboxEgress.parseIpApiCo(
            JSONObject(
                """
                {"ip":"198.51.100.9","country":"US","country_name":"United States",
                 "region":"California","city":"Mountain View","org":"AS15169 Google LLC"}
                """.trimIndent(),
            ),
        )

        assertEquals("198.51.100.9", info.ip)
        assertEquals("US", info.country)
        assertEquals("United States", info.countryName)
        assertEquals("AS15169", info.asn)
        assertEquals("Google LLC", info.organization)
    }

    @Test
    fun `ipApiCo tolerates an org with no AS prefix`() {
        val info = BboxEgress.parseIpApiCo(
            JSONObject("""{"ip":"198.51.100.9","org":"Some Operator"}"""),
        )

        assertEquals("Some Operator", info.organization)
        assertNull(info.asn)
    }

    @Test
    fun `freeIpApi reads its own field names and marks IPv6`() {
        val info = BboxEgress.parseFreeIpApi(
            JSONObject(
                """
                {"ipAddress":"2001:db8::1","countryCode":"JP","countryName":"Japan",
                 "regionName":"Tokyo","cityName":"Tokyo","ipVersion":6}
                """.trimIndent(),
            ),
        )

        assertEquals("2001:db8::1", info.ip)
        assertEquals("JP", info.country)
        assertEquals("Japan", info.countryName)
        assertEquals("Tokyo", info.city)
        assertEquals("IPv6", info.type)
        assertNull(info.isp)
        assertNull(info.asn)
    }

    @Test
    fun `freeIpApi defaults to IPv4 when the version is absent`() {
        val info = BboxEgress.parseFreeIpApi(
            JSONObject("""{"ipAddress":"203.0.113.1"}"""),
        )

        assertEquals("IPv4", info.type)
        assertFalse(info.isEmpty)
    }

    @Test
    fun `the chosen provider is moved to the front of the race`() {
        val sources = BboxEgress.endpointsFor("ipinfo")

        assertEquals("https://ipinfo.io/json", sources.first().first)
        // one chosen + the rest of the default list, without a duplicate of the chosen URL
        assertEquals(5, sources.size)
        assertEquals(1, sources.count { it.first == "https://ipinfo.io/json" })
        assertTrue(sources.drop(1).any { it.first == "https://ipwho.is/" })
    }

    @Test
    fun `a provider that is not in the default list is prepended`() {
        val sources = BboxEgress.endpointsFor("freeipapi")

        assertEquals("https://freeipapi.com/api/json", sources.first().first)
        assertEquals(6, sources.size)
    }

    @Test
    fun `unknown providers keep the default order`() {
        val sources = BboxEgress.endpointsFor("ip2location")

        assertEquals("https://ipwho.is/", sources.first().first)
        assertEquals(5, sources.size)
    }

    @Test
    fun `ip-api is the only plaintext source`() {
        val sources = BboxEgress.endpointsFor("ip-api")

        assertEquals("http://ip-api.com/json", sources.first().first)
        assertTrue(
            "the UI labels this provider as cleartext; keep the assertion if it is ever upgraded to HTTPS",
            sources.first().first.startsWith("http://"),
        )
    }
}
