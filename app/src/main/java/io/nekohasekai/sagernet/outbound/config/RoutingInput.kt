package io.nekohasekai.sagernet.outbound.config

import io.nekohasekai.sagernet.outbound.BuildContext
import io.nekohasekai.sagernet.outbound.Outbound
import io.nekohasekai.sagernet.route.RouteProfile
import io.nekohasekai.sagernet.route.RuleSetCatalog

/**
 * What a started config reads besides the settings and the outbounds (calculatePrerequisites, buildRouteSection,
 * buildAutoSelectorGroup): the route profile named by current_route_id (null when it does not exist), the srslist.h
 * names that rule_set entries may use, the tracked groups of auto-selectors and, where the core is loaded, the
 * core's verdict on auto-selector members. Test configs never read any of them (generate.cpp BuildTestConfig).
 */
class RoutingInput @JvmOverloads constructor(
    @JvmField val profile: RouteProfile?,
    @JvmField val catalog: RuleSetCatalog,
    @JvmField val selectors: SelectorStore = SelectorStore.NONE,
    /** Null skips the core check: members are then checked structurally only. */
    @JvmField val memberCheck: MemberCheck? = null,
    /**
     * The outbound mode replaced this profile's rules on purpose (Global/Direct), so the build
     * must not add anything back.
     *
     * The global added-rules pool is prepended inside the generator, *after* this input is handed
     * over, and `BboxMode.applyTo` only rewrites the profile it was given — it knows nothing about
     * the pool. Without this flag Global mode cleared the profile's rules and the pool then put
     * routing right back, so the switch looked like it did nothing.
     */
    @JvmField val rulesReplacedByMode: Boolean = false,
) {
    companion object {
        /** The built-in Default profile (RouteProfile::GetDefaultChain) and no rule-set names. */
        @JvmField
        val DEFAULT = RoutingInput(RouteProfile.defaultProfile(), RuleSetCatalog(emptyList()))
    }
}

/**
 * IsValid's core half (generate.cpp:2466-2525) for the members an auto-selector is about to build
 * (invalidProfileIDs, :1602-1620): one member the core rejects would fail the whole start, so it is dropped.
 */
fun interface MemberCheck {
    /** The rejected member ids with the core's message; [members] already passed the structural check. */
    fun rejected(members: List<Pair<Long, Outbound>>, ctx: BuildContext): Map<Long, String>
}
