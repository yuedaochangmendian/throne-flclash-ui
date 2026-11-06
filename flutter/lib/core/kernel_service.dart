// The Dart-driven kernel lifecycle (the FFI path): Dart owns the core through
// dart:ffi — build the config over the slim channel, start/stop/reload the
// Instance directly, and stream the status back as the channel-shaped events the
// UI already consumes. Every operation falls back to the method channel when the
// rebuilt core is absent (ThroneKernel.isAvailable == false).
//
// The FFI itself lives in one long-lived isolate (kernel_worker.dart). The UI
// isolate never opens libthrone.so for kernel calls: status arrives as a pushed
// "status" event on the Go message port, and worker failures become UI events.

import 'dart:async';

import '../box.dart';
import 'kernel_worker.dart';
import 'platform_value.dart';
import 'throne_kernel.dart';

/// Drives the core through dart:ffi instead of the Android service.
///
/// On: Dart opens `libthrone.so` and owns the Instance lifecycle — start, stop,
/// reload and the status snapshot all cross the C ABI directly, and the bridge
/// is told to stand aside for the control plane only.
///
/// The driver still stands down on its own when the rebuilt core is absent from
/// the build (`ThroneKernel.isAvailable == false`): it returns before it asks
/// the bridge to yield, so `BaseService` keeps starting `ProxyInstance` through
/// gomobile and every control call takes its channel branch. Flipping this off
/// hands the core back to the service without deleting the driver.
const bool kFfiDriverEnabled = true;

class KernelService {
  KernelService(this.box);

  final BoxController box;

  final _events = StreamController<Map<String, dynamic>>.broadcast();

  /// Channel-shaped events (`{type, value}`) the BoxController feeds to _onEvent.
  Stream<Map<String, dynamic>> get events => _events.stream;

  ThroneKernel? _kernel;
  KernelWorker? _worker;
  int? _instanceHandle;
  StreamSubscription<WorkerEvent>? _workerSub;
  StreamSubscription<BridgeEvent>? _statusSub;
  DateTime? _startedAt;
  bool _starting = false;
  bool _stopping = false;
  bool _recovering = false;
  bool _disposed = false;
  bool _initializing = false;

  /// Set when the bridge stopped a service-side box to hand the control plane over
  /// (the service came up before Dart did). [adoptService] rebuilds the core once the
  /// channel is ready; until then the tunnel is deliberately down rather than doubled.
  bool handoverPending = false;

  /// Automatic restarts spent on the current incident; reset by a run that holds.
  int _recoveryAttempts = 0;

  /// How many restarts a single incident may spend before the failure is shown
  /// instead of retried. Three covers a transient network blip; more than that
  /// is a core that will not stay up.
  static const _maxRecoveries = 3;

  /// True when the rebuilt core is present and the FFI path drives it.
  bool get active => _kernel != null && _instanceHandle != null;

  /// True once the FFI path is engaged (the channel handlers step aside).
  bool get ffiMode => _kernel != null;

  // --- lifecycle ----------------------------------------------------------

  Future<void> initialize() async {
    // Bridge mode: no FFI library is opened, no worker isolate is spawned, and
    // the bridge is never told to stand aside. Everything below belongs to the
    // FFI driver and must stay out of the way when it is switched off.
    if (!kFfiDriverEnabled) return;
    if (_kernel != null || _initializing) return;
    // Nothing to drive when the rebuilt core is absent: leave the bridge in
    // charge rather than ask it to stand aside for a library that is not there.
    if (!ThroneKernel.isAvailable) return;
    _initializing = true;
    try {
      // Tell the bridge the FFI path drives the core from now on, then open the ABI.
      // The reply says whether a service-side box had to be stopped to get here.
      final reply = await box.call('ffi.mode', {'enabled': true});
      handoverPending = reply is Map && reply['handedOver'] == true;
      final kernel = ThroneKernel.ensure();
      if (kernel == null) {
        await _rollbackToBridge();
        return;
      }
      _kernel = kernel;
      try {
        final worker = await KernelWorker.spawn();
        _worker = worker;
        _workerSub = worker.events.listen(_onWorkerEvent, onError: report);
        // The Go side pushes a "status" event for every aggregate snapshot; the
        // worker heartbeat triggers it and uses the return value to detect loss.
        _statusSub = kernel.events
            .where((event) => event['method'] == 'status')
            .listen(_onKernelStatus, onError: report);
      } catch (_) {
        await _workerSub?.cancel();
        await _statusSub?.cancel();
        _workerSub = null;
        _statusSub = null;
        final worker = _worker;
        _worker = null;
        _kernel = null;
        if (worker != null) {
          try {
            await worker.dispose();
          } catch (_) {
            // The worker never came up; nothing to tear down.
          }
        }
        // Hand control back to the channel path so the app is still usable.
        await _rollbackToBridge();
        rethrow;
      }
    } finally {
      _initializing = false;
    }
  }

  /// Gives the core back to the service after the FFI driver failed to come up. A
  /// hand-over has already stopped the service-side box, so the service is asked to
  /// build one again — otherwise the app would sit "connected" with nothing running.
  Future<void> _rollbackToBridge() async {
    final rebuild = handoverPending;
    handoverPending = false;
    try {
      await box.call('ffi.mode', {'enabled': false});
      if (rebuild) await box.call('service.reload');
    } catch (error) {
      note('hand-over rollback: $error');
    }
  }

  /// Rebuilds the core after the bridge handed the control plane over: the service had
  /// started its own box before Dart attached and stopped it to avoid two on one tun.
  /// That close runs on the service's coroutine, so this waits for it to release the
  /// tun before opening the same one again.
  Future<void> adoptService() async {
    if (!handoverPending) return;
    handoverPending = false;
    if (_kernel == null) return;
    await Future<void>.delayed(const Duration(seconds: 1));
    if (_disposed || _kernel == null) return;
    note('adopt: the service came up before the driver, rebuilding its core');
    _recoveryAttempts = 0;
    await _startCore(bringUpService: true);
  }

  /// Starts the foreground service (Android duty) and the core itself.
  ///
  /// The two only meet when the core asks the platform for a tun, so they run at the same
  /// time: Android creating the service and Dart building the config have nothing to say to
  /// each other. Sequenced, the whole service bring-up (a process start, a notification, a
  /// VpnService instance) sat in front of a config build that then ran alone, and the user
  /// waited for the sum instead of the larger of the two.
  Future<void> startService() async {
    if (_kernel == null) return;
    note('start: user asked for the tunnel');
    // A start the user asked for is a fresh incident, whatever the last one cost.
    _recoveryAttempts = 0;
    await _startCore(bringUpService: true);
  }

  Future<void> stopService() async {
    if (_kernel == null) return;
    note('stop: user asked to stop');
    await _stopCore();
    await box.call('service.stop');
    _emitDashboard('Stopped');
  }

  /// Rebuilds the config and restarts the core in place (the foreground service stays).
  /// Only restarts if the core was running — a stopped service must not be pulled up
  /// by a stale selection-change or mode-switch event.
  Future<void> reloadService({String reason = 'reload'}) async {
    if (_kernel == null || !active) return;
    note('reload: $reason');
    await _stopCore(clearRunning: false);
    await _startCore();
  }

  /// Persists the running-config facts for the code that reads them off the store
  /// (`ProfileManager.runningUses`, `RouteManager.runningRouteId`). The values come
  /// straight from `config.build`, so this never re-derives what the native side
  /// already computed. A failure is a breadcrumb, not a failed start: the tunnel
  /// works without them, the two guards above just go quiet.
  Future<void> _markRunning(Map<String, dynamic> built) async {
    final raw = built['involvedProfileIds'];
    final ids = raw is List
        ? raw.whereType<num>().map((value) => value.toInt()).toList()
        : <int>[];
    final routeId = (built['routeId'] as num?)?.toInt() ?? 0;
    try {
      await box.call('state.markRunning', {'involvedProfileIds': ids, 'routeId': routeId});
    } catch (error) {
      note('running state: $error');
    }
  }

  Future<void> _clearRunning() async {
    try {
      await box.call('state.clearRunning');
    } catch (error) {
      note('running state: $error');
    }
  }

  /// Asks the core whether the running config needs Wi-Fi state, and turns the Android
  /// monitor on or off accordingly. Both halves matter: an unnecessary monitor keeps a
  /// ConnectivityManager callback alive, and a missing one silently drops every rule
  /// scoped to an SSID.
  Future<void> _watchWifiRules(KernelWorker worker) async {
    var needed = false;
    try {
      needed = await worker.needWifiState();
    } catch (error) {
      note('wifi rules: $error');
    }
    try {
      await box.call('wifi.watch', {'enabled': needed});
    } catch (error) {
      note('wifi rules: $error');
    }
  }

  /// An SSID/BSSID change announced by the Android monitor; the core re-reads the
  /// platform's state through the same `CorePlatform` implementation as always.
  Future<void> updateWifiState() async {
    final worker = _worker;
    if (worker == null || !active) return;
    try {
      await worker.updateWifiState();
    } catch (error) {
      note('wifi state: $error');
    }
  }

  Future<void> _startCore({bool bringUpService = false}) async {
    if (_kernel == null || _starting || _disposed) return;
    final worker = _worker;
    if (worker == null) return;
    _starting = true;
    _emitDashboard('Starting');
    final beganAt = DateTime.now();
    final clock = Stopwatch()..start();
    var serviceMs = 0;
    var configMs = 0;
    try {
      // Android's half runs alongside the build below: in ffiMode the service owns the
      // VpnService the core asks for a tun, and nothing in the config depends on it.
      final serviceUp = (bringUpService ? box.call('service.start') : Future<Object?>.value())
          .whenComplete(() => serviceMs = clock.elapsedMilliseconds);
      // The native DB owns the selection (DataStore.selectedProxy). The Flutter
      // preference store holds UI settings only, so mining it for an id used to
      // send 0 here and fail every start with "profile 0 is gone".
      final build = box.call('config.build', configBuildArgs())
          .whenComplete(() => configMs = clock.elapsedMilliseconds);
      // No eagerError: a failed start must not leave the other half running unobserved, and
      // the service's own error is the one worth reporting when both halves fail.
      final answers = await Future.wait<Object?>([serviceUp, build]);
      // The channel reply is a `Map<String, dynamic>` after BoxController.call
      // normalizes it. Use a checked conversion so a future codec change fails
      // with a readable message instead of a bare type-cast exception.
      final built = asStringKeyedMap(answers.last, context: 'config.build');
      final readyMs = clock.elapsedMilliseconds;
      final handle = await worker.createInstance(built);
      _instanceHandle = handle;
      final instanceMs = clock.elapsedMilliseconds;
      await worker.start();
      await worker.setHeartbeat(true);
      final startMs = clock.elapsedMilliseconds;
      _startedAt = DateTime.now();
      // Split by phase: the total alone cannot say whether the next second should be spent on
      // Android's service, on the config build, or inside the core's own start.
      final phases = [
        if (bringUpService) 'service $serviceMs',
        'config $configMs',
        'instance ${instanceMs - readyMs}',
        'start ${startMs - instanceMs}',
      ].join(', ');
      note('core started in ${DateTime.now().difference(beganAt).inMilliseconds}ms ($phases)');
      _emitDashboard('Started');
      // What the service used to write right after proxy.init(). Running a chain is not only the
      // box's business: ProfileManager.runningUses refuses to delete a node a running config still
      // uses, and RouteManager.runningRouteId decides whether a group's routing change needs a
      // reload. Both read the store, so the facts are reported here once the start held — after
      // the screen has been told the tunnel is up, since it reads none of them, and the two guards
      // above are only consulted when the user edits a profile or a route.
      await _markRunning(built);
      // Wi-Fi-scoped routes, DNS and rule sets need the core re-read whenever the SSID
      // changes. The monitor is Android's (it owns the callback); whether one is needed at
      // all is the core's answer, so ask the box that just started.
      await _watchWifiRules(worker);
    } catch (error) {
      note('core start FAILED: $error');
      report(error);
      // Release the instance that may have been partially started so the next
      // createInstance does not silently orphan it inside the worker isolate.
      try { await worker.stop(); } catch (_) { /* Already stopped or never started. */ }
      _instanceHandle = null;
      // A failed start leaves nothing running, and a reload that kept the old facts
      // would otherwise describe a core that is not there.
      await _clearRunning();
      _emitDashboard('Stopped');
    } finally {
      _starting = false;
    }
  }

  Future<void> _stopCore({bool clearRunning = true}) async {
    final handle = _instanceHandle;
    _instanceHandle = null;
    _startedAt = null;
    // Cleared before the box closes, so nothing reads "still running" while it shuts down. A
    // reload keeps the facts: the next start writes them again a moment later, and the gap is
    // not a stop the user asked for. The Wi-Fi monitor follows the same rule — it is useless
    // without a box, and rebuilding it on every reload would drop a change that lands between.
    if (clearRunning) {
      await _clearRunning();
      try {
        await box.call('wifi.watch', {'enabled': false});
      } catch (error) {
        note('wifi rules: $error');
      }
    }
    final worker = _worker;
    if (handle == null || worker == null) return;
    _stopping = true;
    _emitDashboard('Stopping');
    try {
      await worker.setHeartbeat(false);
      await worker.stop();
    } catch (error) {
      report(error);
    } finally {
      _stopping = false;
    }
  }

  // --- operations ---------------------------------------------------------

  /// Outbound mode (rule/global/direct): persist, then rebuild the routing config.
  Future<void> setMode(String mode) async {
    if (_kernel == null) return;
    await box.call('state.setMode', {'mode': mode});
    await reloadService(reason: 'outbound mode -> $mode');
    _emitDashboard(null, mode: mode);
  }

  /// A profile/group selection already persisted by the channel; the core follows.
  Future<void> onSelectionChanged() async {
    if (_kernel == null) return;
    await reloadService(reason: 'profile selection changed');
    _emitDashboard(null);
  }

  /// WARP registration through the kernel (Mobile.warpRegister + amnezia packets).
  Future<dynamic> warpRegister(String tunnelType) async {
    final worker = _worker;
    if (_kernel == null || worker == null) {
      return box.call('warp.register', {'tunnelType': tunnelType});
    }
    final params = asStringKeyedMap(
      await box.call('config.warpParams', {'tunnelType': tunnelType}),
      context: 'config.warpParams',
    );
    final result = await worker.warpRegister(tunnelType, params);
    return box.call('state.saveWarpKeys', {
      'tunnelType': tunnelType,
      'identity': result['identity'],
      'packets': result['packets'],
      'packetsError': result['packetsError'],
    });
  }

  /// Domain resolution through the box Dart owns. In FFI mode the service never
  /// creates a `ProxyInstance`, so `dns.resolve` could only answer "not running";
  /// the C ABI's `Mobile.resolveDomains` takes the handle this driver already holds.
  Future<Map<String, dynamic>> resolveDomains(List<String> domains) async {
    final worker = _worker;
    if (worker == null || !active) {
      return <String, dynamic>{'running': false, 'results': const <Object?>[]};
    }
    return worker.resolveDomains(domains);
  }

  // --- events --------------------------------------------------------------

  void _onKernelStatus(BridgeEvent event) {
    final data = event['data'];
    if (data is! Map) return;
    final snapshot = <String, int>{};
    for (final entry in data.entries) {
      final value = (entry.value as num?)?.toInt();
      if (value != null) snapshot[entry.key.toString()] = value;
    }
    _emitStatus(snapshot);
    _publishStats(snapshot);
  }

  /// The notification's speed line and the widget read the service's own counters, and in
  /// FFI mode nothing on that side polls the core — `TrafficLooper` needs a ProxyInstance.
  /// Push the same snapshot it would have produced; the screen-off rule is already handled
  /// on the Kotlin side by `listenPostSpeed`.
  void _publishStats(Map<String, int> snapshot) {
    if (_disposed) return;
    unawaited(() async {
      try {
        await box.call('state.stats', {
          'txRate': snapshot['uplink'] ?? 0,
          'rxRate': snapshot['downlink'] ?? 0,
          'txTotal': snapshot['uplinkTotal'] ?? 0,
          'rxTotal': snapshot['downlinkTotal'] ?? 0,
        });
      } catch (_) {
        // A notification that cannot be updated is not a reason to lose the status stream.
      }
    }());
  }

  void _onWorkerEvent(WorkerEvent event) {
    if (event['type'] != 'lost') return;
    final reason = event['error'];
    report(StateError(reason is String && reason.isNotEmpty
        ? 'the kernel stopped responding: $reason'
        : 'the kernel stopped responding'));
    _emitDashboard('Stopped');
    _recoverOnce();
  }

  /// Restarts a lost core with a growing delay, and stops after
  /// [_maxRecoveries] attempts in a row. A core that dies, comes back and dies
  /// again seconds later is not fixed by another restart: looping forever only
  /// hides the failure, so the last attempt is reported and left alone.
  Future<void> _recoverOnce() async {
    if (_recovering) return;
    // A run that held for a while is a new incident, not a repeat of the last one.
    final ranFor = _startedAt == null ? null : DateTime.now().difference(_startedAt!);
    if (ranFor != null && ranFor >= const Duration(minutes: 1)) _recoveryAttempts = 0;
    if (_recoveryAttempts >= _maxRecoveries) {
      report(StateError(
          'the kernel cannot stay up; automatic recovery stopped after $_maxRecoveries attempts'));
      return;
    }
    _recovering = true;
    final attempt = _recoveryAttempts;
    _recoveryAttempts++;
    try {
      if (attempt > 0) {
        _emitDashboard('Starting');
        await Future<void>.delayed(
            attempt == 1 ? const Duration(seconds: 10) : const Duration(seconds: 30));
        if (!active) return; // the user stopped it while waiting
      }
      await reloadService(reason: 'heartbeat lost, attempt ${attempt + 1}');
      if (active) report('the kernel was restarted automatically');
    } catch (error) {
      report(error);
    } finally {
      _recovering = false;
    }
  }

  void _emitStatus(Map<String, int> snapshot) {
    if (_disposed) return;
    _events.add({
      'type': 'rates',
      'value': {
        'upload': snapshot['uplink'] ?? 0,
        'download': snapshot['downlink'] ?? 0,
        'memoryBytes': snapshot['memory'] ?? 0,
      },
    });
    _emitDashboard(
      _stopping ? 'Stopping' : (_starting ? 'Starting' : 'Started'),
      snapshot: snapshot,
    );
  }

  /// Emits the dashboard wire (the shape ThroneBoxBridge.dashboardWire produces),
  /// carrying the last known static fields and overriding the live numbers.
  void _emitDashboard(String? status, {Map<String, int>? snapshot, String? mode}) {
    if (_disposed) return;
    final previous = box.dashboard;
    final profiles = box.profiles;
    final selectedId = _selectedProfileId();
    String name = previous['selectedProfileName'] as String? ?? '';
    for (final row in profiles) {
      if (row['id'] == selectedId) {
        name = row['name'] as String? ?? name;
        break;
      }
    }
    final effectiveStatus = status ?? previous['status'] ?? 'Stopped';
    // Clear startedAt when stopped so the dashboard does not show a stale timer.
    final startedAt = effectiveStatus == 'Stopped' || effectiveStatus == 'Idle'
        ? 0
        : (_startedAt?.millisecondsSinceEpoch ?? (previous['startedAt'] as num?)?.toInt() ?? 0);
    _events.add({
      'type': 'dashboard',
      'value': {
        ...previous,
        'status': effectiveStatus,
        'selectedProfileId': selectedId,
        'selectedProfileName': name,
        'modes': previous['modes'] ?? ['rule', 'global', 'direct'],
        'mode': mode ?? previous['mode'] ?? 'rule',
        'startedAt': startedAt,
        'uploadTotal': snapshot?['uplinkTotal'] ?? previous['uploadTotal'] ?? 0,
        'downloadTotal': snapshot?['downlinkTotal'] ?? previous['downloadTotal'] ?? 0,
        'connections': (snapshot?['connectionsIn'] ?? 0) + (snapshot?['connectionsOut'] ?? 0),
        'memory': snapshot?['memory'] ?? previous['memory'] ?? 0,
        'goroutines': snapshot?['goroutines'] ?? previous['goroutines'] ?? 0,
      },
    });
  }

  /// Display-only: B-box's dashboard id is the selected *group* id, matching the
  /// ids in `box.profiles`. It is not a proxy entity id and must never be sent to
  /// `config.build` — the native side resolves that from DataStore.selectedProxy.
  int _selectedProfileId() => dashboardSelectedId(box.dashboard);

  void report(Object error) {
    if (_disposed) return;
    _events.add({'type': 'error', 'value': error.toString()});
  }

  /// Writes one lifecycle breadcrumb into the core log — the same file the log
  /// screen shows. A core that closes on its own leaves no trace of who asked
  /// for it, which is exactly what a start/restart loop is made of; these lines
  /// name the caller and the reason.
  void note(String text) {
    if (_disposed) return;
    unawaited(() async {
      try {
        await box.call('log.note', {'text': text});
      } catch (_) {
        // Diagnostics must never be the reason a lifecycle step fails.
      }
    }());
  }

  void dispose() {
    _disposed = true;
    unawaited(_workerSub?.cancel());
    unawaited(_statusSub?.cancel());
    final worker = _worker;
    _worker = null;
    if (worker != null) unawaited(worker.dispose());
    _events.close();
    _kernel?.dispose();
    _kernel = null;
    _instanceHandle = null;
  }
}

/// The `config.build` payload: deliberately no `id`. The native bridge resolves
/// the selected ProxyEntity from DataStore.selectedProxy; neither the Flutter
/// UI preferences (appearance settings only) nor the dashboard's group id is a
/// proxy entity id. Sending a guessed 0 used to fail with "profile 0 is gone".
Json configBuildArgs() => <String, dynamic>{};

/// The dashboard's selected id is a *group* id (B-box's profile card), used only
/// for display and for looking the name up in `box.profiles`.
int dashboardSelectedId(Json dashboard) =>
    (dashboard['selectedProfileId'] as num?)?.toInt() ?? -1;
