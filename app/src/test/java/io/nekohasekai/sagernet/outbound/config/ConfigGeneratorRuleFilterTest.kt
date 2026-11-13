// The rule transforms a build applies (ADR 0002, phase 3c follow-up).
//
// Two behaviours live here, and one of them was wrong until now:
//
//  * a disabled rule must not reach the generated config. The editor writes the flag, the rule
//    list renders "Disabled", and the pool travels with it — but the filter ran before the
//    global pool joined the list, so a pool rule switched off in the UI still ran in the build.
//  * the Linux-only `bypass` action becomes `route` to the same outbound (D12), so it feeds the
//    DNS and tun lists like any other route rule.
package io.nekohasekai.sagernet.outbound.config

import io.nekohasekai.sagernet.route.RouteProfile
import io.nekohasekai.sagernet.route.RouteRule
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConfigGeneratorRuleFilterTest {

    private fun rule(name: String, disabled: Boolean = false, action: String = "route") =
        RouteRule().also {
            it.name = name
            it.disabled = disabled
            it.action = action
        }

    private fun profileOf(vararg rules: RouteRule) = RouteProfile().also {
        it.rules = rules.toMutableList()
    }

    @Test
    fun `a disabled rule does not reach the build`() {
        val profile = profileOf(rule("on"), rule("off", disabled = true))

        ConfigGenerator.applyBuildRuleFilters(profile)

        assertEquals(listOf("on"), profile.rules.map { it.name })
    }

    @Test
    fun `a disabled pool rule is filtered the same as a profile rule`() {
        // This is the regression: the pool is prepended to `profile.rules` before the filter
        // runs, so a pool rule carries the same `disabled` flag into the list. Filtering only
        // before the join left the pool's off switch decorative.
        val poolRule = rule("pool-off", disabled = true)
        val poolRuleOn = rule("pool-on")
        val profile = profileOf(rule("own"))
        profile.rules.addAll(0, listOf(poolRule, poolRuleOn))

        ConfigGenerator.applyBuildRuleFilters(profile)

        assertEquals(listOf("pool-on", "own"), profile.rules.map { it.name })
    }

    @Test
    fun `bypass becomes route`() {
        val profile = profileOf(rule("b", action = "bypass"))

        ConfigGenerator.applyBuildRuleFilters(profile)

        assertEquals("route", profile.rules.single().action)
    }

    @Test
    fun `the bypass rewrite also covers a pool rule`() {
        // The pool joins the list before this loop, so its rules are rewritten too. A pool rule
        // left as `bypass` would be dropped from the DNS and tun lists while still routing.
        val profile = profileOf(rule("own"))
        profile.rules.addAll(0, listOf(rule("pool-bypass", action = "bypass")))

        ConfigGenerator.applyBuildRuleFilters(profile)

        assertEquals(listOf("route", "route"), profile.rules.map { it.action })
    }

    @Test
    fun `other actions are left alone`() {
        val profile = profileOf(
            rule("reject", action = "reject"),
            rule("hijack", action = "hijack-dns"),
            rule("options", action = "route-options"),
        )

        ConfigGenerator.applyBuildRuleFilters(profile)

        assertEquals(
            listOf("reject", "hijack-dns", "route-options"),
            profile.rules.map { it.action },
        )
    }

    @Test
    fun `an all-disabled list empties`() {
        val profile = profileOf(rule("a", disabled = true), rule("b", disabled = true))

        ConfigGenerator.applyBuildRuleFilters(profile)

        assertTrue(profile.rules.isEmpty())
    }

    @Test
    fun `an empty list stays empty`() {
        val profile = profileOf()

        ConfigGenerator.applyBuildRuleFilters(profile)

        assertFalse(profile.rules.isNotEmpty())
    }
}
