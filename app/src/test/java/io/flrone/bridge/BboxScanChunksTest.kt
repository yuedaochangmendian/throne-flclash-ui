package io.flrone.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The scan assembly rules: a node link or URL is complete on its own, anything else becomes complete
 * when the frame stops changing, and a re-delivered frame is never appended twice.
 *
 * The second half is the regression: a base64 subscription (or a YAML document) matched none of the
 * shape rules, so the camera's repeated frames were appended over and over and the screen never left
 * "0 / 1".
 */
class BboxScanChunksTest {

    private val chunks = BboxScanChunks()

    @Test
    fun `a share link is complete on the first frame`() {
        val decision = chunks.accept("s1", "ss://YWVzLTI1Ni1nY206cGFzcw@example.com:8388#Node")

        assertTrue(decision.complete)
        assertEquals("ss://YWVzLTI1Ni1nY206cGFzcw@example.com:8388#Node", decision.text)
    }

    @Test
    fun `a subscription url is complete on the first frame`() {
        assertTrue(chunks.accept("s2", "https://example.com/sub?token=abc").complete)
    }

    @Test
    fun `a base64 payload completes when the frame stops changing`() {
        val payload = "c3M6Ly9ZV1Z6TFRJMU5pMW5ZMjA2Y0dGemN3QGV4YW1wbGUuY29tOjgzODg="

        val first = chunks.accept("s3", payload)
        assertFalse("a payload with no known shape is not complete on sight", first.complete)
        assertEquals(payload, first.text)

        val second = chunks.accept("s3", payload)
        assertTrue("the camera re-delivered the same frame: the symbol has stopped changing", second.complete)
        assertEquals("the frame must not be appended twice", payload, second.text)
    }

    @Test
    fun `a multi-frame payload assembles in order and completes on the repeat`() {
        val a = "c3M6Ly9ZV1Z6TFRJMU5pMW5a"
        val b = "MjA2Y0dGemN3QGV4YW1wbGUuY29t"

        assertFalse(chunks.accept("s4", a).complete)
        val joined = chunks.accept("s4", b)
        assertFalse(joined.complete)
        assertEquals(a + b, joined.text)

        // The scanner cycles back to the first frame; it is already in the buffer.
        val again = chunks.accept("s4", a)
        assertTrue(again.complete)
        assertEquals(a + b, again.text)
    }

    @Test
    fun `reset drops the session so the next scan starts clean`() {
        assertFalse(chunks.accept("s5", "cGFydC1vbmU=").complete)
        chunks.reset("s5")

        val decision = chunks.accept("s5", "cGFydC10d28=")
        assertFalse(decision.complete)
        assertEquals("cGFydC10d28=", decision.text)
    }
}
