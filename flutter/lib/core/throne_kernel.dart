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

import 'package:ffi/ffi.dart';

import 'action.dart';
import 'throne_ffi.dart';

/// One JSON event posted by the Go side (`sendEvent` / `postTo`).
typedef BridgeEvent = Map<String, dynamic>;

class ThroneKernel {
  ThroneKernel._(this.ffi, this._port, this._replyPort) {
    ffi.throne_init_dart_api(NativeApi.initializeApiDLData);
    ffi.throne_attach_message_port(_port.sendPort.nativePort);
    _port.listen((raw) {
      final event = decodeBridgeEvent(raw);
      if (event != null) _events.add(event);
    });
    // Action results arrive on a dedicated port: the C ABI takes a reply port
    // per call, and keeping one long-lived reply port avoids allocating an
    // isolate port for every request. Results are demuxed by their echoed id.
    _replyPort.listen((raw) {
      final result = ActionResult.decode(raw);
      if (result == null || result.id.isEmpty) return;
      final completer = _pending.remove(result.id);
      if (completer == null || completer.isCompleted) return;
      if (result.isError) {
        completer.completeError(
          ActionException(result.method, '${result.data ?? 'action failed'}'),
        );
      } else {
        completer.complete(result.data);
      }
    });
  }

  int _nextId = 0;
  final Map<String, Completer<Object?>> _pending = {};
  final ReceivePort _replyPort;

  /// Invoke one kernel action and wait for the result correlated by id.
  ///
  /// [timeout] bounds the wait even if the kernel never answers; on expiry the
  /// pending entry is removed so a late reply cannot complete a dead Future.
  Future<T> invoke<T>(
    ActionMethod method, {
    Object? data,
    Duration timeout = const Duration(seconds: 30),
  }) {
    final id = '${method.name}#${_nextId++}';
    final completer = Completer<Object?>();
    _pending[id] = completer;
    final payload = Action(id: id, method: method, data: data).encode().toNativeUtf8();
    try {
      ffi.throne_invoke_action(payload, _replyPort.sendPort.nativePort);
    } finally {
      malloc.free(payload);
    }
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw ActionException(method.name, 'timed out after ${timeout.inSeconds}s');
      },
    ).then((value) => value as T);
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
    _instance = ThroneKernel._(ThroneFFI(lib), ReceivePort(), ReceivePort());
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
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(const ActionException('dispose', 'kernel disposed'));
      }
    }
    _pending.clear();
    _port.close();
    _replyPort.close();
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
