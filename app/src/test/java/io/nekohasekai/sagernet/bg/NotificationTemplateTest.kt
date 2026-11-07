package io.nekohasekai.sagernet.bg

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pure-JVM tests for the notification template renderer.
 *
 * These pin the substitution semantics, but they CANNOT catch a regex-dialect
 * bug: the JVM accepts an unescaped `}` that Android's ICU rejects. The dialect
 * half is covered by kotlin_regex_audit.py in CI and by a device smoke test
 * before release.
 */
class NotificationTemplateTest {

    @Test
    fun `substitutes every built-in key`() {
        val values = mapOf(
            "title" to "Tokyo 01",
            "up" to "1.2 MB/s",
            "down" to "3.4 MB/s",
            "directUp" to "10 kB/s",
            "directDown" to "20 kB/s",
            "totalUp" to "1 GB",
            "totalDown" to "2 GB",
        )
        assertEquals(
            "Tokyo 01 | 1.2 MB/s / 3.4 MB/s | 10 kB/s / 20 kB/s | 1 GB / 2 GB",
            NotificationTemplate.render(
                "{title} | {up} / {down} | {directUp} / {directDown} | {totalUp} / {totalDown}",
                values,
            ),
        )
    }

    @Test
    fun `unknown keys stay verbatim`() {
        assertEquals(
            "Tokyo 01 {nope}",
            NotificationTemplate.render("{title} {nope}", mapOf("title" to "Tokyo 01")),
        )
    }

    @Test
    fun `a value containing a placeholder is not substituted again`() {
        // The one-pass rule: a profile name can literally contain "{up}".
        assertEquals(
            "node {up} / 5 MB/s",
            NotificationTemplate.render(
                "{title} / {up}",
                mapOf("title" to "node {up}", "up" to "5 MB/s"),
            ),
        )
    }

    @Test
    fun `non-ascii keys empty braces and unclosed braces stay literal`() {
        val template = "{标题} {} {up {a1}"
        assertEquals(
            template,
            NotificationTemplate.render(template, mapOf("up" to "x", "a" to "y")),
        )
    }

    @Test
    fun `empty template and empty values are no-ops`() {
        assertEquals("", NotificationTemplate.render("", mapOf("up" to "x")))
        assertEquals("{up}", NotificationTemplate.render("{up}", emptyMap()))
    }

    @Test
    fun `plain text without placeholders is untouched`() {
        assertEquals("just text", NotificationTemplate.render("just text", mapOf("up" to "x")))
    }
}
