import 'dart:async';

import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/errors.dart';

/// A rule as BboxRoutes.ruleToMap emits it: metadata, the string fields, every list field and the booleans.
Map<String, Object?> rule({
  String name = '',
  String type = 'custom',
  String action = 'route',
  int outboundId = -1,
  List<String> domain = const [],
  List<String> domainSuffix = const [],
  List<String> ipCidr = const [],
  List<String> processName = const [],
  List<String> networkType = const [],
}) => {
  'name': name,
  'type': type,
  'disabled': false,
  'action': action,
  'outbound_id': outboundId,
  'ip_version': '',
  'network': '',
  'protocol': '',
  'reject_method': '',
  'override_address': '',
  'override_port': '',
  'tls_fragment_fallback_delay': '',
  'tls_spoof': '',
  'tls_spoof_method': '',
  'strategy': '',
  'inbound': <String>[],
  'domain': domain,
  'domain_suffix': domainSuffix,
  'domain_keyword': <String>[],
  'domain_regex': <String>[],
  'source_ip_cidr': <String>[],
  'ip_cidr': ipCidr,
  'source_port': <String>[],
  'source_port_range': <String>[],
  'port': <String>[],
  'port_range': <String>[],
  'process_name': processName,
  'process_path': <String>[],
  'process_path_regex': <String>[],
  'package_name': <String>[],
  'package_name_regex': <String>[],
  'network_type': networkType,
  'wifi_ssid': <String>[],
  'wifi_bssid': <String>[],
  'rule_set': <String>[],
  'sniffers': <String>[],
  'source_ip_is_private': false,
  'ip_is_private': false,
  'invert': false,
  'no_drop': false,
  'sniff_override_dest': false,
  'network_is_expensive': false,
  'tls_fragment': false,
  'tls_record_fragment': false,
};

void main() {
  late StreamController<dynamic> events;
  late List<Map<String, Object?>> rules;
  late List<String> dataPathCalls;
  late List<Map<String, Object?>> savedRules;

  Future<void> mount(WidgetTester tester) async {
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(360, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const channel = MethodChannel('test.routes-page');
    events = StreamController<dynamic>.broadcast();
    dataPathCalls = <String>[];
    savedRules = <Map<String, Object?>>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        // The host cannot answer the data plane's one channel call (older host,
        // no libsqlite3, schema mismatch): every screen must stay on routes.list.
        case 'data.path':
          dataPathCalls.add(call.method);
          return null;
        case 'ready':
          return {
            'version': 'test',
            'coreVersion': 'test',
            'preferences': {'locale': 'en'},
            'dashboard': {'status': 'Stopped'},
          };
        case 'routes.get':
          return {
            'id': 1,
            'name': 'Default',
            'defaultOutbound': 'direct',
            'isRemote': false,
            'remoteUrl': '',
            'autoUpdate': false,
            'isRaw': false,
            'endpointIds': <int>[],
            'rules': '',
            'ruleCount': rules.length,
          };
        case 'routes.list':
          return {
            'currentId': 1,
            'profiles': [
              {
                'id': 1,
                'name': 'Default',
                'current': true,
                'isRemote': false,
                'isRaw': false,
                'ruleCount': rules.length,
                'simpleRuleCount': 0,
              },
            ],
          };
        case 'routes.rules':
          return {'rules': rules};
        // The global pool renders on the Routing page itself now, so the page
        // asks the channel directly where the standalone page used to.
        case 'routes.globalRules':
          return {
            'rules': [
              {
                'id': 1,
                'name': 'Pool A',
                'type': 'route',
                'outbound_id': -1,
                'disabled': false,
              },
            ],
          };
        case 'routes.saveGlobalRules':
          return {'rules': <Object?>[]};
        case 'routes.deleteGlobalRule':
          return null;
        case 'routes.saveRules':
          savedRules = [
            for (final rule in (call.arguments as Map)['rules'] as List)
              Map<String, Object?>.from(rule as Map),
          ];
          rules = savedRules;
          return {'rules': savedRules};
      }
      return null;
    });
    final box = BoxController(channel: channel, events: events.stream);
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await events.close();
      messenger.setMockMethodCallHandler(channel, null);
    });
  }

  testWidgets(
    'the route profile editor and its rule editor render without exceptions',
    (tester) async {
      reportFlutterErrors();
      rules = [
        rule(name: 'Direct LAN', domainSuffix: ['.lan']),
        rule(
          name: 'Simple',
          type: 'simple_address_proxy',
          outboundId: -1,
          domain: ['example.org'],
        ),
        rule(
          name: 'Simple warp',
          type: 'simple_process_name_warp_bypass',
          outboundId: -5,
          processName: ['com.example'],
        ),
      ];
      await mount(tester);
      openPage(
        tester.element(find.byType(HomePage)),
        const AdditionalRulesPage(profileId: 1),
      );
      await tester.pumpAndSettle();
      expect(find.text('Direct LAN'), findsOneWidget);
      expect(find.text('Simple'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Editing an existing plain rule.
      await tester.tap(find.text('Direct LAN'));
      await tester.pumpAndSettle();
      expect(find.text('Edit rule'), findsWidgets);
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(find.text('Edit rule').first)).pop();
      await tester.pumpAndSettle();

      // Editing a simple rule (type token carries the action suffix).
      await tester.tap(find.text('Simple'));
      await tester.pumpAndSettle();
      expect(find.text('Edit rule'), findsWidgets);
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(find.text('Edit rule').first)).pop();
      await tester.pumpAndSettle();

      // Editing a simple rule whose action is warp_bypass.
      await tester.ensureVisible(find.text('Simple warp'));
      await tester.tap(find.text('Simple warp'));
      await tester.pumpAndSettle();
      expect(find.text('Edit rule'), findsWidgets);
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(find.text('Edit rule').first)).pop();
      await tester.pumpAndSettle();

      // Adding a new rule starts from an empty draft, from the bar's add button.
      await tester.tap(find.byTooltip('Add rule'));
      await tester.pumpAndSettle();
      expect(find.text('Add rule'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a rule enabled state is saved and shown immediately', (
    tester,
  ) async {
    reportFlutterErrors();
    rules = [
      rule(name: 'Direct LAN', domainSuffix: ['.lan'])..['disabled'] = true,
    ];
    await mount(tester);
    openPage(
      tester.element(find.byType(HomePage)),
      const AdditionalRulesPage(profileId: 1),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Disabled'),
      findsOneWidget,
      reason: 'the rule list must show the saved disabled state',
    );
    await tester.tap(find.text('Direct LAN'));
    await tester.pumpAndSettle();
    expect(find.text('Enabled'), findsWidgets);
    expect(find.text('Disabled'), findsWidgets);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(savedRules.single['disabled'], isFalse);
    expect(find.textContaining('Enabled'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the route list falls back to the channel when data.path is unavailable',
    (tester) async {
      reportFlutterErrors();
      rules = [];
      await mount(tester);
      openPage(
        tester.element(find.byType(HomePage)),
        const RouteProfilesPage(),
      );
      await tester.pumpAndSettle();

      // data.path was asked once, answered null, and the list still rendered from
      // routes.list — the screen must not see the difference.
      expect(dataPathCalls, isNotEmpty);
      expect(find.text('Default'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  // The scalar rule fields are fixed menus with the legal values Throne for
  // Android ships in arrays.xml, not free-text rows. These are pure helpers,
  // so the value contract is asserted without pumping a widget.
  group('rule enum options (Throne for Android parity)', () {
    test('ip_version stores 4/6, not the old ipv4/ipv6 hints', () {
      expect(ruleEnumValues['ip_version']!.map((o) => o.value), ['', '4', '6']);
      expect(ruleEnumValues['ip_version']!.map((o) => o.label), [
        'Any',
        'IPv4',
        'IPv6',
      ]);
      expect(ruleEnumValues['ip_version']!.length, 3);
    });

    test('network and protocol carry the full upstream value sets', () {
      expect(ruleEnumValues['network']!.map((o) => o.value), [
        '',
        'tcp',
        'udp',
        'icmp',
      ]);
      expect(ruleEnumValues['protocol']!.map((o) => o.value), [
        '',
        'http',
        'tls',
        'quic',
        'stun',
        'dns',
        'bittorrent',
        'dtls',
        'ssh',
        'rdp',
        'ntp',
      ]);
    });

    test('reject_method and strategy keep an empty first (unset) option', () {
      expect(ruleEnumValues['reject_method']!.first.value, '');
      expect(
        ruleEnumValues['reject_method']!.map((o) => o.value).skip(1).toList(),
        ['default', 'drop', 'reply'],
      );
      expect(ruleEnumValues['strategy']!.first.value, '');
      expect(ruleEnumValues['strategy']!.map((o) => o.value).skip(1).toList(), [
        'ipv4_only',
        'ipv6_only',
        'prefer_ipv4',
        'prefer_ipv6',
      ]);
    });

    test('action keeps bypass and adds hijack-dns', () {
      final values = ruleEnumValues['action']!.map((o) => o.value).toList();
      expect(
        values,
        containsAll(<String>[
          'route',
          'reject',
          'hijack-dns',
          'sniff',
          'resolve',
          'route-options',
          'bypass',
        ]),
      );
    });

    test('an unknown stored value is appended, not dropped (ensureValue)', () {
      final options = ruleEnumOptions('ip_version', 'ipv4');
      expect(options.map((o) => o.value), ['', '4', '6', 'ipv4']);
      expect(options.last.label, 'ipv4');
      expect(ruleEnumLabel('ip_version', 'ipv4'), 'ipv4');
      // A known value is never duplicated into the option list.
      expect(ruleEnumOptions('ip_version', '4').map((o) => o.value), [
        '',
        '4',
        '6',
      ]);
      // An unknown field has no presets, but ensureValue still keeps its
      // current value selectable instead of silently dropping it.
      final unknown = ruleEnumOptions('unknown_field', 'x');
      expect(unknown.map((o) => o.value), ['x']);
      expect(unknown.single.label, 'x');
      expect(ruleEnumOptions('unknown_field', ''), isEmpty);
    });

    test('empty values resolve to their unset label', () {
      expect(ruleEnumLabel('ip_version', ''), 'Any');
      expect(ruleEnumLabel('network', ''), 'Any');
      expect(ruleEnumLabel('protocol', ''), 'Any');
      expect(ruleEnumLabel('reject_method', ''), 'Unset');
      expect(ruleEnumLabel('strategy', ''), 'Default');
    });

    test(
      'selecting the unset option removes the key instead of storing ""',
      () {
        final original = <String, dynamic>{
          'name': 'r',
          'ip_version': '4',
          'action': 'route',
        };
        final cleared = ruleEnumApply(original, 'ip_version', '');
        expect(cleared.containsKey('ip_version'), isFalse);
        expect(cleared['name'], 'r');
        expect(cleared['action'], 'route');
        expect(original['ip_version'], '4', reason: 'input map is not mutated');
        final set = ruleEnumApply(original, 'ip_version', '6');
        expect(set['ip_version'], '6');
        // A previously-unset field can be added again.
        expect(ruleEnumApply(cleared, 'ip_version', '6')['ip_version'], '6');
      },
    );
  });

  testWidgets('a legacy ip_version still renders', (tester) async {
    reportFlutterErrors();
    rules = [
      {...rule(name: 'Legacy'), 'ip_version': 'ipv4'},
    ];
    await mount(tester);
    openPage(
      tester.element(find.byType(HomePage)),
      const AdditionalRulesPage(profileId: 1),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Legacy'));
    await tester.pumpAndSettle();
    expect(find.text('Edit rule'), findsWidgets);
    expect(
      tester.takeException(),
      isNull,
      reason: 'ensureValue must keep an out-of-preset value renderable',
    );
  });

  testWidgets('a custom rule folds the long tail behind Advanced', (
    tester,
  ) async {
    reportFlutterErrors();
    rules = [
      {...rule(name: 'Custom one')},
    ];
    await mount(tester);
    openPage(
      tester.element(find.byType(HomePage)),
      const AdditionalRulesPage(profileId: 1),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom one'));
    await tester.pumpAndSettle();

    // Throne's two basic categories are visible; the advanced tail is folded.
    expect(find.text('Match'), findsWidgets);
    expect(find.text('Domain keyword'), findsNothing);
    expect(find.text('Port'), findsNothing);

    await tester.ensureVisible(find.text('Advanced'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();

    expect(find.text('Domain keyword'), findsWidgets);
    expect(find.text('Port'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a list member is edited one value per line, as the native editor does',
    (tester) async {
      reportFlutterErrors();
      rules = [
        rule(name: 'Ads', domainSuffix: ['ads.example']),
      ];
      await mount(tester);
      openPage(
        tester.element(find.byType(HomePage)),
        const AdditionalRulesPage(profileId: 1),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ads'));
      await tester.pumpAndSettle();

      // The row shows what is set; the value is not a comma-joined single line any more.
      expect(find.text('ads.example'), findsOneWidget);
      // A field with nothing set says so, as the native rows do.
      expect(find.text('Not set'), findsWidgets);

      await tester.tap(find.text('Domain suffix'));
      await tester.pumpAndSettle();
      // The dialog carries the hint the native one shows above its field.
      expect(
        find.textContaining('google.com matches google.com and its subdomains'),
        findsOneWidget,
      );

      // The dialog's field is the last one built; the page behind keeps its own text fields.
      await tester.enterText(
        find.byType(TextField).last,
        'a.com\nb.com\n\n  c.com  ',
      );
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      // One value per line, blank lines dropped and each line trimmed.
      expect(find.text('a.com, b.com, c.com'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the route override screen keeps only the core fields', (tester) async {
    reportFlutterErrors();
    rules = [];
    await mount(tester);
    openPage(
      tester.element(find.byType(HomePage)),
      const RouteOverridePage(id: 1),
    );
    await tester.pumpAndSettle();

    // Core profile fields survive the simplification; the rules themselves live
    // on their own screen, reached through the "Additional rules" row.
    expect(find.text('Name'), findsOneWidget);
    expect(find.text('Default outbound'), findsOneWidget);
    expect(find.text('Remote'), findsWidgets);
    // "Additional rules" also appears on the route-profiles list behind this page.
    expect(find.text('Additional rules'), findsWidgets);
    expect(find.text('Global rules'), findsOneWidget);
    expect(find.text('Use this profile'), findsOneWidget);

    // The batch-add text box, default-rules reset and endpoint ids stay out of
    // the override screen; those live on the rules screen and the profile list.
    expect(find.text('Batch add simple rules'), findsNothing);
    expect(find.text('Restore default rules'), findsNothing);
    expect(find.text('Endpoint ids'), findsNothing);
    expect(find.text('Remote profile'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the routing page is the global pool, and the rest moved to the menu', (
    tester,
  ) async {
    reportFlutterErrors();
    rules = [];
    await mount(tester);
    openPage(tester.element(find.byType(HomePage)), const RoutingPage());
    await tester.pumpAndSettle();

    // The pool is the page: its rules render inline, and the add/import
    // actions sit in the app bar like every other page's primary actions.
    expect(find.text('Pool A'), findsOneWidget);
    expect(find.text('Global rules'), findsWidgets);
    expect(find.byTooltip('Add rule'), findsOneWidget);
    expect(find.byTooltip('Import rules from JSON'), findsOneWidget);

    // Nothing that used to be stacked below the pool is still on the page.
    expect(find.text('Route profiles'), findsNothing);
    expect(find.text('WARP'), findsNothing);
    expect(find.text('Outbound domain strategy'), findsNothing);
    expect(find.text('Rule set mirror'), findsNothing);
    expect(find.text('Ad blocking'), findsNothing);
    expect(find.text('Update rule sets'), findsNothing);

    // The old controls are one tap deep, in the ⋮ menu.
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Route profiles'), findsOneWidget);
    expect(find.text('WARP'), findsOneWidget);
    expect(find.text('Route settings'), findsOneWidget);
    expect(find.text('Automatic updates'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inbound, node presets and subscriptions live under Advanced settings', (
    tester,
  ) async {
    reportFlutterErrors();
    rules = [];
    await mount(tester);
    openPage(tester.element(find.byType(HomePage)), const AdvancedSettingsPage());
    await tester.pumpAndSettle();

    expect(find.text('Inbound'), findsOneWidget);
    expect(find.text('Node presets'), findsOneWidget);
    expect(find.text('Subscriptions'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
