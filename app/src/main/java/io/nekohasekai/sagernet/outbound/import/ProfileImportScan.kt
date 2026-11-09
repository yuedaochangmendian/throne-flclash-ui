package io.nekohasekai.sagernet.outbound.import

import io.nekohasekai.sagernet.outbound.link.Base64Strict

/** Subscription::scan (include/configs/sub/SubscriptionScan.hpp) on strings. */
internal object ProfileImportScan {
    private fun isSpace(c: Char): Boolean =
        c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\u000B' || c == '\u000C'

    private fun isBase64Char(c: Char): Boolean =
        c in 'A'..'Z' || c in 'a'..'z' || c in '0'..'9' || c == '+' || c == '/' || c == '='

    private fun isUrlSafeBase64Char(c: Char): Boolean =
        c in 'A'..'Z' || c in 'a'..'z' || c in '0'..'9' || c == '-' || c == '_' || c == '='

    /** scan::trim: ASCII whitespace and NBSP on both ends, a BOM at the front. */
    fun trim(s: String): String {
        var start = 0
        var end = s.length
        while (start < end) {
            val c = s[start]
            if (isSpace(c) || c == '\u00A0' || c == '\uFEFF') start++ else break
        }
        while (end > start) {
            val c = s[end - 1]
            if (isSpace(c) || c == '\u00A0') end-- else break
        }
        return s.substring(start, end)
    }

    /** scan::matchingClose: the index of the bracket closing the one at [open], honouring JSON string escapes; -1 when unbalanced. */
    fun matchingClose(s: String, open: Int): Int {
        var depth = 0
        var inString = false
        var escaped = false
        var i = open
        while (i < s.length) {
            val c = s[i]
            if (inString) {
                when {
                    escaped -> escaped = false
                    c == '\\' -> escaped = true
                    c == '"' -> inString = false
                }
            } else if (c == '"') {
                inString = true
            } else if (c == '{' || c == '[') {
                depth++
            } else if (c == '}' || c == ']') {
                if (--depth == 0) return i
            }
            i++
        }
        return -1
    }

    /** scan::forEachLine: the segments of QString::split('\n'); [fn] returns false to stop. */
    fun forEachLine(s: String, fn: (String) -> Boolean) {
        var idx = 0
        while (true) {
            val nl = s.indexOf('\n', idx)
            if (nl < 0) {
                fn(s.substring(idx))
                return
            }
            if (!fn(s.substring(idx, nl))) return
            idx = nl + 1
        }
    }

    /** scan::forEachItem: one item per line, except that a line opening a bracket yields the whole balanced block. */
    fun forEachItem(s: String, fn: (String) -> Unit) {
        val n = s.length
        var idx = 0
        while (idx < n) {
            if (s[idx] == '\n') {
                idx++
                continue
            }
            if (s[idx] == '{' || s[idx] == '[') {
                val end = matchingClose(s, idx)
                if (end >= 0) {
                    fn(s.substring(idx, end + 1))
                    idx = end + 1
                    continue
                }
            }
            var nl = s.indexOf('\n', idx)
            if (nl < 0) nl = n
            fn(s.substring(idx, nl))
            idx = nl + 1
        }
    }

    fun looksLikeBase64(s: String): Boolean = s.isNotEmpty() && s.all { isBase64Char(it) }

    /** The url-safe alphabet, which only counts when a `-` or `_` proves it is not standard base64. */
    fun looksLikeUrlSafeBase64(s: String): Boolean =
        s.isNotEmpty() && s.all { isUrlSafeBase64Char(it) } && s.any { it == '-' || it == '_' }

    /** scan::looksLikeWrappedBase64: one blob wrapped at a fixed column, as `base64` and MIME emit it. */
    fun looksLikeWrappedBase64(s: String): Boolean {
        var width = 0
        var lines = 0
        var sawShort = false
        var ok = true
        forEachLine(s) { raw ->
            var line = raw
            while (line.isNotEmpty() && isSpace(line[line.length - 1])) line = line.substring(0, line.length - 1)
            if (line.isEmpty()) return@forEachLine true
            if (!line.all { isBase64Char(it) }) {
                ok = false
                return@forEachLine false
            }
            lines++
            if (width == 0) {
                width = line.length
                return@forEachLine true
            }
            if (line.length > width || sawShort) {
                ok = false
                return@forEachLine false
            }
            if (line.length < width) sawShort = true
            true
        }
        return ok && lines >= 2 && width % 4 == 0
    }

    /** scan::decodeBase64 (AbortOnBase64DecodingErrors): null when invalid or empty. */
    fun decodeBase64(s: String): String? = Base64Strict.decode(s)?.takeIf { it.isNotEmpty() }?.let { String(it, Charsets.UTF_8) }

    fun decodeBase64UrlSafe(s: String): String? =
        Base64Strict.decode(s, urlSafe = true)?.takeIf { it.isNotEmpty() }?.let { String(it, Charsets.UTF_8) }

    /** QByteArray::fromBase64 without abort: characters outside the alphabet (line breaks, padding) are skipped. */
    fun decodeBase64Lenient(s: String): String? {
        val filtered = s.filter { it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '+' || it == '/' }
        return decodeBase64(filtered)
    }
}
