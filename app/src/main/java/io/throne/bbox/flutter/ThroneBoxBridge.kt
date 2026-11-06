package io.throne.bbox.flutter

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.nekohasekai.sagernet.BuildConfig
import io.nekohasekai.sagernet.SagerNet
import android.os.Build
import android.os.Debug
import io.nekohasekai.sagernet.Key
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.SagerDatabase
import io.nekohasekai.sagernet.utils.CrashStore
import io.nekohasekai.sagernet.database.DnsServerHistory
import io.nekohasekai.sagernet.database.GroupRepo
import io.nekohasekai.sagernet.database.RouteManager
import io.nekohasekai.sagernet.database.SettingsRegistry
import io.nekohasekai.sagernet.group.SubscriptionClient
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ktx.app
import io.nekohasekai.sagernet.ktx.streamUri
import io.nekohasekai.sagernet.ui.json.engine.JsonTree
import io.nekohasekai.sagernet.ui.json.engine.JsonType
import io.nekohasekai.sagernet.ui.json.engine.JsonFormatter
import io.nekohasekai.sagernet.update.UpdateChecker
import moe.matsuri.nb4a.utils.LogRedactor
import moe.matsuri.nb4a.utils.CoreLog
import io.throne.bbox.bridge.BboxApi
import io.throne.bbox.bridge.BboxApps
import io.throne.bbox.bridge.BboxBackup
import io.throne.bbox.bridge.BboxBridge
import io.throne.bbox.bridge.BboxCommands
import io.throne.bbox.bridge.BboxEgress
import io.throne.bbox.bridge.BboxGroupsWire
import io.throne.bbox.bridge.BboxKernel
import io.throne.bbox.bridge.BboxLogcat
import io.throne.bbox.bridge.BboxLogs
import io.throne.bbox.bridge.BboxMemory
import io.throne.bbox.bridge.BboxMode
import io.throne.bbox.bridge.BboxProbeSession
import io.throne.bbox.bridge.BboxProfiles
import io.throne.bbox.bridge.BboxResolve
import io.throne.bbox.bridge.BboxRoutes
import io.throne.bbox.bridge.BboxScanChunks
import io.throne.bbox.bridge.BboxTestSession
import io.throne.bbox.bridge.BboxWarp
import io.throne.bbox.bridge.Capabilities
import io.throne.bbox.bridge.Apply
// Aliased: this file also uses android.provider.Settings for the battery-optimisation intents.
import io.throne.bbox.bridge.Settings as ThroneSettings
import io.throne.bbox.model.BboxUiState
import io.nekohasekai.sagernet.ui.warp.WarpClient
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Dispatchers
import okhttp3.OkHttpClient
import org.json.JSONArray
import org.json.JSONObject
import java.io.Closeable
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Proxy
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * The host side of B-box's own interface.
 *
 * B-box's Flutter screens talk to Android through exactly two channels — `io.flrone/box` for calls and
 * `io.flrone/events` for pushes — and know nothing about the app behind them. This class implements that
 * contract over Throne: the state comes from [BboxBridge], the writes go through [BboxCommands], and the payloads
 * are shaped the way the Dart side reads them (`box.dart`, `dashboard.dart`, `proxies.dart`, `profiles.dart`).
 *
 * Methods are grouped by whether the answer can be produced synchronously: anything that has to touch the database,
 * the package manager, the network or a system dialog goes through [respond], which moves it off the channel thread
 * and turns a thrown exception into the platform error the UI shows.
 *
 * A handful of screens ask for things Throne has no equivalent of — a terminal, SSH sessions, Tailscale, Taildrop,
 * USB devices and HTTP request capture. Those answer with an error, which the UI reports as a snackbar rather than
 * rendering something invented.
 */
class ThroneBoxBridge(
    private val activity: FragmentActivity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler, Closeable {

    private val channel = MethodChannel(messenger, "io.flrone/box")
    private val events = EventChannel(messenger, "io.flrone/events")

    private val scope = activity.lifecycleScope
    private var sink: EventChannel.EventSink? = null
    private var pump: Job? = null

    /** Bettbox's `tick1s`: one traffic sample per second, independent of whether a number changed. */
    private var ratesTick: Job? = null

    /** B-box keeps its interface preferences in a store of its own; so does the port. */
    private val preferences = activity.getSharedPreferences("bbox_ui", Context.MODE_PRIVATE)

    private var lastDashboard: Map<String, Any?>? = null
    private var lastRates: Map<String, Any?>? = null
    private var lastProfiles: List<Map<String, Any?>>? = null
    private var lastGroups: List<Map<String, Any?>>? = null

    /** True once `ready` has answered, so the pump does not repeat that snapshot as an event. */
    @Volatile
    private var readyServed = false

    /** The catalog revision and node-delivery flag the last pushed rows were built from. */
    private var sentCatalog: Pair<Long, Boolean>? = null

    /** Only the Proxies screen needs node rows; every other screen renders counts. */
    @Volatile
    private var groupsVisible = false

    /** The connections screen, the memory panel and the log screen each hold one subscription while they are open. */
    private var connectionsJob: Job? = null
    private var memoryJob: Job? = null

    /** Detaches the trim listener `attach` installs; null while the bridge is closed. */
    private var stopTrimObserver: (() -> Unit)? = null

    /** The update queue's change reports, for as long as the host lives. */
    private var reportsJob: Job? = null

    /** The batch test panel's state feed, polled only while the panel shows it. */
    private var testSessionJob: Job? = null

    @Volatile
    private var lastTestSession: Map<String, Any?>? = null

    /** QR scans that span several frames, and the completeness rule for a single-frame symbol. */
    private val scanChunks = BboxScanChunks()

    /** Probe sessions: one HTTP client per id, tunneled through the running service. */
    private val probes = ConcurrentHashMap<String, BboxProbeSession>()

    /** The URI the app was opened with, handed to the UI once. */
    private var pendingIntent: String? = null

    /** The intent instance whose payload was already offered to the UI; a repeat take must not re-deliver it. */
    private var deliveredIntent: Intent? = null

    /** Set when an intent arrived while no event sink was attached; raised again in [onListen]. */
    private var intentAvailablePending = false

    @Volatile
    private var lanBusy = false

    /** Set when a write only takes effect on a process restart, cleared once the UI was told. */
    @Volatile
    private var restartPending = false

    fun attach() {
        channel.setMethodCallHandler(this)
        events.setStreamHandler(this)
        // Memory pressure reaches the UI as an event: ART's own gc/trimHeap cannot collect Dart
        // objects, so the decoded-image cache and the UI's own lists only shrink if Dart is told.
        stopTrimObserver = BboxMemory.observeTrim { level -> emit("memoryTrim", mapOf("level" to level)) }
        // Subscription change reports (SubscriptionReportDialog.observe): popups, errors, status
        // lines and reload hints of the update queue, forwarded while the host is alive. A report
        // that arrives before the UI listens is dropped, as the native window drops them while closed.
        reportsJob = scope.launch {
            SubscriptionClient.reports.collect { report -> emitReport(report) }
        }
    }

    override fun close() {
        stopTrimObserver?.invoke()
        stopTrimObserver = null
        pump?.cancel()
        ratesTick?.cancel()
        connectionsJob?.cancel()
        memoryJob?.cancel()
        reportsJob?.cancel()
        testSessionJob?.cancel()
        BboxLogs.stop()
        BboxLogcat.stop()
        probes.keys.forEach { closeProbe(it) }
        channel.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
    }

    // ------------------------------------------------------------------------------------------------ events

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink?) {
        sink = eventSink
        if (intentAvailablePending) {
            intentAvailablePending = false
            emit("intentAvailable", true)
        }
        pump?.cancel()
        pump = scope.launch {
            BboxBridge.state
                .map { it.wireKey() }
                .distinctUntilChanged()
                .collect { pushState() }
        }
        // The dashboard sparkline is a window in time, not a list of changes: Bettbox appends one
        // sample per second (`tick1s`), so an idle tunnel scrolls to zero instead of freezing on
        // its last peak. A sample is pushed every second while the service runs, and not at all
        // while it is stopped — the window belongs to the session that produced it.
        //
        // In ffiMode this side owns no TrafficUpdater, so the meter stays at zero and a sample
        // would only push those zeros: the FFI driver's status feed is the sparkline's source
        // then, and the two would alternate on screen once a second.
        ratesTick?.cancel()
        ratesTick = scope.launch {
            while (isActive) {
                delay(1_000)
                if (!BboxKernel.ffiMode && DataStore.serviceState.connected) pushState(sampleRate = true)
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        pump?.cancel()
        pump = null
        ratesTick?.cancel()
        ratesTick = null
        sink = null
    }

    private fun emit(type: String, value: Any?) {
        activity.runOnUiThread {
            sink?.success(mapOf("type" to type, "value" to value))
        }
    }

    /**
     * Pushes whatever changed since the last push: the dashboard, the rates and the catalog are
     * separate events. [sampleRate] forces the rates through even when the numbers are identical,
     * because the sparkline needs one point per second rather than one per change.
     *
     * The catalog half is rebuilt only when `BboxBridge.catalogRevision` moved — a repository change
     * or the Proxies screen toggling node delivery — because a rates sample used to rebuild every
     * node row and structurally compare it once a second for nothing.
     */
    private fun pushState(sampleRate: Boolean = false) {
        // `ready` answers with this same snapshot; emitting it here too made the first frame build
        // and decode the whole catalog a second time.
        if (!readyServed) return
        val state = BboxBridge.state.value
        val dashboard = dashboardWire(state)
        if (dashboard != lastDashboard) {
            lastDashboard = dashboard
            emit("dashboard", dashboard)
        }
        val rates = mapOf(
            "upload" to state.dashboard.traffic.uploadRate,
            "download" to state.dashboard.traffic.downloadRate,
            "memoryBytes" to (state.dashboard.memory?.inUse ?: 0L),
        )
        if (sampleRate || rates != lastRates) {
            lastRates = rates
            emit("rates", rates)
        }
        val catalog = BboxBridge.catalogRevision to groupsVisible
        if (catalog == sentCatalog) return
        sentCatalog = catalog
        val profiles = profilesWire(state)
        if (profiles != lastProfiles) {
            lastProfiles = profiles
            emit("profiles", profiles)
        }
        val groups = groupsWire(state, withItems = groupsVisible)
        if (groups != lastGroups) {
            lastGroups = groups
            emit("groups", groups)
        }
    }

    /** The Proxies screen asks for node rows on open and gives them back on close. */
    private fun setGroupsVisible(visible: Boolean) {
        if (groupsVisible == visible) return
        groupsVisible = visible
        // The payload shape changes with the flag, so the previous copy is not a baseline for it.
        lastGroups = null
        pushState()
    }

    private fun BboxUiState.wireKey(): String = buildString {
        append(dashboard.status.running).append(dashboard.status.transitioning)
        append(dashboard.status.startedAt).append(dashboard.profile?.id)
        append(dashboard.traffic.uploadTotal).append(dashboard.traffic.downloadTotal)
        append(dashboard.traffic.uploadRate).append(dashboard.traffic.downloadRate)
        append(dashboard.memory?.inUse).append(dashboard.mode)
        // The catalog revision stands in for `groups.hashCode()` + `profiles.hashCode()`: those two
        // walked every node once a second to answer a question the revision already answers.
        append(BboxBridge.catalogRevision)
    }

    // ------------------------------------------------------------------------------------------------ calls

    /**
     * Runs [block] on the scope's dispatcher (the main thread) and answers the call with whatever it
     * produces. A thrown exception becomes the platform error whose message the UI shows, so a
     * failure is never a silent empty screen. A block that does I/O must switch dispatchers itself.
     */
    private fun MethodChannel.Result.respond(block: suspend () -> Any?) {
        if (!scope.isActive) {
            error("cancelled", "Activity closed", null)
            return
        }
        scope.launch {
            try {
                success(block())
            } catch (e: CancellationException) {
                error("cancelled", e.message ?: "Operation cancelled", null)
                throw e
            } catch (e: Exception) {
                Logs.w(e)
                error("failed", e.message ?: e.javaClass.simpleName, null)
            }
        }
    }

    /**
     * Starts the background service and, in VPN mode, waits until it exists before answering.
     *
     * `SagerNet.startService()` only posts a startForegroundService intent, so it returns before
     * the service object is created. Dart calls this immediately before the FFI kernel start, and
     * the core asks the platform for the tun as part of that start: with the wait removed, openTun
     * saw a null `DataStore.vpnService` and every start died with "configure tun interface:
     * bridge: platform callback failed". Answering the channel call only after the live VpnService
     * is registered makes the ordering deterministic instead of a race.
     */
    private suspend fun startServiceAndAwaitTun() {
        if (DataStore.serviceState.canStop) return // already running: the service is registered
        SagerNet.startService()
        if (DataStore.serviceMode != Key.MODE_VPN) return
        val deadline = System.currentTimeMillis() + SERVICE_READY_TIMEOUT_MS
        while (DataStore.vpnService == null) {
            if (System.currentTimeMillis() > deadline) {
                error("VpnService did not start within ${SERVICE_READY_TIMEOUT_MS / 1000}s")
            }
            // The service is created in a few hundred milliseconds; a 50 ms poll added up to
            // that again in quantization on a path the user is watching.
            delay(10)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "ready" -> result.success(serveReady())
                "service.start" -> result.respond {
                    startServiceAndAwaitTun()
                    null
                }
                "service.stop" -> {
                    if (DataStore.serviceState.canStop) SagerNet.stopService()
                    result.success(null)
                }
                // Read-only state the FFI driver polls while adopting a service that
                // started before Dart did. `registered` says the VpnService is back
                // after handOver()'s in-place restart; the core must not ask it for
                // a tun before that. No side effects: this never starts or stops.
                "service.state" -> result.success(mapOf(
                    "state" to DataStore.serviceState.name,
                    "registered" to (DataStore.baseService != null),
                    "ffiMode" to BboxKernel.ffiMode,
                ))
                "service.reload" -> {
                    if (DataStore.serviceState.canStop) SagerNet.reloadService()
                    result.success(null)
                }
                "mode.set" -> {
                    val mode = call.argument<String>("mode") ?: error("Missing mode")
                    BboxCommands.setMode(mode)
                    result.success(null)
                }
                "groups.select" -> result.respond {
                    val group = call.argument<String>("group") ?: error("Missing group")
                    val tag = call.argument<String>("tag") ?: error("Missing tag")
                    BboxCommands.selectProxyAwait(group, tag)
                    null
                }
                "groups.test" -> {
                    val tag = call.argument<String>("tag") ?: error("Missing tag")
                    testNode(tag)
                    result.success(null)
                }
                // The batch test panel over TestSessionClient: one session at a time, state pushed
                // while the panel is visible (groups.testSession.visible opens the feed).
                "groups.testSession.start" -> {
                    val kind = call.argument<Int>("kind") ?: error("Missing kind")
                    val groupId = call.argument<Int>("groupId")?.toLong() ?: 0L
                    val ids = call.argument<List<Any>>("profileIds").orEmpty().mapNotNull { (it as? Number)?.toLong() }
                    val testCurrent = call.argument<Boolean>("testCurrent") == true
                    // The speed session's direction; -1 keeps the Testing settings' mode.
                    val speedMode = call.argument<Int>("speedMode") ?: -1
                    result.respond {
                        if (groupId > 0) BboxTestSession.startGroup(kind, groupId, speedMode)
                        else BboxTestSession.startProfiles(kind, ids, testCurrent, speedMode)
                    }
                }
                "groups.testSession.stop" -> {
                    BboxTestSession.stop()
                    result.success(null)
                }
                "groups.testSession.dismiss" -> {
                    BboxTestSession.dismiss()
                    result.success(null)
                }
                "groups.testSession.sort" -> result.respond {
                    val sorted = BboxTestSession.sort(call.argument<Int>("groupId")?.toLong() ?: 0L)
                    if (!sorted) error("The group is gone or the sort did not run")
                    null
                }
                "groups.testSession.remove" -> result.respond {
                    val ids = call.argument<List<Any>>("ids").orEmpty().mapNotNull { (it as? Number)?.toLong() }
                    mapOf("removed" to BboxTestSession.remove(ids))
                }
                "groups.testSession.visible" -> {
                    setTestSessionVisible(call.argument<Boolean>("visible") == true)
                    result.success(null)
                }
                "profiles.list" -> result.success(profilesWire(BboxBridge.state.value))
                "profiles.select" -> result.respond {
                    BboxCommands.selectProfileAwait(call.argument<Int>("id")?.toLong() ?: -1L)
                    null
                }
                "profiles.delete" -> {
                    BboxCommands.deleteProfile(call.argument<Int>("id")?.toLong() ?: -1L)
                    result.success(null)
                }
                "profiles.update" -> {
                    BboxCommands.updateSubscription(call.argument<Int>("id")?.toLong() ?: -1L)
                    result.success(null)
                }
                // The television's previous / next server (TvControls.switchServer): a running
                // service hot-switches, a stopped one moves the selection.
                "profiles.switchRelative" -> {
                    BboxCommands.switchServer(call.argument<Int>("step") ?: 0)
                    result.success(null)
                }
                // The group settings form: every ProxyGroup field the native editor exposes, with the
                // choices and defaults its menus resolve to. The save validates with the native
                // editor's own checks and reloads the service when a running route re-pointed.
                "groupSettings.get" -> result.respond {
                    BboxProfiles.groupSettings(call.argument<Int>("id")?.toLong() ?: -1L)
                }
                "groupSettings.set" -> {
                    @Suppress("UNCHECKED_CAST")
                    val values = call.argument<Map<String, Any?>>("value") ?: call.arguments as? Map<String, Any?>
                    result.respond { BboxProfiles.saveGroupSettings(values.orEmpty()) }
                }
                "profiles.stats" -> result.respond {
                    BboxProfiles.stats(call.argument<Int>("id")?.toLong() ?: -1L)
                }
                "profiles.reorder" -> {
                    @Suppress("UNCHECKED_CAST")
                    val ids = (call.argument<List<Any>>("ids").orEmpty()).mapNotNull { (it as? Number)?.toLong() }
                    result.respond { BboxProfiles.reorder(ids); null }
                }
                "profiles.save" -> {
                    @Suppress("UNCHECKED_CAST")
                    val values = call.argument<Map<String, Any?>>("value") ?: call.arguments as? Map<String, Any?>
                    result.respond { BboxProfiles.save(values.orEmpty()); null }
                }
                "profiles.config" -> result.respond {
                    BboxProfiles.config(call.argument<Int>("id")?.toLong() ?: -1L).wire()
                }
                "profiles.read" -> result.respond {
                    BboxProfiles.read(call.argument<Int>("id")?.toLong() ?: -1L)
                }
                "profiles.write" -> result.respond {
                    BboxProfiles.write(
                        call.argument<Int>("id")?.toLong() ?: -1L,
                        call.argument<String>("revision"),
                        call.argument<String>("content").orEmpty(),
                    ).wire()
                }
                "profiles.decodeIntent" -> {
                    val uri = call.argument<String>("uri").orEmpty()
                    result.respond { BboxProfiles.decodeIntent(uri) }
                }
                "files.open" -> {
                    val uri = call.argument<String>("uri").orEmpty()
                    result.respond { BboxProfiles.decodeFile(uri) }
                }
                "profiles.nodeLink" -> {
                    val group = call.argument<String>("group").orEmpty()
                    val tag = call.argument<String>("tag").orEmpty()
                    val jsonLink = call.argument<Boolean>("json") == true
                    result.respond { BboxProfiles.nodeLink(group, tag, jsonLink) }
                }
                "profiles.nodeInfo" -> result.respond {
                    BboxProfiles.nodeInfo(call.argument<Int>("id")?.toLong() ?: -1L)
                }
                "profiles.nodeConfig" -> result.respond {
                    BboxProfiles.nodeConfig(call.argument<Int>("id")?.toLong() ?: -1L)
                }
                "profiles.createNode" -> result.respond {
                    BboxProfiles.createNode(
                        call.argument<Int>("groupId")?.toLong(),
                        call.argument<String>("type").orEmpty(),
                    )
                }
                "profiles.nodeUpdate" -> result.respond {
                    BboxProfiles.updateNode(
                        call.argument<Int>("id")?.toLong() ?: -1L,
                        call.argument<String>("name"),
                        call.argument<String>("content"),
                    )
                }
                "profiles.nodeDelete" -> result.respond {
                    BboxProfiles.deleteNode(call.argument<Int>("id")?.toLong() ?: -1L); null
                }
                "profiles.clearTestResults" -> result.respond {
                    BboxProfiles.clearGroupTestResults(call.argument<Int>("id")?.toLong() ?: -1L); null
                }
                "profiles.clearTraffic" -> result.respond {
                    BboxProfiles.clearGroupTraffic(call.argument<Int>("id")?.toLong() ?: -1L); null
                }
                "routes.list" -> result.respond { BboxRoutes.list() }
                "routes.get" -> result.respond { BboxRoutes.get(call.argument<Int>("id")?.toLong() ?: -1L) }
                "routes.save" -> {
                    @Suppress("UNCHECKED_CAST")
                    val values = call.argument<Map<String, Any?>>("value") ?: call.arguments as? Map<String, Any?>
                    result.respond { BboxRoutes.save(values.orEmpty()) }
                }
                "routes.delete" -> result.respond {
                    BboxRoutes.delete(call.argument<Int>("id")?.toLong() ?: -1L); null
                }
                "routes.setCurrent" -> result.respond {
                    BboxRoutes.setCurrent(call.argument<Int>("id")?.toLong() ?: -1L)
                }
                "routes.presets" -> result.respond { BboxRoutes.presets() }
                "routes.addPreset" -> result.respond {
                    BboxRoutes.addPreset(
                        call.argument<String>("country").orEmpty(),
                        call.argument<Boolean>("autoUpdate") != false,
                    )
                }
                "routes.rules" -> result.respond {
                    BboxRoutes.rules(call.argument<Int>("id")?.toLong() ?: -1L)
                }
                "routes.saveRules" -> {
                    @Suppress("UNCHECKED_CAST")
                    val rules = call.argument<List<Any>>("rules").orEmpty()
                        .mapNotNull { it as? Map<String, Any?> }
                    result.respond { BboxRoutes.saveRules(call.argument<Int>("id")?.toLong() ?: -1L, rules) }
                }
                "routes.batchAddRules" -> result.respond {
                    BboxRoutes.batchAddRules(
                        call.argument<Int>("id")?.toLong() ?: -1L,
                        call.argument<String>("text").orEmpty(),
                    )
                }
                "routes.resetRules" -> result.respond {
                    BboxRoutes.resetRules(call.argument<Int>("id")?.toLong() ?: -1L)
                }
                // The rule-set catalog (the routeprofiles srslist) behind the native rule-set picker.
                "routes.ruleSets" -> result.respond {
                    val query = call.argument<String>("query").orEmpty().trim()
                    val limit = call.argument<Int>("limit") ?: 100
                    val catalog = withContext(Dispatchers.IO) { RouteManager.catalog() }
                    mapOf(
                        "total" to catalog.size,
                        "entries" to catalog.search(query, limit).map { (name, url) ->
                            mapOf("name" to name, "url" to url)
                        },
                    )
                }
                "profiles.autoSelectorCreate" -> result.respond {
                    BboxProfiles.createAutoSelector(call.argument<Int>("groupId")?.toLong())
                }
                "profiles.autoSelectorInfo" -> result.respond {
                    BboxProfiles.autoSelectorInfo(call.argument<Int>("id")?.toLong() ?: -1L)
                }
                "profiles.autoSelectorSave" -> {
                    @Suppress("UNCHECKED_CAST")
                    val values = call.argument<Map<String, Any?>>("value") ?: call.arguments as? Map<String, Any?>
                    result.respond { BboxProfiles.autoSelectorSave(call.argument<Int>("id")?.toLong() ?: -1L, values.orEmpty()) }
                }
                "profiles.autoSelectorStatus" -> result.respond { BboxProfiles.autoSelectorStatus() }
                "profiles.autoSelectorPin" -> result.respond {
                    BboxProfiles.autoSelectorPin(
                        call.argument<Int>("id")?.toLong() ?: -1L,
                        call.argument<Int>("memberId")?.toLong() ?: -1L,
                    )
                }
                "profiles.autoSelectorRecheck" -> result.respond {
                    BboxProfiles.autoSelectorRecheck(); null
                }
                "profiles.nodeTuningInfo" -> result.respond {
                    BboxProfiles.nodeTuningInfo(call.argument<Int>("id")?.toLong() ?: -1L)
                }
                "profiles.nodeTuningSave" -> {
                    @Suppress("UNCHECKED_CAST")
                    val values = call.argument<Map<String, Any?>>("value") ?: call.arguments as? Map<String, Any?>
                    result.respond { BboxProfiles.nodeTuningSave(call.argument<Int>("id")?.toLong() ?: -1L, values.orEmpty()) }
                }
                "profiles.importFile" -> result.respond { importFile() }
                "profiles.scan" -> {
                    val session = call.argument<String>("session").orEmpty()
                    val text = call.argument<String>("text").orEmpty()
                    result.respond { scanChunk(session, text) }
                }
                "profiles.scan.close" -> {
                    scanChunks.reset(call.argument<String>("session").orEmpty())
                    result.success(null)
                }
                "preferences.set" -> {
                    @Suppress("UNCHECKED_CAST")
                    val values = call.argument<Map<String, Any?>>("value").orEmpty()
                    result.success(writePreferences(values))
                }
                "settings.get" -> result.success(settingsWire())
                "settings.set" -> {
                    val key = call.argument<String>("key") ?: error("Missing key")
                    applySettings(mapOf(key to call.argument<Any>("value")))
                    if (call.argument<Boolean>("restart") == true && DataStore.serviceState.canStop) {
                        SagerNet.reloadService()
                    }
                    result.success(settingsWire())
                }
                "settings.patch" -> {
                    @Suppress("UNCHECKED_CAST")
                    val values = call.argument<Map<String, Any?>>("value").orEmpty()
                    applySettings(values)
                    result.success(settingsWire())
                }
                "settings.reset" -> {
                    val keys = call.argument<List<Any>>("keys").orEmpty().filterIsInstance<String>()
                    val need = if (keys.isEmpty()) {
                        ThroneSettings.resetAll()
                    } else {
                        keys.mapNotNull { ThroneSettings.reset(it) }.maxByOrNull { it.ordinal }
                    } ?: Apply.None
                    // On demand only: a reset that changed nothing leaves the running core alone,
                    // a Reload rebuilds its config now, and AppRestart raises the badge only a
                    // process restart clears (log level, log buffer).
                    when {
                        need == Apply.AppRestart -> {
                            restartPending = true
                            emit("applyRequired", "Restart")
                        }
                        need == Apply.Reload && DataStore.serviceState.canStop -> SagerNet.reloadService()
                    }
                    result.success(settingsWire())
                }
                // WARP registration: the identity is made in the core process and the keys of the
                // chosen mode are saved by the bridge; the answer tells the UI whether a running
                // service has to reload the configuration it just changed. The keys went straight
                // to storage, so the settings event refreshes what the screen shows.
                "warp.register" -> {
                    val tunnelType = call.argument<String>("tunnelType") ?: error("Missing tunnel type")
                    result.respond {
                        val answer = BboxWarp.register(tunnelType)
                        emit("settings", settingsWire())
                        answer
                    }
                }
                // The DNS server fields offer presets plus the servers typed before (DnsServerHistory::Fill).
                "dns.suggestions" -> result.success(
                    mapOf(
                        "remote" to DnsServerHistory.remoteSuggestions(),
                        "direct" to DnsServerHistory.directSuggestions(),
                    )
                )
                // The Proxies screen asks for the node rows on open and gives them back on close;
                // `ready` and every other screen only get the counts.
                "groups.visible" -> {
                    setGroupsVisible(call.argument<Boolean>("visible") == true)
                    result.success(null)
                }
                // The outbound picker in the rule editor needs names, not rows: id and tag only.
                "groups.nodes" -> result.respond {
                    mapOf("nodes" to nodesWire(BboxBridge.state.value))
                }
                // Domain resolution for the diagnostics screen: the lookups run in the core process
                // against the running box's dns-direct transport, so the answer is the tunnel's and
                // not the phone's. Blocks for up to ~10 s, hence respond() rather than success().
                "dns.resolve" -> {
                    val domains = call.argument<List<String>>("domains").orEmpty()
                    result.respond { BboxResolve.resolve(domains) }
                }
                // What Wi-Fi rules need (location, background, services): the native walk-through
                // runs its dialogs and answers whether everything was granted. The caller saves the
                // rule either way — a refusal leaves the rules inactive, as in the native editor.
                "wifiPermissions.ensure" -> result.respond {
                    (activity as? BboxFlutterActivity)?.ensureWifiPermissions() ?: false
                }
                // The scan screen asks for the camera before it starts the scanner: the plugin would
                // ask too, but its request only completes if the host answers the permission result,
                // and a request that never answers leaves a black preview with nothing to report.
                "permissions.camera" -> result.respond {
                    (activity as? BboxFlutterActivity)?.ensureCameraPermission() ?: false
                }
                "url.open" -> {
                    val url = call.argument<String>("url").orEmpty()
                    BboxCommands.openUrl(url)
                    result.success(null)
                }
                "intent.take" -> result.success(takeIntent())

                // --- live views, each owned by the screen that opened it
                "connections.visible" -> {
                    setConnectionsVisible(call.argument<Boolean>("visible") == true)
                    result.success(null)
                }
                // OkHttp is synchronous; the channel thread is the main thread, where it throws
                // NetworkOnMainThreadException. Same for memoryWire below.
                "connections.close" -> result.respond {
                    withContext(Dispatchers.IO) {
                        BboxApi.close(call.argument<String>("id").orEmpty())
                    }
                    null
                }
                "connections.closeAll" -> result.respond {
                    withContext(Dispatchers.IO) { BboxApi.closeAll() }
                    null
                }
                "logs.visible" -> {
                    setLogsVisible(call.argument<Boolean>("visible") == true)
                    result.success(null)
                }
                "logs.clear" -> result.respond {
                    val batch = withContext(Dispatchers.IO) {
                        BboxLogs.clear()
                        BboxLogs.Batch(reset = true, defaultLogLevel = BboxLogs.level())
                    }
                    emit("logs", BboxLogs.wire(batch))
                    null
                }
                // The system logcat tab: same shape as the core log's events, a different source.
                // The durable crash records: core.log rotates, these files survive until pruned.
                "crashes.list" -> result.respond {
                    withContext(Dispatchers.IO) {
                        // Prune on read too: records older than the window otherwise
                        // survive until the next crash happens to fire.
                        CrashStore.prune()
                        CrashStore.list().map { file ->
                            mapOf("name" to file.name, "size" to file.length(), "time" to file.lastModified())
                        }
                    }
                }
                "crashes.read" -> result.respond {
                    val name = call.argument<String>("name").orEmpty()
                    // The name comes back from crashes.list; anything path-like is rejected outright.
                    require(name.isNotEmpty() && !name.contains('/') && !name.contains('\\') && !name.contains("..")) {
                        "bad crash log name"
                    }
                    withContext(Dispatchers.IO) { mapOf("name" to name, "content" to CrashStore.read(name)) }
                }
                "logs.logcat.visible" -> {
                    if (call.argument<Boolean>("visible") == true) {
                        BboxLogcat.start(scope) { emit("logcat", BboxLogcat.wire(it)) }
                    } else {
                        BboxLogcat.stop()
                    }
                    result.success(null)
                }
                "logs.logcat.clear" -> result.respond {
                    withContext(Dispatchers.IO) { BboxLogcat.clear() }
                    null
                }
                "dashboard.memory.visible" -> {
                    setMemoryVisible(call.argument<Boolean>("visible") == true)
                    result.success(null)
                }
                "dashboard.releaseMemory" -> {
                    // A full GC on a UI tap pauses the heap for a perceptible hitch and
                    // buys nothing: the runtime reclaims on its own. Debug builds keep the
                    // explicit call so the button can still be exercised there.
                    if (BuildConfig.DEBUG) System.gc()
                    result.success(null)
                }

                // --- diagnostics and the status card's probes
                "dashboard.egress" -> result.respond { egressWire(force = call.argument<Boolean>("force") == true) }
                "dashboard.probe.open" -> {
                    probes.computeIfAbsent(call.argument<String>("id").orEmpty()) { BboxProbeSession(probeClient()) }
                    result.success(null)
                }
                "dashboard.probe.get" -> result.respond { probeGet(call) }
                "dashboard.probe.close" -> {
                    closeProbe(call.argument<String>("id").orEmpty())
                    result.success(null)
                }
                "dashboard.qualityCache.get" -> result.success(qualityCache(call.argument<String>("ip").orEmpty()))
                "dashboard.qualityCache.put" -> {
                    val ip = call.argument<String>("ip").orEmpty()
                    @Suppress("UNCHECKED_CAST")
                    val value = call.argument<Any>("value")
                    writeQualityCache(ip, value)
                    result.success(null)
                }

                // --- LAN access to the running proxy
                "dashboard.lan.refresh" -> result.respond { lanWire() }
                "dashboard.lan.set" -> {
                    val enabled = call.argument<Boolean>("enabled") == true
                    val port = call.argument<Int>("port")
                    result.respond { lanSet(enabled, port) }
                }

                // --- per-app access control
                "apps.list" -> {
                    val refresh = call.argument<Boolean>("refresh") == true
                    val system = call.argument<Boolean>("system") == true
                    val nonInternet = call.argument<Boolean>("nonInternet") == true
                    // Package-manager scans belong off the main thread (the channel thread is it).
                    result.respond {
                        withContext(Dispatchers.IO) { BboxApps.list(refresh, system, nonInternet) }
                            .map(BboxApps.App::wire)
                    }
                }
                "apps.icon" -> result.respond {
                    withContext(Dispatchers.IO) { BboxApps.icon(call.argument<String>("package").orEmpty()) }
                }
                "apps.rescan" -> result.respond { rescanManagedApps() }
                "apps.permission" -> result.error(
                    "unsupported",
                    "Throne reads the app list through the package manager, so it needs no Shizuku grant",
                    null,
                )

                // --- backup, restore and WebDAV, all of which Throne already does natively
                "backup.create" -> result.respond { BboxBackup.create(call.argument<String>("scope") ?: "all") }
                "backup.read" -> result.respond { BboxBackup.read() }
                "backup.open" -> result.respond { openBackupDocument() }
                "backup.restore" -> {
                    @Suppress("UNCHECKED_CAST")
                    val payload = call.argument<Map<String, Any?>>("backup")
                    val scope = call.argument<String>("scope") ?: "profiles"
                    val strategy = call.argument<String>("strategy") ?: "Compatible"
                    result.respond {
                        val warnings = BboxBackup.restore(payload, scope, strategy)
                        if (warnings.isNotEmpty()) emit("error", warnings.joinToString("\n"))
                        null
                    }
                }
                "webdav.get" -> result.success(BboxBackup.webdav())
                "webdav.set" -> {
                    @Suppress("UNCHECKED_CAST")
                    result.success(BboxBackup.setWebdav(call.argument<Map<String, Any?>>("value")))
                }
                "webdav.check" -> result.respond { BboxBackup.checkWebdav() }
                "webdav.upload" -> result.respond { BboxBackup.uploadWebdav("all") }
                "webdav.read" -> result.respond { BboxBackup.readWebdav() }

                // --- documents and the share sheet
                "document.save" -> {
                    val name = call.argument<String>("name").orEmpty()
                    val content = call.argument<String>("content").orEmpty()
                    // Log exports carry credentials (URLs, keys); the native export always redacts
                    // (LogExport.build with redact = true), and so must anything that asks for it here.
                    val redact = call.argument<Boolean>("redact") == true
                    result.respond {
                        val text = withContext(Dispatchers.IO) {
                            if (!redact) content else {
                                val redactor = LogRedactor(hideDestinations = false)
                                content.lineSequence().joinToString("\n", transform = redactor::redact)
                            }
                        }
                        saveDocument(name, text)
                    }
                }
                "share.text" -> {
                    val content = call.argument<String>("content").orEmpty()
                    result.respond { shareText(content) }
                }
                "config.check" -> result.respond { checkConfig(call.argument<String>("content").orEmpty()) }
                "config.format" -> result.respond { formatConfig(call.argument<String>("content").orEmpty()) }

                // --- the FFI path's slim surface (BboxKernel): Dart drives the kernel
                // directly over dart:ffi and only DB/build work crosses here. ---
                // The one platform fact Dart cannot derive: where Room keeps its file.
                // `/data/data/<pkg>/databases` needs the package name, which the Dart side
                // has no way to learn, so it asks once at startup and then opens the file
                // itself. This is the last data-plane call on the channel.
                // STATUS: NOT WIRED. `flutter/lib/data/` is a ready-to-wire vertical
                // slice; `DataLayer.attach` has no production caller and this method is
                // never invoked from Dart. Keeping both halves lets the slice be switched
                // on without a host change, but release AOT tree-shakes the Dart side.
                "data.path" -> {
                    val file = activity.getDatabasePath(Key.DB_PROFILE)
                    // Reading `version` forces Room to open (and migrate) the file, which is
                    // what makes the answer trustworthy: the annotation could disagree with
                    // the file after a downgrade, and Dart would then map columns by position.
                    val version = SagerDatabase.instance.openHelper.readableDatabase.version
                    result.success(mapOf("path" to file.absolutePath, "version" to version))
                }
                "ffi.mode" -> {
                    val enabled = call.argument<Boolean>("enabled") == true
                    BboxKernel.ffiMode = enabled
                    // Non-Dart reloads (widget/tile/notification) reach the FFI driver as events.
                    BboxKernel.onReloadWanted = if (BboxKernel.ffiMode) {
                        { emit("serviceReload", true) }
                    } else {
                        null
                    }
                    // A service that came up before Dart (START_STICKY, always-on VPN) already
                    // built its own box. Two boxes on one tun fight over the same descriptor,
                    // so the service-side one is stopped and the service restarted in place:
                    // with ffiMode now true, that start keeps the notification and leaves the
                    // core to Dart, which rebuilds it from the dashboard state it finds.
                    val handedOver = if (enabled) BboxKernel.handOver() else false
                    result.success(mapOf("handedOver" to handedOver))
                }
                // Wi-Fi rules in ffiMode: Dart asks the core whether the config needs Wi-Fi
                // state and enables the monitor here. Only the Android callback stays on this
                // side; every change is announced so the core re-reads the SSID/BSSID.
                "wifi.watch" -> {
                    val enabled = call.argument<Boolean>("enabled") == true
                    BboxKernel.onWifiChanged = if (enabled) {
                        { emit("wifi.state", true) }
                    } else {
                        null
                    }
                    DataStore.baseService?.watchWifiRules(enabled)
                    result.success(null)
                }
                // Lifecycle breadcrumbs from the FFI driver, written into the same core.log the
                // log screen shows. A restart loop is otherwise invisible: the core simply
                // closes, and nothing in its own output says who asked for it or why.
                "log.note" -> {
                    val text = call.argument<String>("text").orEmpty()
                    if (text.isNotEmpty()) {
                        runCatching { CoreLog.write("[lifecycle] $text") }.onFailure { Logs.w(it) }
                    }
                    result.success(null)
                }
                "config.build" -> result.respond {
                    // The native DB owns the selection. Dart sends no id: a UI/group
                    // id or 0 is never a ProxyEntity id and used to fail every start
                    // with "profile 0 is gone". Ignore any stale argument entirely.
                    BboxKernel.buildStartOptions()
                }
                "config.warpParams" -> result.success(
                    WarpClient.registerParams(call.argument<String>("tunnelType").orEmpty()),
                )
                "state.setMode" -> {
                    BboxKernel.setMode(call.argument<String>("mode") ?: error("Missing mode"))
                    result.success(null)
                }
                // The service used to write these two right after proxy.init(); the FFI driver
                // owns the start now, so it reports them once the core is actually up.
                "state.markRunning" -> {
                    val ids = (call.argument<List<*>>("involvedProfileIds") ?: emptyList<Any?>())
                        .mapNotNull { (it as? Number)?.toLong() }
                    BboxKernel.markRunning(ids, (call.argument<Number>("routeId"))?.toLong() ?: 0L)
                    result.success(null)
                }
                "state.clearRunning" -> {
                    BboxKernel.clearRunning()
                    result.success(null)
                }
                // The FFI driver's status snapshot, where TrafficLooper would have written it.
                // Nothing on the service side polls the core in ffiMode, so without this the
                // notification's speed line and the widget stay at zero all session.
                "state.stats" -> {
                    DataStore.baseService?.publishKernelStats(
                        io.nekohasekai.sagernet.aidl.SpeedDisplayData(
                            txRateProxy = (call.argument<Number>("txRate"))?.toLong() ?: 0L,
                            rxRateProxy = (call.argument<Number>("rxRate"))?.toLong() ?: 0L,
                            txTotal = (call.argument<Number>("txTotal"))?.toLong() ?: 0L,
                            rxTotal = (call.argument<Number>("rxTotal"))?.toLong() ?: 0L,
                        ),
                    )
                    result.success(null)
                }
                "state.saveWarpKeys" -> result.respond {
                    val identity = call.argument<Map<String, Any?>>("identity").orEmpty()
                    fun field(key: String) = identity[key]?.toString().orEmpty()
                    val reserved = (identity["reserved"] as? List<*>)?.map { it.toString() }.orEmpty()
                    BboxKernel.completeWarp(
                        call.argument<String>("tunnelType").orEmpty(),
                        WarpClient.Identity(
                            deviceId = field("deviceId"),
                            token = field("token"),
                            license = field("license"),
                            ipv4 = field("ipv4"),
                            ipv6 = field("ipv6"),
                            privateKey = field("privateKey"),
                            peerPublicKey = field("peerPublicKey"),
                            endpoint = field("endpoint"),
                            reserved = reserved,
                        ),
                        packets = (call.argument<List<Any?>>("packets").orEmpty()).map { it.toString() },
                        packetsError = call.argument<String>("packetsError"),
                    )
                }
                "updates.check" -> result.respond { updatesWire() }
                "battery.open" -> {
                    openBatterySettings()
                    result.success(settingsWire())
                }
                "systemProxy.set" -> {
                    // Upstream's switch: the VPN service writes its mixed inbound into the system
                    // settings, which API 29 allows and the proxy-only mode cannot do at all.
                    val enabled = call.argument<Boolean>("enabled") == true
                    if (!systemProxyAvailable()) {
                        result.error("unsupported", "The system HTTP proxy needs VPN mode and Android 10 or newer", null)
                    } else {
                        DataStore.appendHttpProxy = enabled
                        if (DataStore.serviceState.canStop) SagerNet.reloadService()
                        result.success(mapOf("available" to true, "enabled" to DataStore.appendHttpProxy))
                    }
                }
                else -> result.error(
                    "unsupported",
                    "This screen is not wired to Throne yet: ${call.method}",
                    null,
                )
            }
        } catch (e: Exception) {
            Logs.w(e)
            result.error("failed", e.message ?: e.javaClass.simpleName, null)
        }
    }

    /** Tests the group the node belongs to, since Throne measures latency per profile. */
    private fun testNode(tag: String) {
        val group = BboxBridge.state.value.dashboard.groups.firstOrNull { it.tag == tag }
        if (group != null) {
            BboxCommands.testGroup(group.tag)
            return
        }
        val owner = BboxBridge.state.value.dashboard.groups.firstOrNull { candidate ->
            candidate.nodes.any { it.tag == tag }
        } ?: return
        BboxCommands.testProxy(owner.tag, tag)
    }

    // -------------------------------------------------------------------------------------------- live views

    /**
     * Starts or stops the connections feed.
     *
     * Throne's core only exposes live connections through its own control API, which its settings keep switched off by
     * default. Opening the screen flips that setting the way the core settings screen does and asks for the reload that
     * makes the port answer; the first poll after that is the first one that can return anything.
     */
    private fun setConnectionsVisible(visible: Boolean) {
        connectionsJob?.cancel()
        connectionsJob = null
        if (!visible) {
            lastConnections = null
            return
        }
        if (BboxApi.enable()) {
            if (DataStore.serviceState.canStop) SagerNet.reloadService()
            emit("applyRequired", "Restart")
        }
        connectionsJob = scope.launch {
            while (isActive) {
                val rows = withContext(Dispatchers.IO) {
                    runCatching { BboxApi.connections() }.onFailure { Logs.w(it) }.getOrDefault(emptyList())
                }
                if (rows.isNotEmpty() || lastConnections != null) {
                    lastConnections = rows
                    emit("connections", rows)
                }
                delay(1500)
            }
        }
    }

    @Volatile
    private var lastConnections: List<Map<String, Any?>>? = null

    private fun setLogsVisible(visible: Boolean) {
        if (!visible) {
            BboxLogs.stop()
            return
        }
        BboxLogs.start(scope) { emit("logs", BboxLogs.wire(it)) }
    }

    /**
     * The client publishes its model every 100 ms; the panel's feed relays at 400 ms and only what
     * changed, which is what the native panel's diffing achieved on a slower path.
     */
    private fun setTestSessionVisible(visible: Boolean) {
        testSessionJob?.cancel()
        testSessionJob = null
        if (!visible) {
            lastTestSession = null
            return
        }
        testSessionJob = scope.launch {
            while (isActive) {
                val wire = withContext(Dispatchers.IO) { BboxTestSession.wire() }
                if (wire != lastTestSession) {
                    lastTestSession = wire
                    emit("testSession", wire)
                }
                delay(400)
            }
        }
    }

    /**
     * One queue report, split the way the native window splits it: a reload hint raises the apply
     * badge, an error or an untitled status line is a snackbar, a popup opens the change window.
     * The group's name rides along so the UI never has to ask.
     */
    private suspend fun emitReport(report: SubscriptionClient.Report) {
        val groupName = withContext(Dispatchers.IO) {
            runCatching { GroupRepo.get(report.gid)?.displayName() }.getOrNull()
        }
        when {
            report.reload -> emit("applyRequired", "Reload")

            report.error -> emit("subscriptionReport", mapOf(
                "kind" to "error",
                "groupName" to groupName,
                "text" to report.text.ifBlank { report.title },
            ))

            report.popup -> emit("subscriptionReport", mapOf(
                "kind" to "popup",
                "groupName" to groupName,
                "title" to report.title.ifBlank {
                    app.getString(io.nekohasekai.sagernet.R.string.grp_change_of, groupName.orEmpty())
                },
                "text" to report.text,
            ))

            report.title.isEmpty() && report.text.isNotBlank() -> emit("subscriptionReport", mapOf(
                "kind" to "status",
                "text" to report.text,
            ))
        }
    }

    /** Memory is cheap to read but not free on a television, so it is sampled only while a panel shows it. */
    private fun setMemoryVisible(visible: Boolean) {
        memoryJob?.cancel()
        memoryJob = null
        if (!visible) return
        memoryJob = scope.launch {
            while (isActive) {
                // memoryWire() only calls Debug.getMemoryInfo and Runtime (no HTTP
                // any more), but a 2 s sample still belongs off the main looper.
                emit("memory", withContext(Dispatchers.IO) { memoryWire() })
                delay(2000)
            }
        }
    }

    /**
     * What the memory panel shows, all of it from Android's own accounting.
     *
     * `Debug.MemoryInfo` reports PSS — what the process actually has resident — and splits it by
     * allocator: `dalvikPss` for the ART heap, `nativePss` for native allocations (the Go runtime is
     * one) and `otherPss` for the rest. The three add up to `totalPss`, so the panel can show four
     * numbers that agree with each other without any arithmetic of its own.
     *
     * The core used to grade itself instead: `Status().Memory` is the heap the Go runtime has
     * *mapped*, which is a different quantity from resident memory and can exceed RSS. On a 286 MB
     * process it read 319 MB, and every way of folding it into the panel produced a part larger
     * than the whole.
     *
     * `heapInuse`/`heapIdle` stay the ART heap's own counters: they answer "how full is the heap",
     * which PSS cannot.
     */
    private fun memoryWire(): Map<String, Any?> {
        val runtime = Runtime.getRuntime()
        val heapUsed = runtime.totalMemory() - runtime.freeMemory()
        val info = Debug.MemoryInfo()
        Debug.getMemoryInfo(info)
        fun kb(value: Int) = value.toLong() * 1024
        return mapOf(
            "total" to runtime.maxMemory(),
            "app" to kb(info.dalvikPss),
            "core" to kb(info.nativePss),
            "other" to kb(info.otherPss),
            "rss" to kb(info.totalPss),
            "running" to DataStore.serviceState.connected,
            "remote" to false,
            "heapInuse" to heapUsed,
            "heapIdle" to (runtime.totalMemory() - heapUsed),
        )
    }

    // -------------------------------------------------------------------------------------------- probes and egress

    private fun probeClient(): OkHttpClient {
        val builder = OkHttpClient.Builder()
            .connectTimeout(6, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .callTimeout(16, TimeUnit.SECONDS)
            .retryOnConnectionFailure(false)
        // Same route as the egress probe: the mixed inbound only while the core answers it, the device network
        // otherwise, so a session opened while stopped still reaches the quality sources.
        if (!DataStore.serviceState.connected) return builder.build()
        val host = DataStore.inboundAddress.ifBlank { SettingsRegistry.LOOPBACK_ADDRESS }
        val port = DataStore.inboundSocksPort
        return builder.proxy(Proxy(Proxy.Type.HTTP, InetSocketAddress(host, port))).build()
    }

    private suspend fun probeGet(call: MethodCall): Map<String, Any?> {
        // Capture the session before dispatching; a late request must never reopen a closed one.
        val session = probes[call.argument<String>("id").orEmpty()]
            ?: throw CancellationException("IP probe session closed")
        val url = call.argument<String>("url").orEmpty()
        val timeout = call.argument<Int>("timeoutMillis") ?: 8000
        return withContext(Dispatchers.IO) { session.get(url, timeout.toLong()) }
    }

    private fun closeProbe(id: String) {
        probes.remove(id)?.close()
    }

    private suspend fun egressWire(force: Boolean = false): Map<String, Any?> = withContext(Dispatchers.IO) {
        // The probe reaches the internet through the mixed inbound, which nothing answers until the core is up. Rather
        // than leaving the card blank while stopped, ask over the phone's own connection: the answer is the address
        // this device appears as without the tunnel, and `direct` tells the screen which of the two it is looking at.
        val direct = !DataStore.serviceState.connected
        var failure: String? = null
        val info = BboxEgress.probe(force = force, direct = direct) { failure = it }
        if (info.isEmpty && failure != null) error(failure!!)
        mapOf(
            "ip" to info.ip,
            "country" to info.country,
            "countryName" to info.countryName,
            "region" to info.region,
            "city" to info.city,
            "isp" to info.isp,
            "organization" to info.organization,
            "asn" to info.asn,
            "type" to info.type,
            "direct" to direct,
            "ipSource" to (info.source?.substringAfter("://")?.substringBefore('/') ?: "ipwho.is"),
            "checkedAt" to System.currentTimeMillis(),
        )
    }

    private fun qualityCache(ip: String): Map<String, Any?>? {
        if (ip.isBlank()) return null
        val stored = readJsonMap(QUALITY_KEY)
        @Suppress("UNCHECKED_CAST")
        return stored[ip] as? Map<String, Any?>
    }

    private fun writeQualityCache(ip: String, value: Any?) {
        if (ip.isBlank()) return
        val merged = readJsonMap(QUALITY_KEY).toMutableMap()
        if (value == null) merged.remove(ip) else merged[ip] = value
        // Bounded: an entry per IP the user has ever connected through would grow without limit.
        if (merged.size > 512) {
            val oldest = merged.keys.take(merged.size - 512)
            oldest.forEach { merged.remove(it) }
        }
        writeJsonMap(QUALITY_KEY, merged)
    }

    // ------------------------------------------------------------------------------------------------ LAN access

    /**
     * Whether the running service answers on the LAN.
     *
     * Throne's mixed inbound binds to a configured address; loopback keeps the proxy private to the device and a
     * wildcard address shares it with everything on the same network. That choice *is* the LAN switch, so this reads
     * and writes the same setting the core configuration is built from.
     */
    private fun lanWire(): Map<String, Any?> {
        val shared = isSharedInbound()
        val port = DataStore.inboundSocksPort
        val addresses = lanAddresses()
        val endpoints = if (shared && DataStore.serviceState.connected) {
            addresses.map { "$it:$port" }
        } else {
            emptyList()
        }
        return mapOf(
            "addresses" to addresses,
            "canToggle" to true,
            "running" to (shared && DataStore.serviceState.connected),
            "enabled" to shared,
            "profileId" to (BboxBridge.catalog.selectedGroupId.takeIf { it > 0 } ?: -1),
            "revision" to "$port-${DataStore.inboundAddress}",
            "stamp" to "$port-${DataStore.inboundAddress}",
            "error" to null,
            "bindings" to listOf(
                mapOf(
                    "tag" to "mixed",
                    "type" to "mixed",
                    "tls" to false,
                    "authentication" to false,
                    "port" to port,
                    "endpoints" to endpoints,
                    "lan" to shared,
                )
            ),
            "activeBindings" to if (endpoints.isEmpty()) emptyList<Map<String, Any?>>() else listOf(
                mapOf("tag" to "mixed", "type" to "mixed", "port" to port, "endpoints" to endpoints, "lan" to true)
            ),
        )
    }

    private suspend fun lanSet(enabled: Boolean, port: Int?): Map<String, Any?> = withContext(Dispatchers.IO) {
        if (lanBusy) error("Already switching the LAN listener")
        lanBusy = true
        try {
            if (port != null) DataStore.inboundSocksPort = port
            val address = if (enabled) "0.0.0.0" else SettingsRegistry.LOOPBACK_ADDRESS
            if (address != DataStore.inboundAddress) {
                DataStore.inboundAddress = address
                if (DataStore.serviceState.canStop) SagerNet.reloadService()
            }
            lanWire().also { emit("lan", it) }
        } finally {
            lanBusy = false
        }
    }

    private fun isSharedInbound(): Boolean {
        val address = DataStore.inboundAddress
        return address.isNotBlank() && address != SettingsRegistry.LOOPBACK_ADDRESS && address != "127.0.0.1" && address != "::1"
    }

    private fun lanAddresses(): List<String> = runCatching {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.toList() }
            .filter { !it.isLoopbackAddress && it.hostAddress?.contains(':') != true }
            .mapNotNull { it.hostAddress }
    }.getOrDefault(emptyList())

    // ------------------------------------------------------------------------------------------------ documents

    private suspend fun saveDocument(name: String, content: String): Boolean? {
        val host = activity as? BboxFlutterActivity ?: return false
        val mime = when {
            name.endsWith(".json", ignoreCase = true) -> "application/json"
            name.endsWith(".log", ignoreCase = true) -> "text/plain"
            else -> "application/octet-stream"
        }
        val uri = host.pickSaveTarget(name, mime) ?: return null
        return withContext(Dispatchers.IO) {
            runCatching {
                // A null stream means nothing was written; reporting success here would let the
                // UI confirm an export that did not happen.
                val output = host.contentResolver.openOutputStream(uri) ?: error("cannot open $uri")
                output.use { it.write(content.toByteArray(Charsets.UTF_8)) }
                true
            }.onFailure { Logs.w(it) }.getOrDefault(false)
        }
    }

    private suspend fun shareText(content: String): Boolean {
        if (content.isBlank()) return false
        return runCatching {
            activity.startActivity(
                Intent.createChooser(
                    Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, content),
                    null,
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        }.onFailure { Logs.w(it) }.getOrDefault(false)
    }

    /**
     * The local "Restore" entry: the user picks the file, and either the JSON envelope the local
     * "Backup" entry wrote or a `.thrbackup` container ends up as the same staged payload the WebDAV
     * read produces. A cancelled picker answers null, which the page treats as "nothing chosen"
     * rather than "no backup"; a file that is neither is an error the page can show.
     */
    private suspend fun openBackupDocument(): Map<String, Any?>? {
        val host = activity as? BboxFlutterActivity ?: error("The file picker is unavailable")
        val uri = host.pickDocument() ?: return null
        val bytes = withContext(Dispatchers.IO) {
            host.contentResolver.openInputStream(uri)?.use { it.readBytes() }
        } ?: error("The selected file cannot be read")
        return BboxBackup.open(bytes)
            ?: BboxBackup.openJson(bytes.toString(Charsets.UTF_8))
            ?: error("This is not a Throne backup")
    }

    /** A picked file becomes the same draft a pasted link becomes, so both open the same editor. */
    private suspend fun importFile(): Map<String, Any?>? {
        val host = activity as? BboxFlutterActivity ?: return null
        val uri = host.pickDocument() ?: return null
        val text = withContext(Dispatchers.IO) {
            runCatching {
                host.contentResolver.openInputStream(uri)?.use { it.readBytes().toString(Charsets.UTF_8) }
            }.getOrNull()
        }.orEmpty()
        if (text.isBlank()) return null
        return BboxProfiles.decodeIntent(text.trim())
    }

    /**
     * Multi-frame QR payloads: the frames are concatenated until the result is something worth opening, and the
     * progress is reported so the screen can show a bar.
     */
    private suspend fun scanChunk(session: String, text: String): Map<String, Any?> {
        val decision = scanChunks.accept(session, text)
        if (!decision.complete) {
            return mapOf("text" to decision.text, "decoded" to 0, "total" to 1)
        }
        scanChunks.reset(session)
        return mapOf(
            "profile" to BboxProfiles.decodeIntent(decision.text),
            "text" to decision.text,
            "decoded" to 1,
            "total" to 1,
        )
    }

    // ------------------------------------------------------------------------------------------------ JSON editing

    /** The document keys a group's configuration may carry; everything else is an app setting. */
    private val CONFIG_KEYS = setOf("name", "url", "autoUpdate", "updateIntervalMinutes", "nodes")

    /** "DNS, routing rules and log settings are app settings": the Throne split the document follows. */
    private fun refuseForeignConfigKey(key: String): Nothing =
        error("\"$key\" is not part of the configuration; DNS, routing rules and log settings are app settings")

    /**
     * The configuration is the group's manifest — name, url, autoUpdate, updateIntervalMinutes and its nodes.
     * DNS and routing live in the app settings as in Throne, so those keys are refused here instead of being
     * dropped by a save that only reads the manifest.
     */
    private suspend fun checkConfig(content: String): Any? = withContext(Dispatchers.IO) {
        val parsed = JsonTree.parse(content)
        val root = parsed.root ?: error(parsed.error.ifBlank { "Not valid JSON" })
        if (root.type != JsonType.Object) error("The configuration must be a JSON object")
        for (key in root.keys) if (key !in CONFIG_KEYS) refuseForeignConfigKey(key)
        root.member("name")?.takeIf { it.type != JsonType.String }?.let { error("\"name\" must be a string") }
        root.member("url")?.takeIf { it.type != JsonType.String }?.let { error("\"url\" must be a string") }
        root.member("autoUpdate")?.takeIf { it.type != JsonType.Bool }?.let { error("\"autoUpdate\" must be true or false") }
        root.member("updateIntervalMinutes")?.takeIf { it.type != JsonType.Number }?.let { error("\"updateIntervalMinutes\" must be a number") }
        root.member("nodes")?.takeIf { it.type != JsonType.Array }?.let { error("\"nodes\" must be an array") }
        null
    }

    private fun formatConfig(content: String): String {
        val parsed = JsonTree.parse(content)
        val root = parsed.root ?: error(parsed.error.ifBlank { "Not valid JSON" })
        return JsonFormatter.format(content, root) ?: content
    }

    // ------------------------------------------------------------------------------------------------ updates

    private suspend fun updatesWire(): Map<String, Any?> = withContext(Dispatchers.IO) {
        when (val result = UpdateChecker.check(app, withNotes = true)) {
            is UpdateChecker.Result.UpToDate -> mapOf(
                "available" to false,
                "version" to BuildConfig.VERSION_NAME,
                "hasMetadata" to true,
            )
            is UpdateChecker.Result.Available -> {
                val offer = result.offer
                mapOf(
                    "available" to true,
                    "version" to offer.versionName,
                    "notes" to offer.notes,
                    "hasMetadata" to true,
                    "downloadUrl" to offer.apk?.url,
                    "url" to offer.release.htmlUrl,
                )
            }
            is UpdateChecker.Result.Failed -> mapOf(
                "available" to false,
                "version" to BuildConfig.VERSION_NAME,
                "hasMetadata" to false,
            )
        }
    }

    private fun openBatterySettings() {
        runCatching {
            activity.startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                    .setData(Uri.parse("package:${app.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }.onFailure {
            runCatching {
                activity.startActivity(
                    Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            }.onFailure { Logs.w(it) }
        }
    }

    /** The system HTTP proxy is written by the VPN service, so proxy-only mode cannot offer it. */
    private fun systemProxyAvailable(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && DataStore.serviceMode == Key.MODE_VPN

    private fun batteryExempt(): Boolean = runCatching {
        val power = app.getSystemService(Context.POWER_SERVICE) as PowerManager
        power.isIgnoringBatteryOptimizations(app.packageName)
    }.getOrDefault(false)

    /**
     * The share / open-with payload, delivered once per intent: the first `intent.take` after an
     * intent arrives consumes it (per the ready payload's contract), and a later intent starts the
     * cycle again — [notifyIntentAvailable] tells the UI to ask again. Two intents before either is
     * taken keep only the latest, as `setIntent` replaced the first.
     */
    private fun takeIntent(): String? {
        if (pendingIntent == null) {
            val intent = activity.intent
            if (intent != null && intent !== deliveredIntent) {
                // A file arrives in the data slot when it was opened (VIEW) and in the stream slot when it
                // was shared (SEND); the text slot is the QR scanner's and the share sheet's.
                pendingIntent = intent.takeIf { it.action != Intent.ACTION_MAIN }?.dataString
                    ?: intent.getStringExtra(Intent.EXTRA_TEXT)
                    ?: intent.streamUri?.toString()
                deliveredIntent = intent
            }
        }
        return pendingIntent.also { pendingIntent = null }
    }

    /**
     * A new intent has replaced the old one; the UI picks it up with `intent.take`. When the UI is
     * not attached the intent still waits for the next `ready`, so nothing is lost — only the ping
     * is, and the pending flag re-raises it in [onListen].
     */
    fun notifyIntentAvailable() {
        if (sink == null) {
            intentAvailablePending = true
            return
        }
        emit("intentAvailable", true)
    }

    /** Recomputes the managed list against what is actually installed; uninstalled packages cannot stay in it. */
    private suspend fun rescanManagedApps(): Map<String, Any?> = withContext(Dispatchers.IO) {
        val known = BboxApps.list(refresh = true, system = false, nonInternet = false)
            .associateBy { it.packageName }
        val kept = DataStore.individual.lineSequence()
            .map(String::trim)
            .filter(String::isNotEmpty)
            .filter { it in known }
            .distinct()
            .joinToString("\n")
        DataStore.individual = kept
        settingsWire()
    }

    // ------------------------------------------------------------------------------------------------ payloads

    /**
     * Answers `ready` and seeds the pump's baselines with what it just sent.
     *
     * Without the baselines the first push after this answer would rebuild the catalog and emit it
     * again — the very duplicate this release removes — and the pump stays silent until this has
     * answered, so nothing is emitted twice around the first frame.
     */
    @Suppress("UNCHECKED_CAST")
    private fun serveReady(): Map<String, Any?> {
        val payload = readyPayload()
        lastDashboard = payload["dashboard"] as? Map<String, Any?>
        lastProfiles = payload["profiles"] as? List<Map<String, Any?>>
        lastGroups = payload["groups"] as? List<Map<String, Any?>>
        sentCatalog = BboxBridge.catalogRevision to groupsVisible
        readyServed = true
        return payload
    }

    private fun readyPayload(): Map<String, Any?> = mapOf(
        "version" to BuildConfig.VERSION_NAME,
        "coreVersion" to "sing-box · Xray",
        "systemAccentColor" to 0xFF6750A4.toInt(),
        "dashboard" to dashboardWire(BboxBridge.state.value),
        "profiles" to profilesWire(BboxBridge.state.value),
        // Counts only: the node rows are the largest thing the bridge carries, and the first
        // screen does not render them. `groups.visible` sends them when the Proxies screen opens.
        "groups" to groupsWire(BboxBridge.state.value, withItems = groupsVisible),
        "settings" to settingsWire(),
        "capabilities" to Capabilities.map(),
        "preferences" to readPreferences(),
        "lan" to lanWire(),
        "tools" to emptyMap<String, Any?>(),
        "diagnostics" to mapOf(
            "stun" to emptyMap<String, Any?>(),
            "quality" to emptyMap<String, Any?>(),
        ),
        "intent" to takeIntent(),
        // A low-RAM device gets a smaller decoded-image budget than the 50 MiB the UI assumes.
        "lowRam" to lowRamDevice(),
        // The badge an AppRestart-level write or reset raised; it clears only when the restart
        // gives the process a fresh [restartPending].
        "applyRequired" to (if (restartPending) "Restart" else null),
    )

    /** `ActivityManager.isLowRamDevice`: Android's own memory class, not a build flag of ours. */
    private fun lowRamDevice(): Boolean = runCatching {
        (app.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).isLowRamDevice
    }.getOrDefault(false)

    private fun dashboardWire(state: BboxUiState): Map<String, Any?> {
        val dashboard = state.dashboard
        val status = when {
            dashboard.status.transitioning && dashboard.status.statusText == "Stopping" -> "Stopping"
            dashboard.status.transitioning -> "Starting"
            dashboard.status.running -> "Started"
            else -> "Stopped"
        }
        return mapOf(
            "status" to status,
            "selectedProfileId" to (BboxBridge.catalog.selectedGroupId.takeIf { it > 0 } ?: -1),
            "selectedProfileName" to (dashboard.profile?.name ?: ""),
            "modes" to dashboard.modes,
            // Read the store instead of the cached copy: the cached mode only changes on a
            // catalog refresh, and between the switch tap and that refresh the pump would
            // otherwise emit the previous mode back to Dart and revert the chip highlight.
            "mode" to BboxMode.get().id,
            "startedAt" to dashboard.status.startedAt,
            "uploadTotal" to dashboard.traffic.uploadTotal,
            "downloadTotal" to dashboard.traffic.downloadTotal,
            "connections" to 0,
            "memory" to (dashboard.memory?.inUse ?: 0L),
            "goroutines" to 0,
            // Only the VPN service can hand its mixed inbound to apps as the system HTTP proxy.
            "systemProxyAvailable" to systemProxyAvailable(),
            "systemProxy" to DataStore.appendHttpProxy,
            "deprecated" to emptyList<Map<String, Any?>>(),
        )
    }

    private fun profilesWire(state: BboxUiState): List<Map<String, Any?>> =
        state.profiles.map { profile ->
            mapOf(
                "id" to profile.id.toInt(),
                "name" to profile.name,
                "type" to profile.type,
                "remote" to (profile.type == "subscription"),
                "url" to profile.url,
                "traffic" to profile.traffic,
                "expiry" to profile.expiry,
                "selected" to profile.selected,
                "updatedAt" to profile.updatedAt,
                "autoUpdate" to profile.autoUpdate,
                "interval" to profile.interval,
            )
        }

    /**
     * The groups the UI renders. [withItems] is false until the Proxies screen asks for them; the
     * shaping itself lives in [BboxGroupsWire] so the contract is unit-tested.
     */
    private fun groupsWire(state: BboxUiState, withItems: Boolean): List<Map<String, Any?>> =
        BboxGroupsWire.groups(state.dashboard.groups, withItems)

    /** The outbound picker's list: every node of every group, id and tag only. */
    private fun nodesWire(state: BboxUiState): List<Map<String, Any?>> =
        BboxGroupsWire.nodes(state.dashboard.groups)

    /**
     * The settings map the UI reads, in three layers: keys only this shell has (appearance, sorting,
     * card layout) live in a local JSON document, then real Throne storage from [Settings] wins over
     * anything stale in that document, then the derived and read-only keys settle last.
     */
    private fun settingsWire(): Map<String, Any?> {
        val result = LinkedHashMap<String, Any?>()
        result.putAll(readJsonMap(SETTINGS_KEY))
        result.putAll(ThroneSettings.read())
        result["fontSize"] = (result["fontSize"] as? Number)?.toInt() ?: 0
        result["perAppManaged"] = false
        result["perAppManagedList"] = emptyList<String>()
        result["queryMode"] = "ROOT"
        result["batteryExempt"] = batteryExempt()
        return result
    }

    /**
     * Writes go to real Throne storage when [ThroneSettings] knows the key, and to the shell's own document
     * otherwise. A key the host recognises but only applies on a process restart is remembered in
     * [restartPending] so `ready` can tell the UI to show the badge.
     */
    private fun applySettings(values: Map<String, Any?>) {
        val overlay = readJsonMap(SETTINGS_KEY).toMutableMap()
        values.forEach { (key, value) ->
            if (ThroneSettings.has(key)) {
                if (ThroneSettings.set(key, value) == Apply.AppRestart) restartPending = true
                // A typed DNS server joins its suggestion list (RouteProfileActivity's save does the same).
                when (key) {
                    "remoteDns" -> (value as? String)?.let(DnsServerHistory::rememberRemote)
                    "directDns" -> (value as? String)?.let(DnsServerHistory::rememberDirect)
                }
            } else {
                if (value == null) overlay.remove(key) else overlay[key] = value
            }
        }
        writeJsonMap(SETTINGS_KEY, overlay)
        emit("settings", settingsWire())
    }

    // ------------------------------------------------------------------------------------------------ JSON stores

    /** Preferences are one JSON document so bool, number, list and nested map types survive the round trip. */
    private fun writePreferences(values: Map<String, Any?>): Map<String, Any?> {
        val merged = readPreferences().toMutableMap()
        values.forEach { (key, value) ->
            if (value == null) merged.remove(key) else merged[key] = value
        }
        writeJsonMap(PREFERENCES_KEY, merged)
        return merged
    }

    private fun readPreferences(): Map<String, Any?> = readJsonMap(PREFERENCES_KEY)

    private fun readJsonMap(key: String): Map<String, Any?> {
        val stored = preferences.getString(key, null) ?: return emptyMap()
        return runCatching {
            when (val parsed = jsonToWire(JSONObject(stored))) {
                is Map<*, *> -> parsed.entries.associate { it.key.toString() to it.value }
                else -> emptyMap()
            }
        }.getOrDefault(emptyMap())
    }

    private fun writeJsonMap(key: String, values: Map<String, Any?>) {
        val json = JSONObject()
        values.forEach { (name, value) -> json.put(name, wireToJson(value)) }
        preferences.edit().putString(key, json.toString()).apply()
    }

    private fun jsonToWire(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> value.keys().asSequence().associateWith { jsonToWire(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { jsonToWire(value.get(it)) }
        else -> value
    }

    private fun wireToJson(value: Any?): Any = when (value) {
        null -> JSONObject.NULL
        JSONObject.NULL, is JSONObject, is JSONArray -> value
        is Boolean, is Number, is String -> value
        is Map<*, *> -> JSONObject(value.entries.associate { it.key.toString() to wireToJson(it.value) })
        is Collection<*> -> JSONArray(value.map(::wireToJson))
        is Array<*> -> JSONArray(value.map(::wireToJson))
        else -> value.toString()
    }

    private companion object {
        /** How long `service.start` waits for the live VpnService before failing loudly. */
        const val SERVICE_READY_TIMEOUT_MS = 8_000L
        const val PREFERENCES_KEY = "value"
        const val SETTINGS_KEY = "settings"
        const val QUALITY_KEY = "ipQuality"
    }
}
