import 'dart:async';
import 'package:flrone/box.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test.box');
  late StreamController<dynamic> events;
  late BoxController box;
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    events = StreamController<dynamic>.broadcast();
    box = BoxController(channel: channel, events: events.stream);
  });
  tearDown(() async { box.dispose(); await events.close(); messenger.setMockMethodCallHandler(channel, null); });

  test('native startup failure is recoverable', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      // KernelService probes the FFI bridge before 'ready'; keep the mocked
      // native startup failure confined to the startup call itself.
      if (call.method == 'ffi.mode') return null;
      throw PlatformException(code: 'startup', message: 'configuration error');
    });
    await box.initialize();
    expect(box.ready, false);
    expect(box.startupError, 'configuration error');
    messenger.setMockMethodCallHandler(channel, (_) async => {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Stopped'}});
    await box.initialize();
    expect(box.ready, true);
    expect(box.startupError, null);
  });

  test('service and capability state comes from the active core', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Stopped'}});
    await box.initialize();
    expect(box.running, false);
    events.add({'type': 'dashboard', 'value': {'remote': 'server', 'remoteConnected': true, 'status': 'Stopped', 'modes': ['rule']}});
    await Future<void>.delayed(Duration.zero);
    expect(box.running, true);
    expect(box.dashboard['modes'], ['rule']);
    events.add({'type': 'dashboard', 'value': {'status': 'Stopped', 'modes': []}});
    await Future<void>.delayed(Duration.zero);
    expect(box.running, false);
    expect(box.dashboard['modes'], isEmpty);
  });

  test('command errors are visible and never become successful actions', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => throw PlatformException(code: 'core', message: 'automatic group'));
    final error = box.messages.first;
    expect(await box.act('groups.select', {'group': 'auto', 'tag': 'node'}), false);
    expect(await error, 'automatic group');
  });

  test('service setting changes wait for the native restart and ignore repeated edits', () async {
    box.dashboard = {'status': 'Started'};
    box.settings = {'allowBypass': false};
    box.applyRequired = 'Restart';
    final reply = Completer<Json>();
    final edits = <Json>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'settings.set');
      edits.add(json(call.arguments));
      return reply.future;
    });
    final saving = box.setSetting('allowBypass', true, autoRestart: true);
    await Future<void>.delayed(Duration.zero);
    expect(box.serviceSettingsChanging, true);
    expect(box.settings['allowBypass'], false);
    expect(box.applyRequired, 'Restart');
    await box.setSetting('autoRedirect', true, autoRestart: true);
    expect(edits, [{'key': 'allowBypass', 'value': true, 'restart': true}]);
    reply.complete({'allowBypass': true});
    await saving;
    expect(box.serviceSettingsChanging, false);
    expect(box.settings['allowBypass'], true);
    expect(box.applyRequired, null);
  });

  for (final dashboard in <Json>[
    {'status': 'Stopped'},
    {'status': 'Started', 'remote': 'Server', 'remoteConnected': true},
    {'status': 'Stopped', 'remote': 'Server', 'remoteConnected': false},
  ]) {
    test('service settings only persist while stopped or remote: $dashboard', () async {
      box.dashboard = dashboard;
      final edits = <Json>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'settings.set');
        edits.add(json(call.arguments));
        return {'allowBypass': true};
      });
      await box.setSetting('allowBypass', true, autoRestart: true);
      expect(edits, [{'key': 'allowBypass', 'value': true}]);
      expect(box.settings['allowBypass'], true);
      expect(box.applyRequired, null);
    });
  }

  test('service settings cannot change during a local start or stop', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async { calls.add(call.method); return {}; });
    for (final status in ['Starting', 'Stopping']) {
      box.dashboard = {'status': status};
      await box.setSetting('allowBypass', true, autoRestart: true);
    }
    expect(calls, isEmpty);
    expect(box.serviceSettingsChanging, false);
  });

  test('failed automatic restart reports the error and keeps the recovered native settings', () async {
    final reply = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {'version': 'test', 'coreVersion': 'test',
        'dashboard': {'status': 'Started'}, 'settings': {'allowBypass': false}};
      }
      if (call.method == 'ffi.mode') return null;
      expect(call.method, 'settings.set');
      events.add({'type': 'settings', 'value': {'allowBypass': true}});
      await reply.future;
      events.add({'type': 'settings', 'value': {'allowBypass': false}});
      throw PlatformException(code: 'box_error', message: 'Startup failed');
    });
    await box.initialize();
    box.applyRequired = 'Restart';
    final error = box.messages.first;
    final saving = box.setSetting('allowBypass', true, autoRestart: true);
    await Future<void>.delayed(Duration.zero);
    expect(box.settings['allowBypass'], true);
    expect(box.serviceSettingsChanging, true);
    reply.complete();
    await saving;
    await Future<void>.delayed(Duration.zero);
    expect(await error, 'Startup failed');
    expect(box.settings['allowBypass'], false);
    expect(box.serviceSettingsChanging, false);
    expect(box.applyRequired, 'Restart');
  });

  test('core and access settings retain their existing apply behavior', () async {
    box.dashboard = {'status': 'Started'};
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(json(call.arguments).containsKey('restart'), false);
      return {'oomKillerEnabled': true};
    });
    await box.setSetting('oomKillerEnabled', true);
    expect(box.applyRequired, 'Restart');
    box.clearApplyRequired();
    await box.setSetting('disableDeprecatedWarnings', true, restart: false);
    expect(box.applyRequired, null);
    await box.setSettings({'perAppEnabled': true});
    expect(box.applyRequired, 'Restart');
  });

  test('imports received before the home route mounts stay queued', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'intent.take'
      ? 'sing-box://import-remote-profile?url=https%3A%2F%2Fexample.org%2Fconfig.json'
      : {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Stopped'}});
    await box.initialize();
    events.add({'type': 'intentAvailable', 'value': true});
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(box.pendingIntents.single, startsWith('sing-box://'));
  });

  group('event bus', () {
    void wire({Object? intake}) {
      messenger.setMockMethodCallHandler(channel, (call) async => switch (call.method) {
        'ready' => {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Stopped'}},
        'intent.take' => intake,
        _ => <String, dynamic>{},
      });
    }

    test('the derived slices are cached rather than rebuilt on every read', () {
      expect(identical(box.messages, box.messages), true);
      expect(identical(box.subscriptionReports, box.subscriptionReports), true);
      expect(identical(box.browserEvents, box.browserEvents), true);
      expect(identical(box.intents, box.intents), true);
    });

    test('each event reaches only its own slice', () async {
      wire(intake: 'sing-box://import-remote-profile?url=https%3A%2F%2Fexample.org');
      await box.initialize();
      final messages = <String>[];
      final reports = <Json>[];
      final browsers = <Json>[];
      final intents = <IntentAvailableEvent>[];
      box.messages.listen(messages.add);
      box.subscriptionReports.listen(reports.add);
      box.browserEvents.listen(browsers.add);
      box.intents.listen(intents.add);

      events.add({'type': 'subscriptionReport', 'value': {'kind': 'popup', 'groupName': 'Sub', 'text': 'Updated'}});
      events.add({'type': 'browserComplete', 'value': {'url': 'https://example.org/callback'}});
      events.add({'type': 'intentAvailable', 'value': true});
      events.add({'type': 'error', 'value': 'boom'});
      await pumpEventQueue();

      expect(reports, [{'kind': 'popup', 'groupName': 'Sub', 'text': 'Updated'}]);
      expect(browsers, [{'url': 'https://example.org/callback'}]);
      expect(intents, hasLength(1));
      expect(messages, ['boom']);
    });

    test('a subscription report without a popup becomes a banner, prefixed by its group', () async {
      wire();
      await box.initialize();
      final messages = <String>[];
      final reports = <Json>[];
      box.messages.listen(messages.add);
      box.subscriptionReports.listen(reports.add);

      events.add({'type': 'subscriptionReport', 'value': {'kind': 'status', 'groupName': 'Sub', 'text': 'Updated 3 nodes'}});
      events.add({'type': 'subscriptionReport', 'value': {'kind': 'error', 'text': 'Update failed'}});
      await pumpEventQueue();

      expect(messages, ['Sub: Updated 3 nodes', 'Update failed']);
      expect(reports, isEmpty);
    });

    test('a UI notice goes to the banner stream without touching the backend', () async {
      final banner = box.messages.first;
      box.showMessage('copied');
      expect(await banner, 'copied');
    });

    test('an intent the backend cannot supply is not announced', () async {
      wire();
      await box.initialize();
      final intents = <IntentAvailableEvent>[];
      box.intents.listen(intents.add);

      events.add({'type': 'intentAvailable', 'value': true});
      await pumpEventQueue();

      expect(intents, isEmpty);
      expect(box.pendingIntents, isEmpty);
    });

    test('closing the controller ends every slice', () async {
      final local = BoxController(channel: channel, events: events.stream);
      final ended = Future.wait([
        local.messages.toList(),
        local.subscriptionReports.toList(),
        local.browserEvents.toList(),
        local.intents.toList(),
      ]);
      local.dispose();

      expect(await ended, [[], [], [], []]);
    });
  });

  test('the service dashboard never overwrites the driver\'s numbers', () {
    final driver = <String, dynamic>{
      'status': 'Started', 'startedAt': 1000, 'uploadTotal': 4096, 'downloadTotal': 8192,
      'connections': 7, 'memory': 64, 'goroutines': 12, 'mode': 'rule', 'selectedProfileName': 'A',
    };
    final service = <String, dynamic>{
      'status': 'Stopped', 'startedAt': 0, 'uploadTotal': 0, 'downloadTotal': 0,
      'connections': 0, 'memory': 0, 'goroutines': 0, 'mode': 'global', 'selectedProfileName': 'B',
    };
    final merged = BoxController.mergeDashboard(driver, service, channelIsStale: true);
    expect(merged['status'], 'Started');
    expect(merged['uploadTotal'], 4096);
    expect(merged['connections'], 7);
    // The channel still owns what it persists: the mode and the selected profile.
    expect(merged['mode'], 'global');
    expect(merged['selectedProfileName'], 'B');
    // A fresh channel copy is used as-is, and nothing is copied.
    expect(BoxController.mergeDashboard(driver, service, channelIsStale: false), same(service));
  });

  test('the driver\'s own dashboard is never merged away', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Stopped'}});
    await box.initialize();
    box.debugDriverActive = true;

    box.handleEvent({'type': 'dashboard', 'value': {'status': 'Started', 'uploadTotal': 4096, 'mode': 'rule'}}, fromDriver: true);
    expect(box.dashboard['status'], 'Started');
    expect(box.dashboard['uploadTotal'], 4096);

    // A second later the service reports its own zeros. They must not land, or every figure
    // on the home cards stops moving — which is what merging both sources did.
    box.handleEvent({'type': 'dashboard', 'value': {'status': 'Stopped', 'uploadTotal': 0, 'mode': 'global'}});
    expect(box.dashboard['status'], 'Started');
    expect(box.dashboard['uploadTotal'], 4096);
    expect(box.dashboard['mode'], 'global');

    box.handleEvent({'type': 'rates', 'value': {'upload': 0, 'download': 0}});
    expect(box.rates, isEmpty);
    box.handleEvent({'type': 'rates', 'value': {'upload': 1024, 'download': 2048}}, fromDriver: true);
    expect(box.rates['upload'], 1024);
  });

  test('the core\'s heap comes from the driver, not the clash API', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Started'}});
    await box.initialize();
    box.debugDriverActive = true;

    // The driver reports its own heap in the status feed. The channel cannot ask it (it has no
    // instance handle) and the clash API is off, so the channel's memory event says zero.
    box.handleEvent({'type': 'dashboard', 'value': {'status': 'Started', 'memory': 41943040}}, fromDriver: true);
    box.handleEvent({'type': 'memory', 'value': {
      'rss': 297061581, 'app': 297061581, 'core': 0, 'running': true, 'remote': false,
      'heapInuse': 14365491, 'heapIdle': 8700000, 'total': 268435456,
    }});
    expect(box.memory['core'], 41943040);
    // Carved out of the process, not added to it.
    expect(box.memory['app'], 297061581 - 41943040);

    // Without the driver the channel's figure is all there is, and it is left alone.
    box.debugDriverActive = false;
    box.handleEvent({'type': 'memory', 'value': {
      'rss': 297061581, 'app': 297061581, 'core': 0, 'running': false, 'remote': false,
      'heapInuse': 14365491, 'heapIdle': 8700000, 'total': 268435456,
    }});
    expect(box.memory['core'], 0);
    expect(box.memory['app'], 297061581);
  });
}
