package io.nekohasekai.sagernet.bg

/**
 * Renders the `{key}` placeholders in the service notification templates.
 *
 * Kept free of Android types on purpose: the JVM unit test can pin the
 * substitution rules without a device, and this object is never touched while
 * the VPN service is starting.
 *
 * Both braces in the pattern are escaped. Android delegates regex compilation
 * to ICU, which rejects a lone unescaped `}` with U_REGEX_RULE_SYNTAX, while
 * the JVM's java.util.regex.Pattern accepts it as a literal. That difference
 * is why the pattern must not live in ServiceNotification's companion object:
 * there a bad pattern becomes ExceptionInInitializerError on onStartCommand
 * and takes the whole VPN service down.
 */
object NotificationTemplate {
    private val PLACEHOLDER = Regex("""\{([A-Za-z]+)\}""")

    /**
     * One pass over [template]: a value that itself contains `{up}` is never
     * substituted again (a lambda replacement is not re-scanned), and a key
     * absent from [values] keeps its `{key}` text verbatim.
     */
    fun render(template: String, values: Map<String, String>): String =
        PLACEHOLDER.replace(template) { match ->
            values[match.groupValues[1]] ?: match.value
        }
}
