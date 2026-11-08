// The Dart-side runtime for the self-owned kernel bridge.
//
// Dart controls the kernel directly: `DynamicLibrary.open('libthrone.so')` exposes
// the throne_* C ABI (bindings generated in `thone_ffi.dart`), and kernel events
// arrive on a ReceivePort the Go side posts JSON to — the bettbox message-port
// pattern. The method channel stays for Android duties only (VpnService,
// notifications, the platform databases); kernel calls route here whenever the
// rebuilt core is present.
//
// Until the AAR is rebuilt with `buildScript/core-patch`, the symbols are absent
// and `isAvailable` reports false — the BoxController keeps the channel path.

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';


import 'throne_ffi.dart';

/// One JSON event posted by the Go side (`sendEvent` / `postTo`).
typedef BridgeEvent = Map<String, dynamic>;

class ThroneKernel {
  ThroneKernel._(this.ffi, this._port) {
    ffi.throne_init_dart_api(NativeApi.initializeApiDLData);
    ffi.throne_attach_message_port(_port.sendPort.nativePort);
    _port.listen((raw) {
      final event = decodeBridgeEvent(raw);
      if (event != null) _events.add(event);
    });
  }

  static ThroneKernel? _instance;
  static bool? _available;

  /// True when the rebuilt core (with the throne_* C ABI) is present.
  static bool get isAvailable {
    if (_available != null) return _available!;
    try {
      final lib = DynamicLibrary.open('libthrone.so');
      lib.lookup('throne_Mobile_setup');
      _available = true;
    } catch (_) {
      _available = false;
    }
    return _available!;
  }

  /// Opens the library and wires the message port. No-op when unavailable.
  static ThroneKernel? ensure() {
    if (_instance != null) return _instance;
    if (!isAvailable) return null;
    final lib = DynamicLibrary.open('libthrone.so');
    _instance = ThroneKernel._(ThroneFFI(lib), ReceivePort());
    return _instance;
  }

  final ThroneFFI ffi;
  final ReceivePort _port;
  final _events = StreamController<BridgeEvent>.broadcast();

  /// Every JSON event the kernel posts (logs, test results, ...).
  Stream<BridgeEvent> get events => _events.stream;

  /// Log lines: `{level, message}` per event (LogSink replacement).
  Stream<BridgeEvent> get logs =>
      events.where((e) => e['method'] == 'log').map((e) => Map<String, dynamic>.from(e['data'] as Map));

  /// Per-call reply port (the URLTest/IPTest/SpeedTest handler replacement):
  /// pass [nativePort] where the C ABI takes a handler port and read replies
  /// from [stream] until `*Done` arrives.
  ReplyPort openReply() => ReplyPort._();

  void dispose() {
    _port.close();
    _events.close();
    _instance = null;
  }
}

/// A temporary ReceivePort used as the reply address of one async call.
class ReplyPort {
  ReplyPort._() : _port = ReceivePort() {
    _sub = _port.listen((raw) {
      final event = decodeBridgeEvent(raw);
      if (event != null) _controller.add(event);
    });
  }

  final ReceivePort _port;
  final _controller = StreamController<BridgeEvent>.broadcast();
  late final StreamSubscription<dynamic> _sub;

  /// The C `int64_t` port value the C ABI expects.
  int get nativePort => _port.sendPort.nativePort;

  Stream<BridgeEvent> get stream => _controller.stream;

  void close() {
    _sub.cancel();
    _port.close();
    _controller.close();
  }
}
