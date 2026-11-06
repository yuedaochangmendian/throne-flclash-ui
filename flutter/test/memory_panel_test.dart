import 'dart:async';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flrone/components/memory_panel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The numbers `Debug.MemoryInfo` reports for a 283.3 MB process: 13.7 MB of ART heap, 100 MB of
/// native allocations (the Go runtime lives there) and the rest. The four add up, because the
/// platform produced all of them.
const _rss = 297061581;
const _app = 14365491;
const _core = 104857600;
const _other = _rss - _app - _core;

void main() {
  Future<StreamController<dynamic>> mount(WidgetTester tester) async {
    const channel = MethodChannel('test.memory');
    final events = StreamController<dynamic>.broadcast();
    addTearDown(events.close);
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {
          'version': 'test',
          'coreVersion': 'test',
          'preferences': {'locale': 'en', 'hiddenCards': <String>[]},
          'dashboard': {'status': 'Started'},
        };
      }
      return null;
    });
    await tester.pumpWidget(BoxApp(controller: BoxController(channel: channel, events: events.stream)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    return events;
  }

  Future<void> push(WidgetTester tester, StreamController<dynamic> events, {int other = _other}) async {
    events.add({'type': 'memory', 'value': {
      'total': 256 * 1024 * 1024, 'rss': _rss, 'app': _app, 'core': _core, 'other': other,
      'running': true, 'remote': false, 'heapInuse': _app, 'heapIdle': 8700000,
    }});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('the headline is the process, and the parts add up to it', (tester) async {
    final events = await mount(tester);
    await push(tester, events);
    expect(find.byType(MemorySummary), findsOneWidget);
    expect(find.text('283.3 MB'), findsOneWidget);
    expect(find.text('13.7 MB'), findsOneWidget);
    expect(find.text('100.0 MB'), findsOneWidget);
    expect(find.text('169.6 MB'), findsOneWidget);
  });

  testWidgets('a split with no remainder shows two parts', (tester) async {
    final events = await mount(tester);
    // Nothing outside the two allocators: no "Other" segment to draw, and no zero to print.
    await push(tester, events, other: 0);
    expect(find.text('283.3 MB'), findsOneWidget);
    expect(find.text('13.7 MB'), findsOneWidget);
    expect(find.text('100.0 MB'), findsOneWidget);
    expect(find.text('0 B'), findsNothing);
  });
}
