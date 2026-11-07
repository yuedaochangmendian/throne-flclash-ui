// The notification customisation rows on their own settings page: the switches and
// the two templates write through settings.set with no restart badge (the service
// applies them on its next update), and the button picker saves the host's fixed
// order no matter the order the checkboxes were touched in.

import 'dart:async';
import 'package:flrone/main.dart';
import 'package:flrone/pages/settings.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opens the Notification page against a fake host that records settings.set calls.
Future<(BoxController, List<Json>, StreamController<dynamic>)> _openGeneral(
  WidgetTester tester,
  String channelName,
  Map<String, dynamic> settings,
) async {
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
  addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
  final channel = MethodChannel(channelName);
  final events = StreamController<dynamic>.broadcast();
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
  openPage(tester.element(find.byType(HomePage)), const NotificationPage());
  await tester.pumpAndSettle();
  return (box, edits, events);
}

Future<void> _scrollTo(WidgetTester tester, String text) =>
    tester.scrollUntilVisible(find.text(text), 200, scrollable: find.byType(Scrollable).first);

void main() {
  testWidgets('the speed switches write through without a restart badge', (tester) async {
    final (box, edits, events) =
        await _openGeneral(tester, 'test.notification-toggles', {'showProxySpeed': true, 'showTrafficTotal': true});

    await _scrollTo(tester, 'Show proxy speed');
    await tester.tap(find.text('Show proxy speed'));
    await tester.pumpAndSettle();
    expect(edits.last, {'key': 'showProxySpeed', 'value': false});

    await _scrollTo(tester, 'Show traffic total');
    await tester.tap(find.text('Show traffic total'));
    await tester.pumpAndSettle();
    expect(edits.last, {'key': 'showTrafficTotal', 'value': false});
    // A notification text is applied by the host on its next update: no restart badge.
    expect(box.applyRequired, null);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('the title template saves the typed text without a restart badge', (tester) async {
    final (box, edits, events) =
        await _openGeneral(tester, 'test.notification-title-template', {'notificationTitleTemplate': ''});

    await _scrollTo(tester, 'Notification title template');
    // The hint stands in while nothing is configured.
    expect(find.text('Use {title} for the profile name, for example 🚀 {title}'), findsOneWidget);
    await tester.tap(find.text('Notification title template'));
    await tester.pumpAndSettle();
    await tester.enterText(find.descendant(of: find.byType(InputDialog),
        matching: find.byType(EditableText)).first, '🚀 {title}');
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();
    expect(edits.last, {'key': 'notificationTitleTemplate', 'value': '🚀 {title}'});
    expect(box.applyRequired, null);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('the content template saves placeholders and literal text', (tester) async {
    final (box, edits, events) =
        await _openGeneral(tester, 'test.notification-content-template', {'notificationContentTemplate': ''});

    await _scrollTo(tester, 'Notification content template');
    await tester.tap(find.text('Notification content template'));
    await tester.pumpAndSettle();
    await tester.enterText(find.descendant(of: find.byType(InputDialog),
        matching: find.byType(EditableText)).first, '{title} ↑{up} ↓{down}');
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();
    expect(edits.last, {'key': 'notificationContentTemplate', 'value': '{title} ↑{up} ↓{down}'});
    expect(box.applyRequired, null);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('the button picker shows the defaults and saves in the host order', (tester) async {
    // No notificationActions key: the row falls back to the built-in default set.
    final (box, edits, events) =
        await _openGeneral(tester, 'test.notification-actions', <String, dynamic>{});

    await _scrollTo(tester, 'Notification buttons');
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
    expect(box.applyRequired, null);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });
}
