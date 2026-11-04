// The Dart-driven kernel's slim Kotlin surface (zero AIDL, zero cross-process).
//
// With the rebuilt core present, Dart controls the kernel directly over dart:ffi:
// it builds the core config here (the one thing that still owns the profile DB),
// persists what the DB owns, and leaves every kernel call to the FFI bindings.
// The old handlers in ThroneBoxBridge stay for the fallback path — the same
// actions answer both until the rebuilt AAR is proven in CI.
package io.throne.bbox.bridge

import io.nekohasekai.sagernet.bg.proto.BoxInstance
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.SagerDatabase
import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.ui.warp.WarpClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

object BboxKernel {

    /** True once Dart announced the FFI path; the bg start path then skips the core. */
    @Volatile
    var ffiMode: Boolean = false

    /**
     * How a non-Dart reload (widget, tile, notification) reaches Dart in ffiMode:
     * the bridge plugs an emitter here so BaseService.reload can ask the FFI
     * driver to rebuild the core without bouncing the service.
     */
    @Volatile
    var onReloadWanted: (() -> Unit)? = null

    /**
     * Builds the StartOptions payload for the selected profile exactly as the
     * service start path does (BoxInstance.init) — including the Xray asset fetch
     * and dashboard install — but without creating a gobind Instance: the caller
     * starts the core itself through the FFI bindings. The native DB is the sole
     * source of truth; no profile id crosses the channel.
     */
    suspend fun buildStartOptions(): Map<String, Any?> = withContext(Dispatchers.IO) {
        val profile = resolveProfile()
            ?: error("No profile selected: add or import a profile before starting the core")
        val capture = StartOptionsCapture(profile)
        capture.init()
        try {
            capture.options
        } finally {
            capture.close()
        }
    }

    /** The mode switch's persist half; Dart reloads the core itself (FFI). */
    fun setMode(mode: String) {
        BboxMode.set(BboxMode.Mode.of(mode))
    }

    /**
     * The [warpRegister] result landing: the identity the kernel returned, saved
     * like BboxWarp.register does so the generated keys survive into the config.
     */
    fun completeWarp(
        tunnelType: String,
        identity: WarpClient.Identity,
        packets: List<String>,
        packetsError: String?,
    ): Map<String, Any?> = BboxWarp.complete(tunnelType, identity, packets, packetsError)

    /**
     * Resolves the ProxyEntity to start. B-box's profile cards carry *group* ids
     * and the Flutter preference store carries UI settings only, so a 0, a stale
     * id or a group id is never a valid proxy id: the native selection
     * (DataStore.selectedProxy) is the single source of truth. A fresh install
     * whose nodes were imported but never selected falls back to the first one.
     */
    private fun resolveProfile(): ProxyEntity? {
        val dao = SagerDatabase.proxyDao
        val selected = DataStore.selectedProxy
        if (selected > 0L) dao.getById(selected)?.let { return it }
        val first = dao.getAll().firstOrNull() ?: return null
        DataStore.selectedProxy = first.id
        return first
    }

    /** BoxInstance.init minus loadConfig: the build half the FFI caller needs. */
    private class StartOptionsCapture(profile: ProxyEntity) : BoxInstance(profile) {

        var options: Map<String, Any?> = emptyMap()
            private set

        override suspend fun loadConfig() {
            val auto = config.autoSelector
            options = mapOf(
                "coreConfig" to core.coreConfig,
                "needXray" to core.needXray,
                "xrayConfig" to (core.xrayConfig ?: ""),
                "xrayDnsStrategy" to core.xrayDnsStrategy,
                "xrayFullConfigs" to core.xrayFullConfigs,
                // toStartOptions: the idle window must outlast the probe interval.
                "autoSelectorIntervalSec" to (auto?.intervalSec ?: 0),
                "involvedProfileIds" to config.involvedProfileIds.toList(),
                "routeId" to routeId,
            )
        }
    }
}
