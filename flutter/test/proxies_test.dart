import 'dart:async';
import 'package:flrone/main.dart';
import 'package:flrone/pages/proxies.dart';
import 'package:flrone/pages/test_panel.dart';
import 'package:flrone/widgets.dart';
import 'package:flrone/components/proxy_card.dart';
import 'package:flrone/components/proxy_list.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/errors.dart';

void main() {
  testWidgets('list groups fold per profile, build nodes lazily and locate the selected row', (tester) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.proxy-list');
    final preferences = <String, dynamic>{'locale': 'en', 'proxyLayout': 'List'};
    final calls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'ready') {
        return {'version': 'test', 'coreVersion': 'test', 'preferences': preferences,
        'dashboard': {'status': 'Started', 'selectedProfileId': 1}};
      }
      if (call.method == 'preferences.set') {
        preferences.addAll(json((call.arguments as Map)['value']));
        return preferences;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(BoxApp(controller: BoxController(channel: channel, events: events.stream)));
    await tester.pumpAndSettle();
    events.add({'type': 'groups', 'value': [{'tag': 'Large group', 'type': 'Selector', 'selectable': true, 'selected': 'Node 150',
      'items': [for (var index = 0; index < 200; index++) {'tag': 'Node $index', 'type': 'Direct'}]}]});
    await tester.pumpAndSettle();
    await tester.tap(find.text('Proxies').last);
    await tester.pumpAndSettle();
    expect(find.byType(ProxyListView), findsOneWidget);
    expect(find.byType(ProxyNodeCard), findsNothing);
    await tester.tap(find.byTooltip('Show more'));
    await tester.pumpAndSettle();
    expect(json(preferences['proxyUnfolded'])['local:1'], ['Large group']);
    expect(find.byType(ProxyNodeCard).evaluate().length, inInclusiveRange(1, 40));
    final selected = find.descendant(of: find.byType(ProxyNodeCard), matching: find.text('Node 150'));
    expect(selected, findsNothing);
    await tester.tap(find.byTooltip('Scroll to selected'));
    await tester.pumpAndSettle();
    expect(selected.hitTestable(), findsOneWidget);
    expect(find.byType(ProxyGroupHeader).hitTestable(), findsOneWidget);
    expect(find.text('Node 199'), findsNothing);
    await tester.tap(find.byTooltip('Test latency').first);
    await tester.pumpAndSettle();
    expect((calls.lastWhere((call) => call.method == 'groups.test').arguments as Map)['tag'], 'Large group');
    events.add({'type': 'dashboard', 'value': {'status': 'Started', 'selectedProfileId': 2}});
    await tester.pumpAndSettle();
    expect(find.byType(ProxyNodeCard), findsNothing);
    events.add({'type': 'dashboard', 'value': {'status': 'Started', 'selectedProfileId': 1}});
    await tester.pumpAndSettle();
    expect(find.byType(ProxyNodeCard).evaluate(), isNotEmpty);
    await tester.tap(find.byTooltip('Show less'));
    await tester.pumpAndSettle();
    expect(find.byType(ProxyNodeCard), findsNothing);
    expect(json(preferences['proxyUnfolded'])['local:1'], isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('automatic groups cannot send manual selection commands', (tester) async {
    final calls = <MethodCall>[];
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.automatic');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'ready' ? {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Started'}} : null;
    });
    final box = BoxController(channel: channel, events: events.stream);
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    events.add({'type': 'groups', 'value': [{'tag': 'Auto', 'selected': 'Node A', 'selectable': false, 'items': [
      {'tag': 'Node A', 'type': 'Shadowsocks', 'delay': 10}, {'tag': 'Node B', 'type': 'Shadowsocks', 'delay': 20},
    ]}]});
    await tester.pumpAndSettle();
    await tester.tap(find.text('Proxies').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Node B'));
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.method == 'groups.select'), isEmpty);
    expect(find.byType(ProxiesPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('the toolbar tests the displayed group and group swipes keep the primary page', (tester) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.group-toolbar');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'ready' ? {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Started'}} : null;
    });
    await tester.pumpWidget(BoxApp(controller: BoxController(channel: channel, events: events.stream)));
    await tester.pumpAndSettle();
    events.add({'type': 'groups', 'value': [for (final tag in ['Group A', 'Group B'])
      {'tag': tag, 'selected': 'Node $tag', 'selectable': true, 'items': [{'tag': 'Node $tag', 'type': 'direct'}]},
    ]});
    await tester.pumpAndSettle();
    await tester.tap(find.text('Proxies').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Group B'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Test latency').first);
    await tester.pumpAndSettle();
    expect((calls.lastWhere((call) => call.method == 'groups.test').arguments as Map)['tag'], 'Group B');
    await tester.drag(find.byType(TabBarView), const Offset(280, 0));
    await tester.pumpAndSettle();
    expect(find.byType(ProxiesPage).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('nodes select and test while the service is stopped', (tester) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.proxy-stopped');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'ready'
          ? {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Stopped'}, 'preferences': {'locale': 'en'}}
          : null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(BoxApp(controller: BoxController(channel: channel, events: events.stream)));
    await tester.pumpAndSettle();
    events.add({'type': 'groups', 'value': [
      {'id': 1, 'tag': 'Group A', 'selected': 'Node A', 'selectable': true, 'items': [
        {'id': 10, 'tag': 'Node A', 'type': 'Shadowsocks', 'delay': 12},
        {'id': 11, 'tag': 'Node B', 'type': 'Shadowsocks', 'delay': 34},
      ]},
    ]});
    await tester.pumpAndSettle();
    await tester.tap(find.text('Proxies').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Node B'));
    await tester.pumpAndSettle();
    expect((calls.lastWhere((call) => call.method == 'groups.select').arguments as Map)['tag'], 'Node B');
    await tester.tap(find.byTooltip('Test latency').first);
    await tester.pumpAndSettle();
    expect((calls.lastWhere((call) => call.method == 'groups.test').arguments as Map)['tag'], 'Group A');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('selected proxies are located outside the lazy grid and the active group survives group updates', (tester) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.proxy-locate');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async => call.method == 'ready' ? {
      'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Started'}, 'preferences': {'locale': 'en'},
    } : null);
    await tester.pumpWidget(BoxApp(controller: BoxController(channel: channel, events: events.stream)));
    await tester.pumpAndSettle();
    Json group(String tag, int count, int selected) => {'tag': tag, 'selected': '$tag node $selected', 'selectable': true,
      'items': [for (var index = 0; index < count; index++) {'tag': '$tag node $index', 'type': 'direct'}]};
    final groups = [group('Group A', 1, 0), group('Group B', 200, 150)];
    events.add({'type': 'groups', 'value': groups});
    await tester.pumpAndSettle();
    await tester.tap(find.text('Proxies').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Group B'));
    await tester.pumpAndSettle();
    expect(find.text('Group B node 150'), findsNothing);
    if (find.byTooltip('Scroll to selected').evaluate().isNotEmpty) {
      await tester.tap(find.byTooltip('Scroll to selected'));
    } else {
      await tester.tap(find.byTooltip('More').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Scroll to selected').last);
    }
    await tester.pumpAndSettle();
    expect(find.text('Group B node 150').hitTestable(), findsOneWidget);
    events.add({'type': 'groups', 'value': [group('New group', 1, 0), ...groups]});
    await tester.pumpAndSettle();
    final tabContext = tester.element(find.byType(TabBarView));
    expect(DefaultTabController.of(tabContext).index, 2);
    expect(find.text('Group B node 150').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('clicking a node delay shows the running spinner until the test completes', (tester) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.proxy-delay-animation');
    final testDone = Completer<dynamic>();
    var tested = false;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {'version': 'test', 'coreVersion': 'test',
          'dashboard': {'status': 'Started'}, 'preferences': {'locale': 'en'}};
      }
      if (call.method == 'groups.test') {
        tested = true;
        return testDone.future;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(BoxApp(controller: BoxController(channel: channel, events: events.stream)));
    await tester.pumpAndSettle();
    events.add({'type': 'groups', 'value': [{
      'tag': 'Group A', 'selected': 'Node A', 'selectable': true,
      'items': [
        {'id': 10, 'tag': 'Node A', 'type': 'direct', 'delay': 12, 'testedAt': 1},
        {'id': 11, 'tag': 'Node B', 'type': 'direct', 'delay': 30, 'testedAt': 1},
      ],
    }]});
    await tester.pumpAndSettle();
    await tester.tap(find.text('Proxies').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('12 ms'));
    await tester.pump();
    expect(tested, isTrue);
    expect(find.byKey(const ValueKey('proxy-test-running')), findsOneWidget);
    events.add({'type': 'testSession', 'value': {
      'kind': 0, 'running': true,
      'rows': [
        {'id': 10, 'phase': 'TESTING'}, {'id': 11, 'phase': 'QUEUED'},
      ],
    }});
    await tester.pump();
    expect(find.byKey(const ValueKey('proxy-test-running')), findsOneWidget);
    expect(find.byKey(const ValueKey('glyph:ProxyTestPhase.queued')), findsOneWidget);

    testDone.complete(null);
    events.add({'type': 'testSession', 'value': {
      'kind': 0, 'running': false,
      'rows': [
        {'id': 10, 'phase': 'DONE'}, {'id': 11, 'phase': 'DONE'},
      ],
    }});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('proxy-test-running')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('the node speed test panel hides IP check, test kind and scope', (tester) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.proxy-speed-only');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'ready' ? {
      'version': 'test', 'coreVersion': 'test',
      'dashboard': {'status': 'Started'}, 'preferences': {'locale': 'en'},
    } : null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(BoxApp(controller: BoxController(channel: channel, events: events.stream)));
    await tester.pumpAndSettle();
    openPage(tester.element(find.byType(HomePage)),
      const TestPanelPage(speedOnly: true, profileIds: [10], initialSpeedMode: 0));
    await tester.pumpAndSettle();

    expect(find.text('Speed test'), findsOneWidget);
    expect(find.text('Speed test mode'), findsOneWidget);
    expect(find.text('Test kind'), findsNothing);
    expect(find.text('IP check'), findsNothing);
    expect(find.text('Scope'), findsNothing);
    events.add({'type': 'testSession', 'value': {
      'kind': 2, 'running': false, 'speed': {
        'profileId': 10, 'name': 'Node A', 'stage': 'Complete',
        'dlBps': 8000000, 'ulBps': 3000000, 'pingMs': 42,
        'samples': [[0, 3000000, false], [1, 8000000, false], [2, 3000000, true]],
      },
    }});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Last speed test'), findsOneWidget);
    final chart = tester.widget<LineChart>(find.byKey(const ValueKey('speed-curve')));
    expect(chart.secondaryValues, isNotNull);
    expect(chart.secondaryValues!.any((value) => value > 0), isTrue);
    expect(chart.secondaryColor, isNot(chart.color));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });
}
