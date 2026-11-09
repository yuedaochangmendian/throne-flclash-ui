package io.nekohasekai.sagernet.outbound.import

import io.nekohasekai.sagernet.outbound.BuildContext
import java.nio.charset.StandardCharsets
import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Contract corpus for whole-body subscription decoding and the common import formats. */
class ProfileImportTest {

    private val link = "ss://YWVzLTI1Ni1nY206cGFzcw@example.com:8388#Node%20A"
    private val second = "ss://YWVzLTI1Ni1nY206cGFzcw@example.org:8389#Node%20B"

    private fun standard(text: String): String =
        Base64.getEncoder().encodeToString(text.toByteArray(StandardCharsets.UTF_8))

    private fun mime(text: String): String =
        Base64.getMimeEncoder(24, "\r\n".toByteArray()).encodeToString(text.toByteArray(StandardCharsets.UTF_8))

    private fun urlSafe(text: String): String =
        Base64.getUrlEncoder().withoutPadding().encodeToString(text.toByteArray(StandardCharsets.UTF_8))

    private fun parse(text: String) = ProfileImport.parse(text, ctx = BuildContext.DEFAULT)

    @Test
    fun `standard base64 share-link body imports every node`() {
        val result = parse(standard("$link\n$second"))

        assertEquals(listOf("Node A", "Node B"), result.outbounds.map { it.name })
        assertTrue(result.messages.none { it.startsWith("[error]") })
    }

    @Test
    fun `wrapped MIME base64 body imports every node`() {
        val result = parse(mime("$link\n$second"))

        assertEquals(2, result.outbounds.size)
        assertEquals("example.org", result.outbounds[1].server)
    }

    @Test
    fun `url-safe unpadded base64 body imports`() {
        // The link body is valid utf-8 but not a syntactically valid stand-alone share link.
        val result = parse(urlSafe("$link\n$second"))

        assertEquals(2, result.outbounds.size)
    }

    @Test
    fun `base64 JSON outbound config imports`() {
        val json = """[{"type":"shadowsocks","tag":"json-node","server":"json.example","server_port":8388,"method":"aes-256-gcm","password":"secret"}]"""
        val result = parse(standard(json))

        assertEquals(1, result.outbounds.size)
        assertEquals("json-node", result.outbounds.single().name)
        assertEquals("json.example", result.outbounds.single().server)
    }

    @Test
    fun `plain share-link body also imports`() {
        val result = parse("$link\n$second")

        assertEquals(2, result.outbounds.size)
    }

    @Test
    fun `empty and invalid bodies fail closed without nodes`() {
        assertTrue(parse("").outbounds.isEmpty())
        assertTrue(parse("not-base64-and-not-a-link").outbounds.isEmpty())
    }

    @Test
    fun `a decoded body that is still invalid does not partially invent profiles`() {
        val result = parse(standard("this is not a supported configuration"))

        assertTrue(result.outbounds.isEmpty())
        assertFalse(result.messages.isEmpty())
    }
}
