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

  /// True when the rebuilt core is present and the FFI path drives it.
  bool get active => _kernel != null && _instanceHandle != null;

  /// True once the FFI path is engaged (the channel handlers step aside).
  bool get ffiMode => _kernel != null;

  // --- lifecycle ----------------------------------------------------------

  Future<void> initialize() async {
    if (_kernel != null) return;
    // Tell the bridge the FFI path drives the core from now on, then open the ABI.
    await box.call('ffi.mode', {'enabled': true});
    final kernel = ThroneKernel.ensure();
    if (kernel == null) {
      await box.call('ffi.mode', {'enabled': false});
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
      await box.call('ffi.mode', {'enabled': false});
      rethrow;
    }
  }

  /// Starts the foreground service (Android duty) and then the core itself.
  Future<void> startService() async {
    if (_kernel == null) return;
    await box.call('service.start'); // foreground only in ffiMode
    await _startCore();
  }

  Future<void> stopService() async {
    if (_kernel == null) return;
    await _stopCore();
    await box.call('service.stop');
    _emitDashboard('Stopped');
  }

  /// Rebuilds the config and restarts the core in place (the foreground service stays).
  Future<void> reloadService() async {
    if (_kernel == null) return;
    await _stopCore();
    await _startCore();
  }

  Future<void> _startCore() async {
    if (_kernel == null || _starting) return;
    final worker = _worker;
    if (worker == null) return;
    _starting = true;
    _emitDashboard('Starting');
    try {
      // The native DB owns the selection (DataStore.selectedProxy). The Flutter
      // preference store holds UI settings only, so mining it for an id used to
      // send 0 here and fail every start with "profile 0 is gone".
      // The channel reply is a `Map<String, dynamic>` after BoxController.call
      // normalizes it. Use a checked conversion so a future codec change fails
      // with a readable message instead of a bare type-cast exception.
      final built = asStringKeyedMap(
        await box.call('config.build', configBuildArgs()),
        context: 'config.build',
      );
      final handle = await worker.createInstance(built);
      _instanceHandle = handle;
      await worker.start();
      await worker.setHeartbeat(true);
      _startedAt = DateTime.now();
      _emitDashboard('Started');
    } catch (error) {
      report(error);
      _instanceHandle = null;
      _emitDashboard('Stopped');
    } finally {
      _starting = false;
    }
  }

  Future<void> _stopCore() async {
    final handle = _instanceHandle;
    _instanceHandle = null;
    _startedAt = null;
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
    await reloadService();
    _emitDashboard(null, mode: mode);
  }

  /// A profile/group selection already persisted by the channel; the core follows.
  Future<void> onSelectionChanged() async {
    if (_kernel == null) return;
    await reloadService();
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

  // --- events --------------------------------------------------------------

  void _onKernelStatus(BridgeEvent event) {
    final data = event['data'];
    if (data is! Map) return;
    final snapshot = data.map(
      (key, value) => MapEntry(key.toString(), (value as num).toInt()),
    );
    _emitStatus(snapshot);
  }

  void _onWorkerEvent(WorkerEvent event) {
    if (event['type'] != 'lost') return;
    report(StateError('the kernel stopped responding'));
    _emitDashboard('Stopped');
    _recoverOnce();
  }

  /// One automatic restart after a lost core; further failures stay visible.
  Future<void> _recoverOnce() async {
    if (_recovering) return;
    _recovering = true;
    try {
      await reloadService();
      if (active) report('the kernel was restarted automatically');
    } catch (error) {
      report(error);
    } finally {
      _recovering = false;
    }
  }

  void _emitStatus(Map<String, int> snapshot) {
    _events.add({
      'type': 'rates',
      'value': {
        'upload': snapshot['uplink'],
        'download': snapshot['downlink'],
        'memoryBytes': snapshot['memory'],
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
    _events.add({
      'type': 'dashboard',
      'value': {
        ...previous,
        'status': status ?? previous['status'] ?? 'Stopped',
        'selectedProfileId': selectedId,
        'selectedProfileName': name,
        'modes': previous['modes'] ?? ['rule', 'global', 'direct'],
        'mode': mode ?? previous['mode'] ?? 'rule',
        'startedAt': _startedAt?.millisecondsSinceEpoch ?? previous['startedAt'] ?? 0,
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
    _events.add({'type': 'error', 'value': error.toString()});
  }

  void dispose() {
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
