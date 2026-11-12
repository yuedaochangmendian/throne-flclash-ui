import 'dart:async';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test.state_updates');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late StreamController<dynamic> events;
  late BoxController box;

  setUp(() {
    events = StreamController<dynamic>.broadcast();
    box = BoxController(channel: channel, events: events.stream);
    messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'ready'
      ? {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Stopped'}} : null);
  });

  tearDown(() async {
    await events.close();
    messenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets('telemetry updates only its subscribers and preserves state notifications', (tester) async {
    await box.initialize();
    final builds = {for (final aspect in BoxAspect.values) aspect: 0};
    var routeUpdates = 0;
    box.stateChanges.addListener(() => routeUpdates++);
    await tester.pumpWidget(BoxScope(controller: box, child: Directionality(
      textDirection: TextDirection.ltr,
      child: Column(children: [for (final aspect in BoxAspect.values) Builder(builder: (context) {
        final state = aspect == BoxAspect.state ? context.box : BoxScope.of(context, aspect: aspect);
        builds[aspect] = builds[aspect]! + 1;
        return Text('${aspect.name}:${state.ready}');
      })]),
    )));
    // List events coalesce their notifications over a short window, so the clock has to
    // pass it before each one is delivered; the others arrive as they land.
    Future<void> settle() async {
      await tester.pumpAndSettle();
      await tester.pump(BoxController.batchWindow + const Duration(milliseconds: 50));
    }
    for (final (type, value, aspect) in <(String, Object, BoxAspect)>[
      ('rates', {'upload': 42, 'download': 84}, BoxAspect.traffic),
      ('dashboard', {'status': 'Stopped', 'uploadTotal': '1 MB', 'connections': 20}, BoxAspect.traffic),
      ('memory', {'total': 100}, BoxAspect.memory),
      ('logs', {'entries': [], 'defaultLogLevel': 'Warn'}, BoxAspect.logs),
      ('connections', [], BoxAspect.connections),
    ]) {
      final before = Map.of(builds);
      events.add({'type': type, 'value': value});
      // The broadcast arrives asynchronously and then schedules the model's frame.
      await settle();
      for (final candidate in BoxAspect.values) {
        expect(builds[candidate], before[candidate]! + (candidate == aspect ? 1 : 0), reason: '$type -> $candidate');
      }
      expect(routeUpdates, 0);
    }
    events.add({'type': 'dashboard', 'value': {'status': 'Started', 'mode': 'rule'}});
    await tester.pumpAndSettle();
    expect(routeUpdates, 1);
    expect(builds[BoxAspect.state], 2);
    final before = Map.of(builds);
    box.notifyListeners();
    await tester.pump();
    for (final aspect in BoxAspect.values) { expect(builds[aspect], before[aspect]! + 1); }
    await tester.pumpWidget(const SizedBox());
    box.dispose();
  });

  testWidgets('the application root survives telemetry and responds to appearance changes', (tester) async {
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    final app = tester.widget<PrismApp>(find.byType(PrismApp));
    for (final (type, value) in <(String, Object)>[
      ('rates', {'upload': 1024, 'download': 2048}),
      ('memory', {'total': 100}),
      ('logs', {'entries': [], 'defaultLogLevel': 'Info'}),
      ('connections', []),
      ('dashboard', {...box.dashboard, 'uploadTotal': '2 MB', 'memory': '20 MB'}),
      ('settings', {'allowBypass': true}),
    ]) {
      events.add({'type': type, 'value': value});
      await tester.pumpAndSettle();
      // Let the coalesced list events deliver too, so the check is not trivially true.
      await tester.pump(BoxController.batchWindow + const Duration(milliseconds: 50));
      expect(identical(app, tester.widget<PrismApp>(find.byType(PrismApp))), isTrue, reason: type);
    }
    events.add({'type': 'preferences', 'value': {'theme': 'dark'}});
    await tester.pumpAndSettle();
    expect(tester.widget<PrismApp>(find.byType(PrismApp)).themeMode, ThemeMode.dark);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('log deltas retain existing records, evict old entries and keep pause snapshots intact', () async {
    await box.initialize();
    Json record(int id) => {'id': id, 'level': 'Debug', 'message': 'record $id'};
    Future<void> emit(Json value) async {
      events.add({'type': 'logs', 'value': value});
      await Future<void>.delayed(Duration.zero);
    }
    await emit({'reset': true, 'firstId': 1, 'defaultLogLevel': 'Info', 'entries': [record(1), record(2)]});
    final paused = List<Json>.of(box.logs);
    await emit({'reset': false, 'firstId': 2, 'defaultLogLevel': 'Warn', 'entries': [record(3)]});
    expect(box.logs.map((entry) => entry['id']), [2, 3]);
    expect(identical(box.logs.first, paused.last), isTrue);
    expect(paused.map((entry) => entry['id']), [1, 2]);
    expect(box.defaultLogLevel, 'Warn');
    await emit({'reset': false, 'firstId': 2, 'defaultLogLevel': 'Error', 'entries': []});
    expect(box.logs.map((entry) => entry['id']), [2, 3]);
    await emit({'reset': true, 'firstId': null, 'defaultLogLevel': null, 'entries': []});
    expect(box.logs, isEmpty);
    await emit({'reset': true, 'firstId': 1, 'defaultLogLevel': 'Trace', 'entries': [record(1)]});
    expect(box.logs.single['id'], 1);
    expect(box.defaultLogLevel, 'Trace');
    box.dispose();
  });

  test('the traffic window takes one sample a second and empties when the session ends', () async {
    await box.initialize();
    Future<void> emit(String type, Object value) async {
      events.add({'type': type, 'value': value});
      await Future<void>.delayed(Duration.zero);
    }
    await emit('dashboard', {'status': 'Started'});
    await emit('rates', {'upload': 100, 'download': 200});
    expect(box.uploadHistory, [100.0]);
    expect(box.downloadHistory, [200.0]);
    expect(box.sampleRevision, 1);
    // The channel's tick and the FFI status feed can both report the same second; that is one
    // sample, not two, or the half-minute window would only span fifteen seconds.
    await emit('rates', {'upload': 110, 'download': 210});
    expect(box.uploadHistory, [100.0]);
    expect(box.sampleRevision, 1);
    // The live figure still follows every push, even when the window does not grow.
    expect(box.rates['upload'], 110);
    await Future<void>.delayed(BoxController.trafficSampleGap);
    await emit('rates', {'upload': 120, 'download': 220});
    expect(box.uploadHistory, [100.0, 120.0]);
    expect(box.downloadHistory, [200.0, 220.0]);
    // Bettbox clears the window and the totals with the session, so the next start draws its own curve.
    await emit('dashboard', {...box.dashboard, 'status': 'Stopped', 'uploadTotal': 0, 'downloadTotal': 0});
    expect(box.uploadHistory, isEmpty);
    expect(box.downloadHistory, isEmpty);
    expect(box.rates, isEmpty);
    box.dispose();
  });
}
