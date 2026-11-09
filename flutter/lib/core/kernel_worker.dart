// The single long-lived isolate that owns the FFI view of the kernel.
//
// Before this, every kernel operation used Isolate.run: a fresh DynamicLibrary,
// a fresh ThroneFFI and a fresh object graph per call, stitched together only
// by the process-global handle table. Status polling did that once a second and
// leaked a StatusMessage handle each time.
//
// Now the FFI is opened exactly once, the Instance wrapper is retained by this
// isolate (so its finalizer cannot collect it out from under the caller), and
// temporary wrappers are released explicitly. The heartbeat calls one aggregate
// status snapshot; the Go side pushes the same snapshot to the UI message port.
// Errors and "core lost" detections travel back over an event port instead of
// being swallowed by debugPrint.

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'kernel_heartbeat.dart';
import 'platform_value.dart';
import 'throne_ffi.dart';

enum KernelCommand {
  createInstance,
  adoptInstance,
  start,
  stop,
  setHeartbeat,
  warpRegister,
  needWifiState,
  updateWifiState,
  dispose,
}

/// Events from the worker: `{'type': 'lost'}` or `{'type': 'error', ...}`.
typedef WorkerEvent = Map<String, dynamic>;

/// How long a fresh start may go without a status before a miss counts. The
/// box is still opening its tun and loading rule sets in that window.
const heartbeatGrace = Duration(seconds: 12);

/// How long the status must stay unreadable *after* a good beat to call the
/// core lost. A single slow read under load is not a lost core.
const heartbeatGiveUpAfter = Duration(seconds: 8);

class KernelWorker {
  KernelWorker._(this._commands, this._events, this._eventsPort);

  final SendPort _commands;
  final Stream<WorkerEvent> _events;
  final ReceivePort _eventsPort;
  bool _disposed = false;

  Stream<WorkerEvent> get events => _events;

  static Future<KernelWorker> spawn() async {
    final events = ReceivePort();
    final ready = ReceivePort();
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
          _workerMain, <Object>[events.sendPort, ready.sendPort]);
    } catch (_) {
      // The spawn itself failed before any cleanup path existed; without
      // closing these the two native ports would leak.
      events.close();
      ready.close();
      rethrow;
    }
    late final SendPort commands;
    try {
      commands = await ready.first.timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw StateError('the kernel worker did not start'),
      ) as SendPort;
    } catch (_) {
      // The worker never came up (a timeout, or its first message was not the
      // command port). Without this, the isolate would live on holding
      // libthrone.so open, with an events port nobody ever reads.
      isolate.kill(priority: Isolate.beforeNextEvent);
      events.close();
      rethrow;
    } finally {
      ready.close();
    }
    return KernelWorker._(
      commands,
      events.map((raw) => asStringKeyedMap(raw, context: 'worker event')).asBroadcastStream(),
      events,
    );
  }

  Future<Object?> _call(KernelCommand command, [Object? payload]) async {
    final reply = ReceivePort();
    try {
      _commands.send(<Object?>[reply.sendPort, command.index, payload]);
      final result = await reply.first.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw StateError('the kernel worker timed out on ${command.name}'),
      );
      if (result is Map && result['__error'] is String) {
        throw StateError(result['__error'] as String);
      }
      return result;
    } finally {
      reply.close();
    }
  }

  /// Builds StartOptions, creates the Instance and releases the options handle.
  Future<int> createInstance(Map<String, dynamic> built) async =>
      (await _call(KernelCommand.createInstance, built))! as int;

  /// Re-attaches to an Instance the host adopted when the previous Flutter
  /// engine died. The Go handle table is process-wide, so the numeric handle is
  /// still valid; false means it was closed in the meantime.
  Future<bool> adoptInstance(int handle) async =>
      (await _call(KernelCommand.adoptInstance, handle)) == true;

  Future<void> start() => _call(KernelCommand.start);

  /// Closes the Instance and releases its handle (the only release path).
  Future<void> stop() => _call(KernelCommand.stop);

  Future<void> setHeartbeat(bool enabled) =>
      _call(KernelCommand.setHeartbeat, enabled);

  /// Whether the running config asks for Wi-Fi state at all (a Wi-Fi-scoped route,
  /// DNS or rule set). Asked after the start, when there is an instance to ask.
  Future<bool> needWifiState() async =>
      (await _call(KernelCommand.needWifiState)) == true;

  /// Tells the core to re-read the platform's SSID/BSSID (the Kotlin side reads it).
  Future<void> updateWifiState() => _call(KernelCommand.updateWifiState);

  Future<Map<String, dynamic>> warpRegister(
    String tunnelType,
    Map<String, dynamic> params,
  ) async {
    final result = await _call(
      KernelCommand.warpRegister,
      <String, dynamic>{'tunnelType': tunnelType, 'params': params},
    );
    return asStringKeyedMap(result, context: 'warp.register result');
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _call(KernelCommand.dispose);
    } finally {
      _eventsPort.close();
    }
  }
}

void _workerMain(List<Object> init) {
  final events = init[0] as SendPort;
  final ready = init[1] as SendPort;
  final commands = ReceivePort();
  final ffi = ThroneFFI(DynamicLibrary.open('libthrone.so'));
  ffi.throne_Mobile_setLogSink();

  ThroneInstance? instance;
  final heartbeatPolicy = KernelHeartbeatPolicy();
  Timer? heartbeat;
  // The core answers a status only once its box is up, and a start can take a
  // few seconds (tun, rule sets, xray assets) before that. Counting raw misses
  // turned a slow start into three "lost" beats, and the recovery then closed
  // the box it had just opened: the service restarted every few seconds and
  // never stayed up. A miss now only counts once the start has had its grace
  // period and the last good beat is older than [heartbeatGiveUpAfter].
  heartbeat = Timer.periodic(const Duration(seconds: 1), (_) {
    final current = instance;
    if (!heartbeatPolicy.enabled || current == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final snapshot = throneStatusSnapshot(ffi, current.handle);
    // The numbers were unreadable this second. That is not the same as a dead
    // core: reading the traffic counters races a busy box, and a panic there used
    // to end the snapshot and, with it, a tunnel that was carrying traffic all
    // along. Ask the cheap question — is the box still started — before counting
    // a miss, and only a box that really stopped counts as lost.
    final lost = heartbeatPolicy.observe(
      nowMs: now,
      snapshotReadable: snapshot != null,
      instanceAlive: ffi.throne_Instance_alive(current.handle) != 0,
      grace: heartbeatGrace,
      giveUpAfter: heartbeatGiveUpAfter,
    );
    if (lost) events.send(<String, dynamic>{'type': 'lost', 'error': throneLastError(ffi)});
  });

  ready.send(commands.sendPort);
  commands.listen((raw) {
    final message = raw as List<Object?>;
    final reply = message[0] as SendPort;
    final command = KernelCommand.values[message[1]! as int];
    final payload = message[2];
    try {
      switch (command) {
        case KernelCommand.createInstance:
          final built = asStringKeyedMap(payload, context: 'createInstance payload');
          // Release any previous instance before creating a new one to prevent orphans.
          final previous = instance;
          if (previous != null) {
            instance = null;
            try { previous.close(); }
            finally { previous.release(); }
          }
          final options = _startOptions(ffi, built);
          try {
            final created = ThroneMobile.newInstance(ffi, options.handle);
            if (created == null) {
              throw StateError('the kernel refused to create an instance');
            }
            instance = created;
            heartbeatPolicy.prepare();
            reply.send(created.handle);
          } finally {
            options.release();
          }
        case KernelCommand.adoptInstance:
          final adoptedHandle = payload! as int;
          if (ffi.throne_Instance_alive(adoptedHandle) == 0) {
            reply.send(false);
          } else {
            // The previous engine's isolate is gone, so this worker holds no
            // instance of its own; only the process-wide Go handle survives.
            final previous = instance;
            if (previous != null) {
              instance = null;
              try { previous.close(); }
              finally { previous.release(); }
            }
            instance = ThroneInstance(ffi, adoptedHandle);
            heartbeatPolicy.start(DateTime.now().millisecondsSinceEpoch);
            reply.send(true);
          }
        case KernelCommand.start:
          final current = instance;
          if (current == null) throw StateError('no kernel instance to start');
          current.start();
          // The clock for the heartbeat starts here, not at the process start:
          // the grace period exists for the box this call just opened.
          heartbeatPolicy.start(DateTime.now().millisecondsSinceEpoch);
          reply.send(null);
        case KernelCommand.stop:
          heartbeatPolicy.stop();
          final current = instance;
          instance = null;
          if (current != null) {
            try { current.close(); }
            finally { current.release(); }
          }
          reply.send(null);
        case KernelCommand.setHeartbeat:
          heartbeatPolicy.setEnabled(payload as bool, DateTime.now().millisecondsSinceEpoch);
          reply.send(null);
        case KernelCommand.warpRegister:
          final data = asStringKeyedMap(payload, context: 'warpRegister payload');
          reply.send(_warpRegister(
            ffi,
            data['tunnelType'] as String,
            asStringKeyedMap(data['params'], context: 'warp params'),
          ));
        case KernelCommand.needWifiState:
          final current = instance;
          reply.send(current != null && current.needWIFIState());
        case KernelCommand.updateWifiState:
          instance?.updateWIFIState();
          reply.send(null);
        case KernelCommand.dispose:
          heartbeatPolicy.stop();
          heartbeat?.cancel();
          // Release any still-running instance so the native handle is not orphaned.
          final current = instance;
          instance = null;
          if (current != null) {
            try { current.close(); }
            finally { current.release(); }
          }
          reply.send(null);
          commands.close();
      }
    } catch (error) {
      reply.send(<String, dynamic>{'__error': error.toString()});
    }
  });
}

/// Assembles StartOptions from the native `config.build` payload.
ThroneStartOptions _startOptions(ThroneFFI ffi, Map<String, dynamic> built) {
  final options = ThroneStartOptions.create(ffi);
  options.setCoreConfig(built['coreConfig'] as String? ?? '');
  options.setNeedXray(built['needXray'] as bool? ?? false);
  options.setXrayConfig(built['xrayConfig'] as String? ?? '');
  options.setXrayOutboundDNSStrategy(built['xrayDnsStrategy'] as String? ?? '');
  // A channel reply can carry a List<Object?> here; cast<String>() would build
  // a view that throws on the first non-string element while iterating.
  final rawFull = built['xrayFullConfigs'];
  final full = rawFull is List ? rawFull.whereType<String>().toList() : <String>[];
  for (final config in full) {
    options.addXrayFullConfig(config);
  }
  // BoxInstance.toStartOptions: the idle window must outlast the probe interval.
  final intervalSec = built['autoSelectorIntervalSec'] as int? ?? 0;
  if (intervalSec > 0 && (built['needXray'] == true || full.isNotEmpty)) {
    options.setXrayLazyStart(true);
    options.setXrayIdleSeconds(intervalSec * 2 > 120 ? intervalSec * 2 : 120);
    options.setXrayFullIdleSeconds(0);
  }
  return options;
}

Map<String, dynamic> _warpRegister(
  ThroneFFI ffi,
  String tunnelType,
  Map<String, dynamic> params,
) {
  final request = ThroneWarpRegisterRequest.create(ffi);
  ThroneWarpIdentity? identity;
  ThroneStringIterator? iterator;
  try {
    request.setTunnelType(tunnelType);
    request.setProxy((params['proxy'] as String?) ?? '');
    for (final host in (params['hosts'] as List? ?? const [])) {
      request.addAPIHost(host.toString());
    }
    identity = ThroneMobile.warpRegister(ffi, request.handle);
    if (identity == null) throw StateError('warp: the kernel returned no identity');
    final reserved = identity.getReserved();
    final identityMap = <String, dynamic>{
      'deviceId': identity.getDeviceID(),
      'token': identity.getToken(),
      'license': identity.getLicense(),
      'ipv4': identity.getIPv4(),
      'ipv6': identity.getIPv6(),
      'privateKey': identity.getPrivateKey(),
      'peerPublicKey': identity.getPeerPublicKey(),
      'endpoint': identity.getEndpoint(),
      'reserved': reserved.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
    };
    String? packetsError;
    var packets = <String>[];
    if (params['mode'] == 'amnezia') {
      try {
        iterator = ThroneMobile.genQuicSignature(ffi, 'www.cloudflare.com');
        packets = iterator?.toList() ?? [];
        if (packets.isEmpty || packets.length > 5 || packets.any((p) => p.isEmpty)) {
          packetsError = 'the core returned an invalid QUIC signature';
        }
      } catch (error) {
        packetsError = error.toString();
      }
    }
    return <String, dynamic>{
      'identity': identityMap,
      'packets': packets,
      'packetsError': packetsError,
    };
  } finally {
    iterator?.release();
    identity?.release();
    request.release();
  }
}

extension on ThroneStringIterator {
  List<String> toList() {
    final out = <String>[];
    while (hasNext()) {
      out.add(next());
    }
    return out;
  }
}
