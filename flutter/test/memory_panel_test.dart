import 'dart:async';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flrone/components/memory_panel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The numbers the bridge sends for a 283.3 MB process whose core reports nothing: the ART heap is
/// 13.7 MB of it, which is what the panel used to print as the total.
const _rss = 297061581;
const _heap = 14365491;

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

  testWidgets('the headline is the process, not the heap inside it', (tester) async {
    final events = await mount(tester);
    events.add({'type': 'memory', 'value': {
      'total': 256 * 1024 * 1024, 'rss': _rss, 'app': _rss, 'core': 0,
      'running': true, 'remote': false, 'heapInuse': _heap, 'heapIdle': 8700000,
    }});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(MemorySummary), findsOneWidget);
    // 283.3 MB, and not the 13.7 MB heap the panel used to add up to.
    expect(find.text('283.3 MB'), findsWidgets);
    expect(find.text('13.7 MB'), findsNothing);
  });

  testWidgets('a core that reports nothing is unknown, not zero', (tester) async {
    final events = await mount(tester);
    events.add({'type': 'memory', 'value': {
      'total': 256 * 1024 * 1024, 'rss': _rss, 'app': _rss, 'core': 0,
      'running': true, 'remote': false, 'heapInuse': _heap, 'heapIdle': 8700000,
    }});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    // The core's share sits inside the process figure, so the legend says so instead of "0 B".
    final summary = find.byType(MemorySummary);
    expect(find.descendant(of: summary, matching: find.text('—')), findsOneWidget);
    expect(find.descendant(of: summary, matching: find.text('0 B')), findsNothing);
  });

  testWidgets('a reported core is carved out of the process, not added to it', (tester) async {
    final events = await mount(tester);
    const core = 41943040; // 40 MB
    events.add({'type': 'memory', 'value': {
      'total': 256 * 1024 * 1024, 'rss': _rss, 'app': _rss - core, 'core': core,
      'running': true, 'remote': false, 'heapInuse': _heap, 'heapIdle': 8700000,
    }});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('283.3 MB'), findsWidgets);
    expect(find.text('40.0 MB'), findsOneWidget);
    // 283.3 - 40 = 243.3 MB of the process is not the core.
    expect(find.text('243.3 MB'), findsOneWidget);
  });
}
