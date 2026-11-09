package io.flrone.bridge

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The catalog reads `displayType()` once per type instead of once per row: that call parses the
 * row's outbound JSON, and the answer depends on the outbound class, which `type` selects. These
 * pin the two halves of that claim — the cache, and the `custom` exception that cannot be cached.
 */
class BboxCatalogTypeLabelsTest {

    @Test
    fun `a label is resolved once per type`() {
        val labels = BboxCatalog.TypeLabels()
        var calls = 0

        repeat(100) {
            assertEquals("Shadowsocks", labels.of("shadowsocks") { calls++; "Shadowsocks" })
        }

        assertEquals(1, calls)
        assertEquals(1, labels.parses)
    }

    @Test
    fun `each type keeps its own label`() {
        val labels = BboxCatalog.TypeLabels()

        assertEquals("Shadowsocks", labels.of("shadowsocks") { "Shadowsocks" })
        assertEquals("AnyTLS", labels.of("anytls") { "AnyTLS" })
        // Cached: the resolver must not run again for a type already answered.
        assertEquals("Shadowsocks", labels.of("shadowsocks") { error("resolved twice") })
        assertEquals(2, labels.parses)
    }

    @Test
    fun `custom rows are resolved every time`() {
        val labels = BboxCatalog.TypeLabels()
        var calls = 0

        repeat(3) { labels.of("custom") { calls++; "Custom Outbound" } }

        assertEquals(3, calls)
        assertEquals(3, labels.parses)
    }
}
