import 'package:b_box_ui/box.dart';
import 'package:b_box_ui/core/kernel_service.dart';
import 'package:b_box_ui/core/throne_ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FFI kernel runtime contracts', () {
    test('the pushed status event decodes into a wire map', () {
      final event = decodeBridgeEvent('{"method":"status","data":{"memory":42}}');
      expect(event, isNotNull);
      expect(event!['method'], 'status');
      expect((event['data'] as Map)['memory'], 42);
    });

    test('malformed bridge events never reach the dispatcher', () {
      expect(decodeBridgeEvent(42), isNull);
      expect(decodeBridgeEvent('{oops'), isNull);
      expect(decodeBridgeEvent('[]'), isNull);
      expect(decodeBridgeEvent(null), isNull);
    });

    test('config.build sends no id; the dashboard id is display-only', () {
      expect(configBuildArgs(), isEmpty);
      expect(dashboardSelectedId(<String, dynamic>{'selectedProfileId': 7}), 7);
      expect(dashboardSelectedId(<String, dynamic>{}), -1);
    });

    test('without the rebuilt core the channel path stays in control', () async {
      const channel = MethodChannel('test.kernel-runtime');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return null;
      });

      final controller = BoxController(channel: channel);
      final service = KernelService(controller);
      expect(service.ffiMode, isFalse);
      expect(service.active, isFalse);

      await service.initialize();
      expect(service.ffiMode, isFalse,
          reason: 'ThroneKernel.isAvailable is false off-device');
      expect(calls.where((name) => name == 'ffi.mode').length, 2,
          reason: 'the flag is enabled then handed straight back to the channel');
      expect(service.active, isFalse);

      service.dispose();
    });
  });
}
