// Regression guard for the settings row-store rollout (ADR 0002, amended).
//
// settings.* is channel-authoritative: Room is the only writer for
// ThroneSettings, and preferences live in SharedPreferences. A previous bus-first
// facade sent every write to a Go handler whose row store was never wired, so
// with the FFI driver attached the user's edits were silently swallowed by the
// BoxController's catch/report. This test makes that failure loud.

import 'dart:async';

import 'package:flrone/core/action.dart';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_route_kernel.dart';

void main() {
  testWidgets('settings writes reach the channel even with an attached kernel', (tester) async {
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);

    const channel = MethodChannel('test.settings-channel');
    final events = StreamController<dynamic>.broadcast();
    final settings = <String, dynamic>{'adblockEnable': false};
    final channelCalls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      channelCalls.add(call);
      switch (call.method) {
        case 'ready':
          return {
            'version': 'test',
            'coreVersion': 'test',
            'dashboard': {'status': 'Started'},
            'settings': settings,
          };
        case 'settings.set':
          final args = json(call.arguments);
          settings[args['key'] as String] = args['value'];
          return settings;
        case 'settings.patch':
          settings.addAll(json(call.arguments)['value'] as Map<String, dynamic>);
          return settings;
        case 'settings.reset':
          return settings;
        case 'preferences.set':
          return json(call.arguments)['value'];
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final box = BoxController(channel: channel, events: events.stream);
    // An attached kernel is the production case (libthrone.so ships in the APK).
    // Any settings action sent over the bus is a regression: fail immediately.
    final busCalls = <ActionMethod>[];
    box.kernel.debugAttach(
      FakeRouteKernel((method, data) {
        busCalls.add(method);
        throw StateError('settings must not use the action bus: ${method.name}');
      }),
      NoopKernelWorker(),
    );

    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();

    await box.setSetting('adblockEnable', true);
    await tester.pumpAndSettle();

    expect(
      channelCalls.where((c) => c.method == 'settings.set'),
      hasLength(1),
      reason: 'setSetting must reach the Room-backed channel arm',
    );
    expect(busCalls, isEmpty, reason: 'no settings action may go over the bus');
    expect(box.settings['adblockEnable'], true);
    expect(tester.takeException(), isNull);

    // The other four entry points must not drift back onto the bus either.
    await box.setSettings({'allowBypass': true});
    await box.resetSettings(['adblockEnable']);
    await box.setPreferences({'theme': 'dark'});
    await tester.pumpAndSettle();

    expect(channelCalls.where((c) => c.method == 'settings.patch'), hasLength(1));
    expect(channelCalls.where((c) => c.method == 'settings.reset'), hasLength(1));
    expect(channelCalls.where((c) => c.method == 'preferences.set'), hasLength(1));
    expect(busCalls, isEmpty);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await events.close();
  });
}
