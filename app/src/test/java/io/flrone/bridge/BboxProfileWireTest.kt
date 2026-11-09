package io.flrone.bridge

import io.flrone.model.ProfileInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BboxProfileWireTest {
    @Test
    fun `profile rows carry every field the Dart cards read`() {
        val wire = BboxProfileWire.profiles(listOf(ProfileInfo(
            id = 7L,
            name = "Subscription",
            type = "subscription",
            traffic = "1.2 GB",
            expiry = "2027-01-01",
            selected = true,
            url = "https://example.test/sub",
            updatedAt = 1_793_030_400_000L,
            autoUpdate = true,
            interval = 120,
        )))

        val row = wire.single()
        assertEquals(7, row["id"])
        assertEquals("Subscription", row["name"])
        assertTrue(row["remote"] as Boolean)
        assertEquals("https://example.test/sub", row["url"])
        assertEquals("1.2 GB", row["traffic"])
        assertEquals("2027-01-01", row["expiry"])
        assertTrue(row["selected"] as Boolean)
        assertEquals(1_793_030_400_000L, row["updatedAt"])
        assertTrue(row["autoUpdate"] as Boolean)
        assertEquals(120, row["interval"])
    }

    @Test
    fun `local groups are not marked remote`() {
        val row = BboxProfileWire.profiles(listOf(ProfileInfo(id = 8L, name = "Local", type = "group"))).single()
        assertFalse(row["remote"] as Boolean)
    }
}
