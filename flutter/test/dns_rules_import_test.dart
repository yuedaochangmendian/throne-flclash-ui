// The DNS page's own import: it takes `dns.rules` alone, says where a route rule belongs, and
// appends what it took to the DNS object's rules.

import 'dart:async';
import 'dart:convert';

import 'package:flrone/components/code_editor.dart';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the DNS page imports dns.rules into the DNS object', (tester) async {
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    const channel = MethodChannel('test.dns-import');
    final events = StreamController<dynamic>.broadcast();
    final settings = <String, dynamic>{
      'useDnsObject': true,
      // A DNS object already carrying a server, so the append has to keep it.
      'dnsObject': '{"servers": [{"tag": "remote", "type": "https", "server": "1.1.1.1"}]}',
    };
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

    openPage(tester.element(find.byType(HomePage)), const DnsPage());
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Import DNS rules'));
    await tester.pumpAndSettle();
    expect(find.text('Import DNS rules'), findsOneWidget);

    await tester.tap(find.text('Import DNS rules'));
    await tester.pumpAndSettle();
    // The DNS sheet has no rule kind to choose: it only reads `dns.rules`.
    expect(find.text('Rule kind'), findsNothing);

    final editor = find.descendant(of: find.byType(CodeEditor), matching: find.byType(EditableText));
    await tester.enterText(editor, '{"rules": [{"domain_suffix": ["a.com"], "action": "reject"}]}');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('DNS rules to add'), findsOneWidget);
    expect(find.text('Route rules to add'), findsNothing);

    // The importer now opens as a form sheet: its confirmation moves to the
    // sheet's foot as a text button, so there is no Import tooltip to tap.
    await tester.tap(find.text('Import').last);
    await tester.pumpAndSettle();

    expect(edits, hasLength(1));
    expect(edits.single['key'], 'dnsObject');
    final saved = jsonDecode(edits.single['value'] as String) as Map<String, dynamic>;
    // The server the object already had survives; the rule is appended to its rules.
    expect(saved['servers'], hasLength(1));
    final rules = saved['rules'] as List;
    expect(rules, hasLength(1));
    expect((rules.single as Map)['domain_suffix'], ['a.com']);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('a route rule pasted on the DNS page is named, not silently dropped', (tester) async {
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    const channel = MethodChannel('test.dns-import-route');
    final events = StreamController<dynamic>.broadcast();
    final settings = <String, dynamic>{'useDnsObject': true, 'dnsObject': ''};
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

    openPage(tester.element(find.byType(HomePage)), const DnsPage());
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Import DNS rules'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import DNS rules'));
    await tester.pumpAndSettle();

    final editor = find.descendant(of: find.byType(CodeEditor), matching: find.byType(EditableText));
    await tester.enterText(editor, '{"route": {"rules": [{"domain_suffix": ["a.com"], "outbound": "proxy"}]}}');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // The rule is reported with where it belongs, and nothing is importable.
    expect(find.text('Route rules belong to a route profile'), findsOneWidget);
    expect(find.text('Open a route profile to import those.'), findsOneWidget);
    // The importer now opens as a form sheet: its confirmation moves to the
    // sheet's foot as a text button, so there is no Import tooltip to tap.
    await tester.tap(find.text('Import').last);
    await tester.pumpAndSettle();
    expect(edits, isEmpty);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await events.close();
  });
}
