package io.nekohasekai.sagernet.outbound.config

import io.nekohasekai.sagernet.outbound.types.Shadowsocks
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ConfigGeneratorGoldenTest {
    @Test
    fun `test build keeps the deterministic proxy tag and profile mapping contract`() {
        val node = Shadowsocks().apply {
            name = "Node A"
            server = "example.com"
            serverPort = 8388
            method = "aes-256-gcm"
            password = "secret"
        }
        val generator = ConfigGenerator(
            profiles = { id -> node.takeIf { id == 1L } },
            settings = GeneratorSettings(),
        )

        val result = generator.buildTest(listOf(TestCandidate(1L)))

        assertTrue(result.error ?: "build failed", result.ok)
        assertEquals(listOf("proxy-1-0"), result.outboundTags)
        assertEquals(mapOf("proxy-1-0" to 1L), result.tagToProfileId)
        val core = JSONObject(result.coreConfig)
        val outbound = core.getJSONArray("outbounds")
            .let { array -> (0 until array.length()).map { array.getJSONObject(it) } }
            .single { it.optString("tag") == "proxy-1-0" }
        assertEquals("shadowsocks", outbound.getString("type"))
        assertEquals("example.com", outbound.getString("server"))
        assertEquals(8388, outbound.getInt("server_port"))
        assertEquals("aes-256-gcm", outbound.getString("method"))
        assertTrue(core.has("dns"))
        assertTrue(core.has("route"))
    }
}
