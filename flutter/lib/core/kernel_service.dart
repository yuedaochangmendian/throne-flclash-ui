// The Dart-driven kernel lifecycle (the FFI path): Dart owns the core through
// dart:ffi — build the config over the slim channel, start/stop/reload the
// Instance directly, and stream the status back as the channel-shaped events the
// UI already consumes. Every operation falls back to the method channel when the
// rebuilt core is absent (ThroneKernel.isAvailable == false).
//
// The services themselves (foreground notification, VPN establish) stay Android
// duties over the channel; the kernel calls never touch it.

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../box.dart';
import 'throne_ffi.dart';
import 'throne_kernel.dart';

class KernelService {
  KernelService(this.box);

  final BoxController box;

  final _events = StreamController<Map<String, dynamic>>.broadcast();

  /// Channel-shaped events (`{type, value}`) the BoxController feeds to _onEvent.
  Stream<Map<String, dynamic>> get events => _events.stream;

  ThroneKernel? _kernel;
  ThroneInstance? _instance;
  int _profileId = 0;
  DateTime? _startedAt;
  bool _starting = false;
  bool _stopping = false;
  Timer? _poll;

  /// True when the rebuilt core is present and the FFI path drives it.
  bool get active => _kernel != null && _instance != null;

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
    // LogSink lives on the message port; the in-process gobind sink steps aside.
    // (The BoxController already routes the port's log events — the dual path.)
    kernel.ffi.throne_Mobile_setLogSink();
    _startPoll();
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
    _starting = true;
    _emitDashboard('Starting');
    try {
      final profileId = _selectedProfileId();
      final built = await box.call('config.build', {'id': profileId}) as Map<String, dynamic>;
      _profileId = profileId;
      final instance = await Isolate.run(() {
        final ffi = ThroneFFI(DynamicLibrary.open('libthrone.so'));
        final options = _startOptions(ffi, built);
        return _newInstance(ffi, options.handle);
      });
      final kernel = _kernel!;
      // Re-wrap the returned handle on this isolate's view of the ABI.
      _instance = ThroneInstance(kernel.ffi, instance);
      await Isolate.run(() {
        final ffi = ThroneFFI(DynamicLibrary.open('libthrone.so'));
        ThroneInstance(ffi, instance).start();
      });
      _startedAt = DateTime.now();
      _emitDashboard('Started');
    } catch (error) {
      report(error);
      _emitDashboard('Stopped');
    } finally {
      _starting = false;
    }
  }

  Future<void> _stopCore() async {
    final instance = _instance;
    _instance = null;
    _startedAt = null;
    if (instance == null || _kernel == null) return;
    _stopping = true;
    _emitDashboard('Stopping');
    try {
      await Isolate.run(() {
        final ffi = ThroneFFI(DynamicLibrary.open('libthrone.so'));
        ThroneInstance(ffi, instance.handle).close();
      });
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
    if (_kernel == null) {
      return box.call('warp.register', {'tunnelType': tunnelType});
    }
    final params = await box.call('config.warpParams', {'tunnelType': tunnelType}) as Map<String, dynamic>;
    final result = await Isolate.run(() {
      final ffi = ThroneFFI(DynamicLibrary.open('libthrone.so'));
      final request = ThroneWarpRegisterRequest.create(ffi);
      request.setTunnelType(tunnelType);
      request.setProxy((params['proxy'] as String?) ?? '');
      for (final host in (params['hosts'] as List? ?? const [])) {
        request.addAPIHost(host.toString());
      }
      final identity = ThroneMobile.warpRegister(ffi, request.handle);
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
          final iterator = ThroneMobile.genQuicSignature(ffi, 'www.cloudflare.com');
          packets = iterator?.toList() ?? [];
          if (packets.isEmpty || packets.length > 5 || packets.any((p) => p.isEmpty)) {
            packetsError = 'the core returned an invalid QUIC signature';
          }
        } catch (error) {
          packetsError = error.toString();
        }
      }
      return {
        'identity': identityMap,
        'packets': packets,
        'packetsError': packetsError,
      };
    });
    return box.call('state.saveWarpKeys', {
      'tunnelType': tunnelType,
      'identity': result['identity'],
      'packets': result['packets'],
      'packetsError': result['packetsError'],
    });
  }

  // --- status stream -------------------------------------------------------

  void _startPoll() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _pollStatus());
  }

  Future<void> _pollStatus() async {
    final kernel = _kernel;
    final instance = _instance;
    if (kernel == null || instance == null) return;
    try {
      final snapshot = await Isolate.run(() {
        final ffi = ThroneFFI(DynamicLibrary.open('libthrone.so'));
        final status = ThroneInstance(ffi, instance.handle).status();
        if (status == null) return null;
        return <String, int>{
          'memory': status.getMemory(),
          'goroutines': status.getGoroutines(),
          'connectionsIn': status.getConnectionsIn(),
          'connectionsOut': status.getConnectionsOut(),
          'uplink': status.getUplink(),
          'downlink': status.getDownlink(),
          'uplinkTotal': status.getUplinkTotal(),
          'downlinkTotal': status.getDownlinkTotal(),
        };
      });
      if (snapshot == null) return;
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
    } catch (error) {
      // A poll failure is a blip, not a banner.
      debugPrint('kernel poll: $error');
    }
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

  int _selectedProfileId() {
    final preferences = box.preferences;
    final raw = preferences['selectedProxy'] ?? preferences['profileId'] ?? 0;
    return (raw as num?)?.toInt() ?? 0;
  }

  void report(Object error) {
    _events.add({'type': 'error', 'value': error.toString()});
  }

  void dispose() {
    _poll?.cancel();
    _events.close();
    _kernel?.dispose();
    _kernel = null;
    _instance = null;
  }
}

/// The handle-side StartOptions assembly (shared by the worker isolates).
ThroneStartOptions _startOptions(ThroneFFI ffi, Map<String, dynamic> built) {
  final options = ThroneStartOptions.create(ffi);
  options.setCoreConfig(built['coreConfig'] as String? ?? '');
  options.setNeedXray(built['needXray'] as bool? ?? false);
  options.setXrayConfig(built['xrayConfig'] as String? ?? '');
  options.setXrayOutboundDNSStrategy(built['xrayDnsStrategy'] as String? ?? '');
  final full = (built['xrayFullConfigs'] as List? ?? const []).cast<String>();
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

int _newInstance(ThroneFFI ffi, int optionsHandle) {
  final instance = ThroneMobile.newInstance(ffi, optionsHandle);
  if (instance == null) throw StateError('the kernel refused to create an instance');
  return instance.handle;
}

/// Iterator helpers over the generated wrapper types.
extension on ThroneStringIterator {
  List<String> toList() {
    final out = <String>[];
    while (hasNext()) {
      out.add(next());
    }
    return out;
  }
}
