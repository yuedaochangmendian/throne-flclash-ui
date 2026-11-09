import 'dart:async';

import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'node presets follow Throne for Android rows and dependent options',
    (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
      addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);

      const channel = MethodChannel('test.node-presets');
      final events = StreamController<dynamic>.broadcast();
      final settings = <String, dynamic>{
        'muxProtocol': 'h2mux',
        'muxMode': 'max_streams',
        'muxConcurrency': 8,
        'muxBrutal': false,
        'muxBrutalUpMbps': 0,
        'muxBrutalDownMbps': 0,
        'fragmentImplementation': 'built-in',
        'utlsFingerprint': '',
      };
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'ready') {
          return {
            'version': 'test',
            'coreVersion': 'test',
            'dashboard': {'status': 'Stopped'},
            'settings': settings,
          };
        }
        if (call.method == 'settings.set') {
          final args = json(call.arguments);
          settings[args['key'] as String] = args['value'];
          return settings;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      await tester.pumpWidget(
        BoxApp(
          controller: BoxController(channel: channel, events: events.stream),
        ),
      );
      await tester.pumpAndSettle();
      openPage(tester.element(find.byType(HomePage)), const PresetsPage());
      await tester.pumpAndSettle();

      // The active Mux mode owns the pool row, while both Brutal speed fields stay
      // visible so they can be set before the switch is enabled.
      expect(find.text('Mux concurrency'), findsOneWidget);
      expect(find.text('Mux max connections'), findsNothing);
      expect(find.text('Brutal upload'), findsOneWidget);
      expect(find.text('Brutal download'), findsOneWidget);
      expect(find.text('TLS spoof'), findsNothing);

      await tester.scrollUntilVisible(
        find.text('uTLS fingerprint'),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('uTLS'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('HTTP/2 and QUIC'),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('HTTP/2 and QUIC'), findsOneWidget);
      expect(find.text('QUIC'), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      await events.close();
    },
  );
}
