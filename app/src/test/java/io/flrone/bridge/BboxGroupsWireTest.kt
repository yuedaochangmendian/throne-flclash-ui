package io.flrone.bridge

import io.flrone.model.ProxyGroup
import io.flrone.model.ProxyNode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The two shapes of the group payload: counts for `ready` and every other screen, rows only while
 * the Proxies screen is open. A field renamed here has to fail here — the Dart side reads these
 * keys by name and would otherwise render blanks on a device.
 */
class BboxGroupsWireTest {

    private val nodes = listOf(
        ProxyNode(id = 1, tag = "🇭🇰 香港 01", type = "shadowsocks", delay = 40, testedAt = 1_793_030_400_000),
        ProxyNode(id = 2, tag = "🇯🇵 东京 01", type = "vless", delay = 0, testedAt = 1_793_030_400_000),
        ProxyNode(id = 3, tag = "Auto", type = "Auto Selector", testedAt = 0, isSelector = true),
    )
    private val groups = listOf(
        ProxyGroup(id = 7, tag = "Primary", type = "group", selected = "🇭🇰 香港 01", selectedId = 1, nodes = nodes),
        ProxyGroup(id = 8, tag = "Empty", type = "subscription", nodes = emptyList()),
    )

    @Test
    fun `the light shape carries counts and no rows`() {
        val wire = BboxGroupsWire.groups(groups, withItems = false)

        assertEquals(2, wire.size)
        assertEquals(3, wire[0]["nodeCount"])
        assertEquals(0, wire[1]["nodeCount"])
        assertEquals(emptyList<Map<String, Any?>>(), wire[0]["items"])
        assertTrue(wire[0].containsKey("items"))
        assertEquals(1, wire[0]["selectedId"])
    }

    @Test
    fun `timeouts count nodes that were tested and did not answer`() {
        val wire = BboxGroupsWire.groups(groups, withItems = false)

        // Node 2 was tested (testedAt > 0) and has no delay; node 3 was never tested.
        assertEquals(1, wire[0]["timeouts"])
        assertEquals(0, wire[1]["timeouts"])
    }

    @Test
    fun `the full shape keeps every node in order`() {
        val wire = BboxGroupsWire.groups(groups, withItems = true)

        @Suppress("UNCHECKED_CAST")
        val items = wire[0]["items"] as List<Map<String, Any?>>
        assertEquals(listOf(1, 2, 3), items.map { it["id"] })
        assertEquals("🇯🇵 东京 01", items[1]["tag"])
        assertEquals("vless", items[1]["type"])
        assertEquals(0, items[1]["delay"])
        assertEquals(1_793_030_400_000L, items[1]["testedAt"])
        assertFalse(items[1]["isSelector"] as Boolean)
        assertTrue(items[2]["isSelector"] as Boolean)
    }

    @Test
    fun `the picker list is flat, id and tag only`() {
        val wire = BboxGroupsWire.nodes(groups)

        assertEquals(listOf(1, 2, 3), wire.map { it["id"] })
        assertEquals(setOf("id", "tag"), wire.first().keys)
        assertEquals("🇭🇰 香港 01", wire.first()["tag"])
    }
}
