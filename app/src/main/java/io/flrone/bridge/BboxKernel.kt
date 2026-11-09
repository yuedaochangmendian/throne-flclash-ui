// The Dart-driven kernel's slim Kotlin surface (zero AIDL, zero cross-process).
//
// With the rebuilt core present, Dart controls the kernel directly over dart:ffi:
// it builds the core config here (the one thing that still owns the profile DB),
// persists what the DB owns, and leaves every kernel call to the FFI bindings.
// The old handlers in ThroneBoxBridge stay for the fallback path — the same
// actions answer both until the rebuilt AAR is proven in CI.
package io.flrone.bridge

import io.nekohasekai.sagernet.bg.BaseService
import io.nekohasekai.sagernet.bg.proto.BoxInstance
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.SagerDatabase
import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.ktx.Logs
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
     * How an SSID/BSSID change reaches Dart in ffiMode. The monitor has to live on the Android
     * side (it owns the ConnectivityManager callback), but the core that must re-read the state
     * is Dart's, so the change is announced rather than applied here.
     */
    @Volatile
    var onWifiChanged: (() -> Unit)? = null

    /**
     * The numeric Instance handle Dart registered for the running core. The Go
     * handle table is process-wide, so it survives the Dart isolate: after a
     * Flutter-engine death the host is the only side that can still close it.
     * Dart clears it on every stop and failed start; a stale registration is
     * exactly the case the host must take over. 0 means no adopted core.
     */
    @Volatile
    var kernelHandle: Long = 0L

    /** Dart -> host: register the running core's handle, or clear it. */
    fun adoptHandle(handle: Long?) {
        kernelHandle = handle?.takeIf { it > 0L } ?: 0L
    }

    /**
     * Closes the core whose Dart owner is gone. Read-and-clear first so only one
     * stop uses the handle; a second stop must not close it twice. A core that is
     * already gone only sets last_error on the Go side — never a failed stop.
     */
    fun closeAdoptedCore() {
        val handle = kernelHandle
        if (handle == 0L) return
        kernelHandle = 0L
        try {
            io.flrone.core.Core.closeInstance(handle)
            Logs.i("[lifecycle] host closed adopted core handle=$handle")
        } catch (error: Throwable) {
            Logs.w("adopted core handle=$handle could not be closed: ${error.message}")
        }
    }

    /**
     * How a non-Dart stop (widget/tile/notification) reaches the FFI driver:
     * true when the UI is attached and was told to close the core itself, false
     * when the engine is gone and the host must close the adopted handle.
     */
    @Volatile
    var onStopWanted: (() -> Boolean)? = null

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

    /**
     * The running-config facts the service used to write right after `proxy.init()`
     * (`runningProfiles` and `runningRouteId`). They are not decoration: `ProfileManager.runningUses`
     * reads the first to refuse deleting a node a running chain still uses, and
     * `RouteManager.runningRouteId` reads the second to decide whether a group's routing change
     * needs a reload. Dart owns the core now, so it reports them here once the start actually
     * succeeded — writing them in [buildStartOptions] would leave stale values behind whenever the
     * core refuses to come up.
     */
    fun markRunning(involvedProfileIds: List<Long>, routeId: Long) {
        DataStore.runningProfiles = involvedProfileIds.map { it.toString() }
        DataStore.runningRouteId = routeId
    }

    /** The stop half of [markRunning]: nothing is running, so nothing may look like it is. */
    fun clearRunning() {
        DataStore.runningProfiles = emptyList()
        DataStore.runningRouteId = 0L
    }

    /**
     * Hands the control plane over when the service came up first (START_STICKY, always-on VPN, a
     * widget): its `startProxy` ran with [ffiMode] still false and built a ProxyInstance. Two boxes
     * on one tun fight over the same descriptor, so the service-side one is stopped and the service
     * restarted in place — with [ffiMode] now true, that start keeps the notification and leaves the
     * core to Dart.
     *
     * @return true only when a service-side box was actually stopped, so the caller knows the
     *   tunnel is down and has to be rebuilt. A stop that was declined (the service is already
     *   `State.Stopping`) is NOT a hand-over: reporting true there would make Dart start a new
     *   core while the previous close still owns the tun.
     */
    fun handOver(): Boolean {
        val service = DataStore.baseService ?: return false
        // `changeState` keeps these two in sync, but stopRunner guards on `data.state`
        // directly. Check both so an in-flight stop can never be mistaken for ours.
        if (service.data.state == BaseService.State.Stopping ||
            !DataStore.serviceState.canStop
        ) return false
        if (service.data.proxy == null) return false
        return try {
            service.stopRunner(restart = true)
            // stopRunner sets State.Stopping synchronously before it returns. If it
            // declined our call, the state is still something else.
            service.data.state == BaseService.State.Stopping
        } catch (error: Throwable) {
            // A failed stop is not a hand-over; Dart must not rebuild onto it.
            false
        }
    }

    /** The mode switch's persist half; Dart reloads the core itself (FFI). */
    fun setMode(mode: String) {
        BboxMode.set(BboxMode.Mode.of(mode))
        // Writing the store is not enough: BboxBridge caches the mode in its UI state
        // and re-publishes that cache every second. Without this refresh the pump kept
        // pushing the *old* mode, so it stomped the value Dart had just pushed and the
        // mode chips kept highlighting the previous choice until some unrelated catalog
        // change happened to rebuild the state. BboxCommands.setMode does the same.
        BboxBridge.scheduleRefresh(immediate = true)
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
