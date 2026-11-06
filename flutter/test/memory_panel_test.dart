import 'dart:async';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flrone/components/memory_panel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The numbers from the report: a 283.3 MB process whose ART heap is 13.7 MB.
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

  Future<void> push(WidgetTester tester, StreamController<dynamic> events, {required int core}) async {
    events.add({'type': 'memory', 'value': {
      'total': 256 * 1024 * 1024, 'rss': _rss, 'app': _heap, 'core': core,
      'running': true, 'remote': false, 'heapInuse': _heap, 'heapIdle': 8700000,
    }});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('the headline is the process, and every part adds up to it', (tester) async {
    final events = await mount(tester);
    await push(tester, events, core: 0);
    expect(find.byType(MemorySummary), findsOneWidget);
    // 283.3 MB: the process, as the RSS row on the details page says.
    expect(find.text('283.3 MB'), findsOneWidget);
    expect(find.text('13.7 MB'), findsOneWidget);
    // What is left once the app's heap is accounted for.
    expect(find.text('269.6 MB'), findsOneWidget);
  });

  testWidgets('a core that reports nothing is unknown, not zero', (tester) async {
    final events = await mount(tester);
    await push(tester, events, core: 0);
    final summary = find.byType(MemorySummary);
    expect(find.descendant(of: summary, matching: find.text('—')), findsOneWidget);
    expect(find.descendant(of: summary, matching: find.text('0 B')), findsNothing);
  });

  testWidgets('a reported core is carved out of the process, and the rest is named', (tester) async {
    final events = await mount(tester);
    const core = 41943040; // 40 MB
    await push(tester, events, core: core);
    expect(find.text('283.3 MB'), findsOneWidget);
    expect(find.text('13.7 MB'), findsOneWidget);
    expect(find.text('40.0 MB'), findsOneWidget);
    // 283.3 - 13.7 - 40 = 229.6 MB of native allocations, graphics and shared pages.
    expect(find.text('229.6 MB'), findsOneWidget);
  });

  testWidgets('a core that reports more than the process cannot exceed it', (tester) async {
    final events = await mount(tester);
    // The Go runtime reports mapped heap, which can be larger than what is resident: this is the
    // 319.2 MB reading on a 286 MB process from the report.
    await push(tester, events, core: 334700000);
    expect(find.text('283.3 MB'), findsOneWidget);
    // Capped at the process minus the app's heap, so nothing claims more than the whole.
    expect(find.text('269.6 MB'), findsOneWidget);
    expect(find.text('319.2 MB'), findsNothing);
  });
}
