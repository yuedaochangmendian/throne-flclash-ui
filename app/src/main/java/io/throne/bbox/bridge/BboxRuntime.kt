package io.throne.bbox.bridge

import io.nekohasekai.sagernet.outbound.config.RoutingInput

/**
 * Process-wide entry point for the Throne runtime pieces the FlClash Core host
 * shares: the outbound-mode routing rewrite and (through the other files in
 * this package) the core platform callbacks. There is no UI state pump here —
 * the presentation talks to [io.throne.bbox.corehost.ThroneCore] directly.
 */
object BboxRuntime {

    /**
     * The routing input a start should use: the user's route profile, rewritten when the
     * outbound mode is Global or Direct. Called by
     * [io.nekohasekai.sagernet.bg.proto.CoreConfigs] so a reload from anywhere (tile,
     * shortcut, notification) honours the mode too.
     */
    fun routingInput(base: RoutingInput): RoutingInput = BboxMode.applyTo(base)
}
