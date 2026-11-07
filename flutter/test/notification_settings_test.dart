// The notification customisation rows on the General page: the prefix writes a plain
// string through settings.set with no restart badge, and the button picker saves the
// host's fixed order no matter the order the checkboxes were touched in.

import 'dart:async';
import 'package:flrone/main.dart';
import 'package:flrone/pages/settings.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the notification rows render and the traffic-total switch writes through', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    const channel = MethodChannel('test.notification-settings');
    final events = StreamController<dynamic>.broadcast();
    final settings = <String, dynamic>{'showTrafficTotal': true};
    final edits = <Json>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {'version': 'test', 'coreVersion': 'test',
        'dashboard': {'status': 'Stopped'}, 'settings': settings};
      }
      if (call.method == 'settings.set') {
        final args = json(call.arguments);
        edits.add(args);
        settings[args['key'] as String] = args['value'];
        return settings;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final box = BoxController(channel: channel, events: events.stream);
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    openPage(tester.element(find.byType(HomePage)), const GeneralPage());
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('Show traffic total'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Show traffic total'));
    await tester.pumpAndSettle();
    expect(edits.last, {'key': 'showTrafficTotal', 'value': false});
    // A notification text is applied by the host on its next update: no restart badge.
    expect(box.applyRequired, null);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('the title prefix saves the typed text without a restart badge', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    const channel = MethodChannel('test.notification-prefix');
    final events = StreamController<dynamic>.broadcast();
    final settings = <String, dynamic>{'notificationTitlePrefix': ''};
    final edits = <Json>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {'version': 'test', 'coreVersion': 'test',
        'dashboard': {'status': 'Started'}, 'settings': settings};
      }
      if (call.method == 'settings.set') {
        final args = json(call.arguments);
        edits.add(args);
        settings[args['key'] as String] = args['value'];
        return settings;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final box = BoxController(channel: channel, events: events.stream);
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    openPage(tester.element(find.byType(HomePage)), const GeneralPage());
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('Notification title prefix'), 200, scrollable: find.byType(Scrollable).first);
    // The hint stands in while nothing is configured.
    expect(find.text('Shown in front of the title, for example 🚀'), findsOneWidget);
    await tester.tap(find.text('Notification title prefix'));
    await tester.pumpAndSettle();
    await tester.enterText(find.descendant(of: find.byType(InputDialog),
        matching: find.byType(EditableText)).first, '🚀');
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();
    expect(edits.last, {'key': 'notificationTitlePrefix', 'value': '🚀'});
    // Running service, but the notification text needs no restart: no badge.
    expect(box.applyRequired, null);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('the button picker shows the defaults and saves in the host order', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    const channel = MethodChannel('test.notification-actions');
    final events = StreamController<dynamic>.broadcast();
    // No notificationActions key: the row falls back to the built-in default set.
    final settings = <String, dynamic>{};
    final edits = <Json>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {'version': 'test', 'coreVersion': 'test',
        'dashboard': {'status': 'Stopped'}, 'settings': settings};
      }
      if (call.method == 'settings.set') {
        final args = json(call.arguments);
        edits.add(args);
        settings[args['key'] as String] = args['value'];
        return settings;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final box = BoxController(channel: channel, events: events.stream);
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    openPage(tester.element(find.byType(HomePage)), const GeneralPage());
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('Notification buttons'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Stop, Next, Switch…'), findsOneWidget);

    await tester.tap(find.text('Notification buttons'));
    await tester.pumpAndSettle();
    // Stop is checked (part of the defaults); untick it and add Reset.
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Stop'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Reset connections'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    // The save keeps the host's fixed order (stop, previous, next, switch, reset), not the
    // order the checkboxes were touched in, and drops the unticked Stop.
    expect(edits.last, {'key': 'notificationActions', 'value': ['next', 'switch', 'reset']});
    expect(find.text('Next, Switch…, Reset connections'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });
}
