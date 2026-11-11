// Test doubles for the FFI action bus (ADR 0002 phase 3c).
//
// The route surface goes through the JSON action bus, so a screen that reads routes needs an
// attached kernel. These fakes stand in for the Go dispatcher and the isolate worker: a test
// attaches them through `kernel.debugAttach`, which is the same seam the hand-over tests use,
// so the screens run their real code path.

import 'package:flrone/core/action.dart';
import 'package:flrone/core/kernel_worker.dart';
import 'package:flrone/core/throne_ffi.dart';
import 'package:flrone/core/throne_kernel.dart';

/// A kernel whose `invoke` is the test's own function.
class FakeRouteKernel implements ThroneKernel {
  FakeRouteKernel(this.handler);

  /// Answers one action. Returning null is a successful "no payload".
  final Object? Function(ActionMethod method, Object? data) handler;

  @override
  Future<T> invoke<T>(
    ActionMethod method, {
    Object? data,
    Duration timeout = const Duration(seconds: 30),
  }) async => handler(method, data) as T;

  @override
  Map<String, dynamic> get lastSpeedTestState => const {};

  @override
  Stream<Map<String, dynamic>> get speedTestStates => const Stream.empty();

  @override
  Stream<BridgeEvent> get events => const Stream.empty();

  @override
  Stream<BridgeEvent> get logs => const Stream.empty();

  @override
  ThroneFFI get ffi => throw UnimplementedError('routes never touch ffi');

  @override
  ReplyPort openReply() =>
      throw UnimplementedError('routes never open a reply port');

  @override
  void dispose() {}
}

/// A worker that only answers the event stream the driver subscribes to.
///
/// The route screens never drive the core lifecycle, so every other member throws: reaching
/// one would mean the test took a path it should not have.
class NoopKernelWorker implements KernelWorker {
  @override
  Stream<WorkerEvent> get events => const Stream.empty();

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('the route tests do not drive the worker');
}
