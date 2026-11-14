package io.throne.bbox.corehost

import android.net.VpnService
import com.follow.clash.common.GlobalState
import io.nekohasekai.sagernet.SagerNet
import io.nekohasekai.sagernet.bg.BaseService
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.GroupRepo
import io.nekohasekai.sagernet.database.ProfileManager
import io.nekohasekai.sagernet.ktx.Logs
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicLong

/**
 * FlClash's Android lifecycle on top of Throne's own foreground service.
 *
 * This is not a second proxy runtime: SagerNet/VpnService remains the only owner
 * of the tunnel and ProxyInstance. The class only supplies the lifecycle contract
 * FlClash's Service plugin and SetupAction already understand.
 */
object ThroneServiceController {
    private var initialized = false

    // Written by requests on the platform thread and cleared by the stop watcher on a background
    // coroutine, so the read in awaitRunTime has to see the latest value.
    @Volatile
    private var startedAt = 0L
    private var lastSharedState = ""
    private val revision = AtomicLong()
    private val _running = MutableStateFlow(false)
    val running: StateFlow<Boolean> = _running

    /**
     * The run intent, upstream's `ServiceState.isRunRequested`: true from a start request until the
     * run is over. It is what tells a real stop from a tunnel that was only swapped under a restart.
     */
    @Volatile
    private var runRequested = false

    /** Set by ServicePlugin; reports a stop that no command of the plugin asked for. */
    @Volatile
    private var stoppedListener: (() -> Unit)? = null

    private var stateWatcherStarted = false

    val isRunRequested: Boolean
        get() = runRequested

    @Synchronized
    fun initialize() {
        if (initialized) return
        initialized = true
        // Only a reference to a service that is gone is stale. A live tunnel keeps its
        // VpnService: `openTun` and socket protect() read it on every core (re)start, and
        // clearing it under a running service fails the next reload with "no VpnService".
        if (!DataStore.serviceState.canStop) DataStore.vpnService = null
        _running.value = DataStore.serviceState.canStop
        // A process that comes up beside a running service (START_STICKY, always-on VPN) is in
        // the same run as the one that started it, so the intent is seeded from the service. An
        // intent already set here — a shortcut or broadcast that started the tunnel before Flutter
        // initialized — is a newer request and must not be cleared by the seed.
        if (!runRequested) runRequested = DataStore.serviceState.canStop
        startStateWatcher()
    }

    fun isRunning(): Boolean = DataStore.serviceState.canStop

    /**
     * Registers (or clears) the receiver of "the tunnel went away" reports. Throne keeps the
     * service state in a plain `@Volatile` field rather than a Flow, so the transition is found by
     * [startStateWatcher].
     */
    @Synchronized
    fun setStoppedListener(listener: (() -> Unit)?) {
        stoppedListener = listener
    }

    /**
     * Clears [listener] only while it is still the registered one: an engine that detaches after a
     * new one attached must not take the new listener down with it.
     */
    @Synchronized
    fun clearStoppedListener(listener: (() -> Unit)?) {
        if (stoppedListener === listener) stoppedListener = null
    }

    suspend fun syncState(json: String): String {
        lastSharedState = json
        val state = JSONObject(json)
        // Throne generates its own tunnel options from the route and inbound
        // settings. A Clash-style `tun.enable = false` selects proxy-only mode;
        // the UI's other Clash-specific VPN fields are not silently forwarded.
        val enable = state.optJSONObject("vpnOptions")?.optBoolean("enable", true) ?: true
        DataStore.serviceMode = if (enable) "vpn" else "proxy"
        return ""
    }

    fun requestStart() {
        // A launcher shortcut or a broadcast can be the first thing this process serves, before
        // Flutter ever sent "init"; the stop watcher has to exist for that run too. Only the
        // watcher is started here — initialize() also clears a VpnService left by a dead process,
        // and doing that from a request path could drop the reference a starting service needs.
        startStateWatcher()
        val ticket = revision.incrementAndGet()
        runRequested = true
        _running.value = true
        startedAt = System.currentTimeMillis()
        GlobalState.launch {
            // The group the UI is on, not the first tab: switching tabs selects a group without
            // selecting a member, so DataStore.selectedProxy can still name a profile of another
            // group (or none at all). GroupRepo.currentId() also repoints a stored group id whose
            // group is gone. A failure here must not keep the tunnel from starting, so a broken
            // selection falls back to whatever the profile id already said.
            val selected = runCatching {
                val groupId = GroupRepo.currentId()
                DataStore.selectedProxy
                    .takeIf { it > 0 && ProfileManager.getProfile(it)?.groupId == groupId }
                    ?: ProfileManager.memberIds(groupId).firstOrNull()
                    ?: 0L
            }.getOrElse {
                Logs.w("resolve start profile: ${it.message}")
                DataStore.selectedProxy
            }
            DataStore.selectedProxy = selected
            if (selected > 0) {
                // The panel already shows "the profile being run"; the service confirms it once
                // the tunnel is up, but a stale value would be shown until then.
                DataStore.currentProfile = selected
            }
            SagerNet.startService()
            // A stopped report from before a newer request must not cancel it.
            if (ticket == revision.get()) _running.value = DataStore.serviceState.canStop
        }
    }

    fun requestStop() {
        revision.incrementAndGet()
        runRequested = false
        _running.value = false
        startedAt = 0L
        GlobalState.launch { SagerNet.stopService() }
    }

    suspend fun awaitRunTime(): Long {
        withTimeoutOrNull(5_000) {
            while (!DataStore.serviceState.canStop) delay(100)
        }
        return if (DataStore.serviceState.canStop) startedAt else 0L
    }

    fun isVpnPermissionGranted(): Boolean =
        VpnService.prepare(GlobalState.application) == null

    fun currentState(): BaseService.State = DataStore.serviceState

    /**
     * Watches [DataStore.serviceState] for a transition into [BaseService.State.Stopped] and reports
     * it, so the Flutter side stops believing in a tunnel that the system, the notification or the
     * OS took away (upstream did the same from its StateMachine).
     *
     * The field is a `@Volatile var` written by [BaseService.Data.changeState], not a Flow: there is
     * no subscription to take, and adding a listener to BaseService would mean editing the
     * foreground service's own state path. A short poll is the smallest change that cannot lose a
     * transition — every write is visible here, and a stop that lands between two reads is still
     * seen by the read after it.
     *
     * `Stopped` is also a waypoint of a restart (`stopRunner(restart = true)` passes through it on
     * its way back to Connecting), so the state has to stay Stopped for a full confirmation window
     * before it counts. A restart reaches Connecting within milliseconds on the keep-notification
     * path and within a service start otherwise; a real stop stays Stopped until the next request.
     */
    private fun startStateWatcher() {
        if (stateWatcherStarted) return
        stateWatcherStarted = true
        GlobalState.launch {
            var previous = DataStore.serviceState
            while (true) {
                delay(STATE_POLL_MILLIS)
                val current = DataStore.serviceState
                if (current == previous) continue
                previous = current
                if (current != BaseService.State.Stopped) continue
                if (!awaitStoppedConfirmed()) continue
                // Only a stop nobody asked for: a start/stop command clears the intent before the
                // service reports back, and its own plugin already told Dart.
                if (!runRequested) continue
                runRequested = false
                _running.value = false
                startedAt = 0L
                stoppedListener?.invoke()
                previous = DataStore.serviceState
            }
        }
    }

    /** True once the service has been observed stopped for [STOP_CONFIRM_MILLIS] without a bounce. */
    private suspend fun awaitStoppedConfirmed(): Boolean {
        var waited = 0L
        while (waited < STOP_CONFIRM_MILLIS) {
            delay(STATE_POLL_MILLIS)
            waited += STATE_POLL_MILLIS
            if (DataStore.serviceState != BaseService.State.Stopped) return false
        }
        return true
    }

    private const val STATE_POLL_MILLIS = 200L
    private const val STOP_CONFIRM_MILLIS = 1_000L
}
