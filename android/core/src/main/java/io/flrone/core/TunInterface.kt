// The tun-scoped Android duties, passed to Core.startTun per the bettbox shape:
// the kernel reaches these through throne_callbacks_t (protect / resolver_process).
package io.flrone.core

interface TunInterface {
    /** VpnService.protect(fd) — keep a socket out of the VPN. */
    fun protect(fd: Int)

    /** Package name owning the connection, or "" when unknown. */
    fun resolverProcess(protocol: Int, source: String, target: String, uid: Int): String
}
