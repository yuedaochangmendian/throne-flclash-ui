import 'package:b_box_ui/core/kernel_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FFI core startup profile selection', () {
    test('config.build never sends a guessed profile id', () {
      final args = configBuildArgs();
      expect(args.containsKey('id'), isFalse,
          reason: 'the native bridge resolves DataStore.selectedProxy itself');
      expect(args.values, isNot(contains(0)));
    });

    test('a zero id reproduces the old "profile 0 is gone" failure', () async {
      const channel = MethodChannel('test.kernel-config');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      // Mirror the native handler contract: a non-positive id used to be looked
      // up as a ProxyEntity and threw "profile 0 is gone" on every start.
      messenger.setMockMethodCallHandler(channel, (call) async {
        final id = (call.arguments as Map?)?['id'] as num?;
        if (id != null && id <= 0) {
          throw PlatformException(code: 'failed', message: 'profile 0 is gone');
        }
        return <String, dynamic>{'coreConfig': '{}'};
      });

      final built =
          await channel.invokeMethod<dynamic>('config.build', configBuildArgs());
      expect((built as Map)['coreConfig'], '{}');
      await expectLater(
        channel.invokeMethod<dynamic>('config.build', <String, dynamic>{'id': 0}),
        throwsA(isA<PlatformException>().having(
            (error) => error.message, 'message', 'profile 0 is gone')),
      );
    });

    test('dashboard display id comes from the dashboard wire', () {
      // B-box profile cards carry group ids; UI appearance preferences never
      // hold the selected profile.
      expect(dashboardSelectedId(<String, dynamic>{'selectedProfileId': 7}), 7);
      expect(dashboardSelectedId(<String, dynamic>{}), -1);
    });
  });
}
