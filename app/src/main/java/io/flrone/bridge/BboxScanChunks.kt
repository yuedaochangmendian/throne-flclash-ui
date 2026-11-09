package io.flrone.bridge

import io.nekohasekai.sagernet.outbound.OutboundFactory

/**
 * Assembles the frames of a QR code into one payload, and decides when it is complete.
 *
 * A QR too large for one symbol arrives as several frames whose texts differ; a normal one repeats
 * the same text on every camera frame. Both cases are handled by the same two rules: a frame that
 * the buffer already holds is not appended again (the camera re-delivers a frame many times a
 * second, and cycling frames A,B,A,B must not build "ABAB"), and a frame that adds nothing means
 * the symbol has stopped changing — so it is complete, whatever its text looks like.
 *
 * Before, completeness was decided by the payload's shape alone: a URL, a `{`-prefixed JSON
 * document, a share link. Everything else — a base64 subscription, a YAML document — never
 * completed, and the camera kept re-appending the same text, so the screen sat at "0 / 1" while the
 * buffer grew without bound.
 */
internal class BboxScanChunks {

    /** What has arrived for one session so far, plus the decision for this frame. */
    data class Decision(val text: String, val complete: Boolean)

    private val buffers = HashMap<String, StringBuilder>()
    private val lastAssembled = HashMap<String, String>()

    /** Drops everything a session accumulated; called when the screen closes or a payload is taken. */
    @Synchronized
    fun reset(session: String) {
        buffers.remove(session)
        lastAssembled.remove(session)
    }

    @Synchronized
    fun accept(session: String, text: String): Decision {
        val buffer = buffers.getOrPut(session) { StringBuilder() }
        val chunk = text.trim()
        // A frame already in the buffer is a re-delivery (or a cycle back to an earlier frame).
        // Appending it again is what corrupted multi-frame payloads and inflated single-frame ones.
        if (chunk.isNotEmpty() && buffer.indexOf(chunk) < 0) buffer.append(chunk)
        val assembled = buffer.toString().trim()
        val unchanged = assembled == lastAssembled[session]
        lastAssembled[session] = assembled
        return Decision(assembled, complete = unchanged || looksComplete(assembled))
    }

    /** The shapes that are complete on their own, whatever the frame count. */
    private fun looksComplete(payload: String): Boolean {
        val firstLine = payload.lineSequence().firstOrNull().orEmpty()
        return payload.startsWith("http://", true) ||
            payload.startsWith("https://", true) ||
            payload.startsWith("sing-box://", true) ||
            payload.startsWith("{") ||
            firstLine.startsWith("throne://add/", true) ||
            firstLine.startsWith("json://", true) ||
            OutboundFactory.typeForScheme(firstLine) != null
    }
}
