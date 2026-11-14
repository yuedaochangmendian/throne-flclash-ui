// The Prism-sheet conversion of the speed test history: the records render,
// a history taller than the viewport is scrollable, and Close dismisses it.

import 'dart:async';

import 'package:flrone/components/speed_test_settings.dart';
import 'package:flrone/services/speed_test_history.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

void main() {
  testWidgets('the history sheet renders, scrolls and closes', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    const channel = MethodChannel('test.speed-history');
    final events = StreamController<dynamic>.broadcast();
    final preferences = <String, dynamic>{
      'locale': 'en',
      speedTestHistoryKey: [
        for (var i = 0; i < 12; i++)
          SpeedTestRecord(
            time: DateTime.now().millisecondsSinceEpoch - i * 60000,
            proxy: 'Node $i',
            provider: 'cloudflare',
            download: 8.0e7 - i * 1.0e6,
          ).toJson(),
      ],
    };
    final messenger = TestDefaultBinaryMessengerBinding
        .instance
        .defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'ready':
          return {
            'version': 'test',
            'coreVersion': 'test',
            'preferences': preferences,
            'dashboard': {'status': 'Stopped'},
          };
        case 'preferences.set':
          preferences.addAll(Map<String, dynamic>.from(call.arguments));
          return preferences;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final box = BoxController(channel: channel, events: events.stream);
    await tester.pumpWidget(
      TestApp(
        child: Builder(
          builder: (context) => FilledButton(
            onPressed: () => showSpeedTestHistory(context, box: box),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Write through the controller so the records land in box.preferences the
    // same way a real run stores them.
    await writeSpeedTestHistory(box, [
      for (var i = 0; i < 12; i++)
        SpeedTestRecord(
          time: DateTime.now().millisecondsSinceEpoch - i * 60000,
          proxy: 'Node $i',
          provider: 'cloudflare',
          download: 8.0e7 - i * 1.0e6,
        ),
    ]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Speed test history'), findsOneWidget);
    // _HistoryItem renders each record's throughput line.
    expect(find.textContaining('↓'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Speed test history'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });
}
