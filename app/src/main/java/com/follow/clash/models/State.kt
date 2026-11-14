package com.follow.clash.models

/**
 * The shared-state payload FlClash syncs before a run. Throne's service reads
 * only what its own model owns: the run labels and whether the caller wants a
 * VPN tunnel or a proxy-only service. Clash-specific VPN construction details
 * are deliberately not mirrored here — Throne builds its tun from its own
 * route and inbound settings.
 */
data class SharedState(
    val startTip: String = "Starting VPN...",
    val stopTip: String = "Stopping VPN...",
    val localNetworkTip: String = "Local network unavailable.",
    val currentProfileName: String = "FlClash",
    val stopText: String = "Stop",
    val onlyStatisticsProxy: Boolean = false,
    val showStopAction: Boolean = true,
    val vpnOptions: VpnOptionsState? = null,
)

data class VpnOptionsState(
    val enable: Boolean = true,
)
