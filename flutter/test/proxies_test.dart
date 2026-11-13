import 'dart:async';

import 'package:flrone/main.dart';
import 'package:flrone/pages/proxies.dart';
import 'package:flrone/pages/test_panel.dart';
import 'package:flrone/widgets.dart';
import 'package:flrone/components/proxy_card.dart';
import 'package:flrone/components/proxy_list.dart';
import 'package:flrone/components/speed_gauge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/errors.dart';

void main() {
  testWidgets(
    'list groups fold per profile, build nodes lazily and locate the selected row',
    (tester) async {
      reportFlutterErrors();
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final events = StreamController<dynamic>.broadcast();
      const channel = MethodChannel('test.proxy-list');
      final preferences = <String, dynamic>{
        'locale': 'en',
        'proxyLayout': 'List',
      };
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'ready') {
          return {
            'version': 'test',
            'coreVersion': 'test',
            'preferences': preferences,
            'dashboard': {'status': 'Started', 'selectedProfileId': 1},
          };
        }
        if (call.method == 'preferences.set') {
          preferences.addAll(json((call.arguments as Map)['value']));
          return preferences;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(
        BoxApp(
          controller: BoxController(channel: channel, events: events.stream),
        ),
      );
      await tester.pumpAndSettle();
      events.add({
        'type': 'groups',
        'value': [
          {
            'tag': 'Large group',
            'type': 'Selector',
            'selectable': true,
            'selected': 'Node 150',
            'items': [
              for (var index = 0; index < 200; index++)
                {'id': index + 1, 'tag': 'Node $index', 'type': 'Direct'},
            ],
          },
        ],
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('Proxies').last);
      await tester.pumpAndSettle();
      expect(find.byType(ProxyListView), findsOneWidget);
      expect(find.byType(ProxyNodeCard), findsNothing);
      await tester.tap(find.byTooltip('Show more'));
      await tester.pumpAndSettle();
      expect(json(preferences['proxyUnfolded'])['local:1'], ['Large group']);
      expect(
        find.byType(ProxyNodeCard).evaluate().length,
        inInclusiveRange(1, 40),
      );
      final selected = find.descendant(
        of: find.byType(ProxyNodeCard),
        matching: find.text('Node 150'),
      );
      expect(selected, findsNothing);
      await tester.tap(find.byTooltip('Scroll to selected'));
      await tester.pumpAndSettle();
      expect(selected.hitTestable(), findsOneWidget);
      expect(find.byType(ProxyGroupHeader).hitTestable(), findsOneWidget);
      expect(find.text('Node 199'), findsNothing);
      await tester.tap(find.byTooltip('Test latency').first);
      await tester.pumpAndSettle();
      expect(
        (calls.lastWhere((call) => call.method == 'groups.test').arguments
            as Map)['tag'],
        'Large group',
      );
      events.add({
        'type': 'dashboard',
        'value': {'status': 'Started', 'selectedProfileId': 2},
      });
      await tester.pumpAndSettle();
      expect(find.byType(ProxyNodeCard), findsNothing);
      events.add({
        'type': 'dashboard',
        'value': {'status': 'Started', 'selectedProfileId': 1},
      });
      await tester.pumpAndSettle();
      expect(find.byType(ProxyNodeCard).evaluate(), isNotEmpty);
      await tester.tap(find.byTooltip('Show less'));
      await tester.pumpAndSettle();
      expect(find.byType(ProxyNodeCard), findsNothing);
      expect(json(preferences['proxyUnfolded'])['local:1'], isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await events.close();
    },
  );

  testWidgets('automatic groups cannot send manual selection commands', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.automatic');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'ready'
              ? {
                  'version': 'test',
                  'coreVersion': 'test',
                  'dashboard': {'status': 'Started'},
                }
              : null;
        });
    final box = BoxController(channel: channel, events: events.stream);
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    events.add({
      'type': 'groups',
      'value': [
        {
          'tag': 'Auto',
          'selected': 'Node A',
          'selectable': false,
          'items': [
            {'tag': 'Node A', 'type': 'Shadowsocks', 'delay': 10},
            {'tag': 'Node B', 'type': 'Shadowsocks', 'delay': 20},
          ],
        },
      ],
    });
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

  testWidgets(
    'the toolbar tests the displayed group and group swipes keep the primary page',
    (tester) async {
      reportFlutterErrors();
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final events = StreamController<dynamic>.broadcast();
      const channel = MethodChannel('test.group-toolbar');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return call.method == 'ready'
                ? {
                    'version': 'test',
                    'coreVersion': 'test',
                    'dashboard': {'status': 'Started'},
                  }
                : null;
          });
      await tester.pumpWidget(
        BoxApp(
          controller: BoxController(channel: channel, events: events.stream),
        ),
      );
      await tester.pumpAndSettle();
      events.add({
        'type': 'groups',
        'value': [
          for (final tag in ['Group A', 'Group B'])
            {
              'tag': tag,
              'selected': 'Node $tag',
              'selectable': true,
              'items': [
                {
                  'id': tag == 'Group A' ? 10 : 20,
                  'tag': 'Node $tag',
                  'type': 'direct',
                },
              ],
            },
        ],
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('Proxies').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Group B'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Test latency').first);
      await tester.pumpAndSettle();
      final test =
          calls.lastWhere((call) => call.method == 'groups.test').arguments
              as Map;
      expect(test['tag'], 'Group B');
      expect(test['profileIds'], [20]);
      await tester.drag(find.byType(TabBarView), const Offset(280, 0));
      await tester.pumpAndSettle();
      expect(find.byType(ProxiesPage).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await events.close();
    },
  );

  testWidgets('nodes select and test while the service is stopped', (
    tester,
  ) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.proxy-stopped');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'ready'
              ? {
                  'version': 'test',
                  'coreVersion': 'test',
                  'dashboard': {'status': 'Stopped'},
                  'preferences': {'locale': 'en'},
                }
              : null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await tester.pumpWidget(
      BoxApp(
        controller: BoxController(channel: channel, events: events.stream),
      ),
    );
    await tester.pumpAndSettle();
    events.add({
      'type': 'groups',
      'value': [
        {
          'id': 1,
          'tag': 'Group A',
          'selected': 'Node A',
          'selectable': true,
          'items': [
            {
              'id': 10,
              'tag': 'Node A',
              'type': 'Shadowsocks',
              'delay': 12,
              'testedAt': 1,
            },
            {
              'id': 11,
              'tag': 'Node B',
              'type': 'Shadowsocks',
              'delay': 34,
              'testedAt': 1,
            },
          ],
        },
      ],
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Proxies').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Node B'));
    await tester.pumpAndSettle();
    expect(
      (calls.lastWhere((call) => call.method == 'groups.select').arguments
          as Map)['tag'],
      'Node B',
    );

    // Tapping the selected node's body must not start a test; only the delay
    // figure has the test action.
    final nodeACard = find.byWidgetPredicate(
      (widget) => widget is ProxyNodeCard && widget.node['tag'] == 'Node A',
    );
    final testsBeforeBodyTap = calls
        .where((call) => call.method == 'groups.test')
        .length;
    await tester.tap(
      find.descendant(of: nodeACard, matching: find.text('Shadowsocks')),
    );
    await tester.pumpAndSettle();
    expect(
      calls.where((call) => call.method == 'groups.test').length,
      testsBeforeBodyTap,
    );

    // The completed-delay target shrinks to its 48px minimum instead of
    // stretching across the rest of the card row.
    final nodeADelay = find.descendant(
      of: nodeACard,
      matching: find.byKey(const ValueKey('delay')),
    );
    expect(tester.getSize(nodeADelay).width, lessThanOrEqualTo(60));
    final selectsBeforeDelayTap = calls
        .where((call) => call.method == 'groups.select')
        .length;
    await tester.tap(nodeADelay);
    await tester.pumpAndSettle();
    expect(
      calls.where((call) => call.method == 'groups.select').length,
      selectsBeforeDelayTap,
    );
    final test =
        calls.lastWhere((call) => call.method == 'groups.test').arguments
            as Map;
    expect(test['tag'], 'Node A');
    expect(test['profileIds'], [10]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets(
    'selected proxies are located outside the lazy grid and the active group survives group updates',
    (tester) async {
      reportFlutterErrors();
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final events = StreamController<dynamic>.broadcast();
      const channel = MethodChannel('test.proxy-locate');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => call.method == 'ready'
                ? {
                    'version': 'test',
                    'coreVersion': 'test',
                    'dashboard': {'status': 'Started'},
                    'preferences': {'locale': 'en'},
                  }
                : null,
          );
      await tester.pumpWidget(
        BoxApp(
          controller: BoxController(channel: channel, events: events.stream),
        ),
      );
      await tester.pumpAndSettle();
      Json group(String tag, int count, int selected) => {
        'tag': tag,
        'selected': '$tag node $selected',
        'selectable': true,
        'items': [
          for (var index = 0; index < count; index++)
            {'tag': '$tag node $index', 'type': 'direct'},
        ],
      };
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
      events.add({
        'type': 'groups',
        'value': [group('New group', 1, 0), ...groups],
      });
      await tester.pumpAndSettle();
      final tabs = tester.widget<TabBarView>(find.byType(TabBarView));
      expect(tabs.controller.index, 2);
      expect(find.text('Group B node 150').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await events.close();
    },
  );

  testWidgets(
    'clicking a node delay shows the running spinner until the test completes',
    (tester) async {
      reportFlutterErrors();
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final events = StreamController<dynamic>.broadcast();
      const channel = MethodChannel('test.proxy-delay-animation');
      final testDone = Completer<dynamic>();
      var tested = false;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'ready') {
          return {
            'version': 'test',
            'coreVersion': 'test',
            'dashboard': {'status': 'Started'},
            'preferences': {'locale': 'en'},
          };
        }
        if (call.method == 'groups.test') {
          tested = true;
          return testDone.future;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(
        BoxApp(
          controller: BoxController(channel: channel, events: events.stream),
        ),
      );
      await tester.pumpAndSettle();
      events.add({
        'type': 'groups',
        'value': [
          {
            'tag': 'Group A',
            'selected': 'Node A',
            'selectable': true,
            'items': [
              {
                'id': 10,
                'tag': 'Node A',
                'type': 'direct',
                'delay': 12,
                'testedAt': 1,
              },
              {
                'id': 11,
                'tag': 'Node B',
                'type': 'direct',
                'delay': 30,
                'testedAt': 1,
              },
            ],
          },
        ],
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('Proxies').last);
      await tester.pumpAndSettle();
      events.add({
        'type': 'testSession',
        'value': {
          'kind': 0,
          'running': false,
          'startedAt': 1,
          'rows': [
            {'id': 10, 'phase': 'DONE'},
            {'id': 11, 'phase': 'DONE'},
          ],
        },
      });
      await tester.pump();

      await tester.tap(find.text('12 ms'));
      await tester.pump();
      expect(tested, isTrue);
      expect(find.byKey(const ValueKey('proxy-test-running')), findsOneWidget);
      final currentSessionStartedAt = DateTime.now().millisecondsSinceEpoch;
      events.add({
        'type': 'testSession',
        'value': {
          'kind': 0,
          'running': true,
          'startedAt': currentSessionStartedAt,
          'rows': [
            {'id': 10, 'phase': 'TESTING'},
            {'id': 11, 'phase': 'QUEUED'},
          ],
        },
      });
      await tester.pump();
      expect(find.byKey(const ValueKey('proxy-test-running')), findsOneWidget);
      // A single-node action does not turn its siblings into a test queue.
      expect(
        find.byKey(const ValueKey('glyph:ProxyTestPhase.queued')),
        findsNothing,
      );
      expect(find.text('30 ms'), findsOneWidget);

      testDone.complete(null);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // The node action owns its spinner: even if the shared session feed still
      // carries a TESTING row, completing groups.test must clear this card.
      expect(find.byKey(const ValueKey('proxy-test-running')), findsNothing);

      // Result persistence arrives as a catalog update. The proxy page must
      // rebuild on that event without requiring another node selection.
      events.add({
        'type': 'groups',
        'value': [
          {
            'tag': 'Group A',
            'selected': 'Node A',
            'selectable': true,
            'items': [
              {
                'id': 10,
                'tag': 'Node A',
                'type': 'direct',
                'delay': 42,
                'testedAt': 2,
              },
              {
                'id': 11,
                'tag': 'Node B',
                'type': 'direct',
                'delay': 30,
                'testedAt': 1,
              },
            ],
          },
        ],
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('42 ms'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await events.close();
    },
  );

  testWidgets('a failing delay test clears its spinner', (tester) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.proxy-delay-failure');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {
          'version': 'test',
          'coreVersion': 'test',
          'dashboard': {'status': 'Started'},
          'preferences': {'locale': 'en'},
        };
      }
      if (call.method == 'groups.test') {
        throw PlatformException(code: 'failed', message: 'test failed');
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      BoxApp(
        controller: BoxController(channel: channel, events: events.stream),
      ),
    );
    await tester.pumpAndSettle();
    events.add({
      'type': 'groups',
      'value': [
        {
          'tag': 'Group A',
          'selected': 'Node A',
          'selectable': true,
          'items': [
            {
              'id': 10,
              'tag': 'Node A',
              'type': 'direct',
              'delay': 12,
              'testedAt': 1,
            },
          ],
        },
      ],
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Proxies').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('12 ms'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('proxy-test-running')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('the node speed test panel hides IP check, test kind and scope', (
    tester,
  ) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.proxy-speed-only');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'ready'
          ? {
              'version': 'test',
              'coreVersion': 'test',
              'dashboard': {'status': 'Started'},
              'preferences': {'locale': 'en'},
            }
          : null,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      BoxApp(
        controller: BoxController(channel: channel, events: events.stream),
      ),
    );
    await tester.pumpAndSettle();
    openPage(
      tester.element(find.byType(HomePage)),
      const TestPanelPage(
        speedOnly: true,
        profileIds: [10],
        initialSpeedMode: 0,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Speed test'), findsOneWidget);
    expect(find.text('Speed test mode'), findsOneWidget);
    expect(find.text('Test kind'), findsNothing);
    expect(find.text('IP check'), findsNothing);
    expect(find.text('Scope'), findsNothing);
    events.add({
      'type': 'testSession',
      'value': {
        'kind': 2,
        'running': false,
        'speed': {
          'profileId': 10,
          'name': 'Node A',
          'stage': 'Complete',
          'dlBps': 8000000,
          'ulBps': 3000000,
          'pingMs': 42,
          'samples': [
            [0, 3000000, false],
            [1, 8000000, false],
            [2, 3000000, true],
          ],
        },
      },
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Last speed test'), findsOneWidget);
    // The panel draws the speed screen's own curve widget, so a batch run and a
    // single run share one chart instead of two lookalikes.
    final curve = tester.widget<SpeedCurves>(
      find.byKey(const ValueKey('speed-curve')),
    );
    expect(curve.download.any((value) => value > 0), isTrue);
    expect(curve.upload.any((value) => value > 0), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets(
    'dedicated speed page starts the native session and renders its snapshot',
    (tester) async {
      reportFlutterErrors();
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final events = StreamController<dynamic>.broadcast();
      const channel = MethodChannel('test.speed-page');
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'ready') {
          return {
            'version': 'test',
            'coreVersion': 'test',
            'dashboard': {'status': 'Started', 'profile': {'id': 7}, 'selectedProfileId': 7},
            'preferences': {'locale': 'en'},
          };
        }
        if (call.method == 'groups.testSession.start') return true;
        if (call.method == 'groups.testSession.stop') return true;
        if (call.method == 'groups.testSession.visible') return null;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final box = BoxController(channel: channel, events: events.stream);
      await tester.pumpWidget(BoxApp(controller: box));
      await tester.pumpAndSettle();
      openPage(
        tester.element(find.byType(HomePage)),
        const SpeedTestPage(outbound: 'Node A'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Start'));
      // The gauge spins while the run is live, so settle on frames rather than
      // waiting for animations to stop.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // The run goes through Throne's own test session, as a speed run.
      final start = calls.lastWhere(
        (call) => call.method == 'groups.testSession.start',
      );
      final args = json(start.arguments);
      expect(args['kind'], 2, reason: 'TestSpec.KIND_SPEED');
      expect(args['profileIds'], isNotEmpty);

      // The session's speed snapshot drives the tiles.
      events.add({
        'type': 'testSession',
        'value': {
          'running': false,
          'speed': {
            'name': 'Node A',
            'stage': 'complete',
            'dlBps': 8000000,
            'ulBps': 3000000,
            'pingMs': 42,
            'server': 'speed.example',
            'serverCountry': 'US',
            'finished': true,
            'samples': [
              [0, 1000, false],
              [1, 4000000, false],
              [2, 8000000, false],
              [3, 500000, true],
              [4, 3000000, true],
            ],
          },
        },
      });
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView).last, const Offset(0, -420));
      await tester.pumpAndSettle();
      expect(find.text('8.00 Mbps'), findsOneWidget);
      expect(find.text('3.00 Mbps'), findsOneWidget);
      expect(find.text('42 ms'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await events.close();
    },
  );

  testWidgets(
    'home speed page runs the session without a named node',
    (tester) async {
      reportFlutterErrors();
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final events = StreamController<dynamic>.broadcast();
      const channel = MethodChannel('test.speed-page-home');
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'ready') {
          return {
            'version': 'test',
            'coreVersion': 'test',
            'dashboard': {'status': 'Started', 'profile': {'id': 7}, 'selectedProfileId': 7},
            'preferences': {'locale': 'en'},
          };
        }
        if (call.method == 'groups.testSession.start') return true;
        if (call.method == 'groups.testSession.visible') return null;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(
        BoxApp(
          controller: BoxController(channel: channel, events: events.stream),
        ),
      );
      await tester.pumpAndSettle();
      openPage(tester.element(find.byType(HomePage)), const SpeedTestPage());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Start'));
      // The gauge spins while the run is live, so settle on frames rather than
      // waiting for animations to stop.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // No outbound was named, so the session measures the started profile.
      final start = calls.lastWhere(
        (call) => call.method == 'groups.testSession.start',
      );
      final args = json(start.arguments);
      expect(args['kind'], 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await events.close();
    },
  );

  // spins, the rows still waiting show the clock. The batch marks every id in
  // one set so the action can be awaited once, and reading that set as "this
  // node is running" painted the whole group as spinning and made the session
  // rows unreachable.
  testWidgets('a group delay test spins only the node under test', (
    tester,
  ) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.group-queue');
    final testDone = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'ready') {
            return {
              'version': 'test',
              'coreVersion': 'test',
              'dashboard': {'status': 'Started'},
              'preferences': {'locale': 'en'},
            };
          }
          if (call.method == 'groups.test') return testDone.future;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await tester.pumpWidget(
      BoxApp(
        controller: BoxController(channel: channel, events: events.stream),
      ),
    );
    await tester.pumpAndSettle();
    events.add({
      'type': 'groups',
      'value': [
        {
          'tag': 'Group A',
          'selected': 'Node A',
          'selectable': true,
          'items': [
            {'id': 10, 'tag': 'Node A', 'type': 'direct', 'delay': 12, 'testedAt': 1},
            {'id': 11, 'tag': 'Node B', 'type': 'direct', 'delay': 30, 'testedAt': 1},
          ],
        },
      ],
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Proxies').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Test latency').first);
    await tester.pump();
    // Rows have not arrived: the whole batch reads as queued, not running.
    expect(find.byKey(const ValueKey('proxy-test-running')), findsNothing);
    expect(
      find.byKey(const ValueKey('glyph:ProxyTestPhase.queued')),
      findsNWidgets(2),
    );

    events.add({
      'type': 'testSession',
      'value': {
        'kind': 0,
        'running': true,
        'startedAt': DateTime.now().millisecondsSinceEpoch,
        'rows': [
          {'id': 10, 'phase': 'TESTING'},
          {'id': 11, 'phase': 'QUEUED'},
        ],
      },
    });
    await tester.pump();
    // One spinner for the node under test, one clock for the one waiting.
    expect(find.byKey(const ValueKey('proxy-test-running')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('glyph:ProxyTestPhase.queued')),
      findsOneWidget,
    );

    testDone.complete(null);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });
}
