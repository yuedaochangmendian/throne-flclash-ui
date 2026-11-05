package io.nekohasekai.sagernet.bg

import io.nekohasekai.sagernet.bg.DomainResolver.Resolved
import io.throne.bbox.bridge.BboxResolve
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The wire contract of `dns.resolve`, exercised without the core: [DomainResolver.wire] shapes what
 * the :bg process answers and [BboxResolve.parse] is the only reader, so a field renamed on one
 * side has to fail here rather than on a device with no box running.
 */
class DomainResolverTest {

    @Test
    fun `wire keeps request order and both address families`() {
        val reply = JSONObject(
            DomainResolver.wire(
                running = true,
                results = listOf(
                    Resolved("example.com", listOf("93.184.216.34", "2606:2800::1"), ""),
                    Resolved("missing.invalid", emptyList(), "no such host"),
                ),
            )
        )

        assertTrue(reply.getBoolean("running"))
        val results = reply.getJSONArray("results")
        assertEquals(2, results.length())
        assertEquals("example.com", results.getJSONObject(0).getString("domain"))
        assertEquals(2, results.getJSONObject(0).getJSONArray("addresses").length())
        assertEquals("no such host", results.getJSONObject(1).getString("error"))
        assertEquals(0, results.getJSONObject(1).getJSONArray("addresses").length())
    }

    @Test
    fun `no running box answers running=false with no rows`() {
        val reply = JSONObject(DomainResolver.wire(running = false, results = emptyList()))

        assertFalse(reply.getBoolean("running"))
        assertEquals(0, reply.getJSONArray("results").length())
    }

    @Test
    fun `the bridge reply round-trips through parse`() {
        val wire = DomainResolver.wire(
            running = true,
            results = listOf(Resolved("a.test", listOf("10.0.0.1"), "")),
        )

        val parsed = BboxResolve.parse(wire)
        assertEquals(true, parsed["running"])
        val rows = parsed["results"] as List<*>
        assertEquals(1, rows.size)
        val row = rows.single() as Map<*, *>
        assertEquals("a.test", row["domain"])
        assertEquals(listOf("10.0.0.1"), row["addresses"])
        assertEquals("", row["error"])
    }

    @Test
    fun `an unusable reply degrades to no rows`() {
        for (reply in listOf(null, "", "not json", "{}")) {
            val parsed = BboxResolve.parse(reply)
            assertEquals(false, parsed["running"])
            assertTrue((parsed["results"] as List<*>).isEmpty())
        }
    }

    @Test
    fun `a row without an addresses array still parses`() {
        val parsed = BboxResolve.parse("""{"running":true,"results":[{"domain":"a.test","error":"timeout"}]}""")

        val row = (parsed["results"] as List<*>).single() as Map<*, *>
        assertEquals("timeout", row["error"])
        assertTrue((row["addresses"] as List<*>).isEmpty())
    }
}
