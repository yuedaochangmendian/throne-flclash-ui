// The routing page after the FlClash refactor: a rule list plus an add-rule
// sheet built from built-in types and targets. The 45-column editor, per-profile
// rules, JSON import and per-profile opt-outs are gone.

import 'dart:async';

import 'package:flrone/core/action.dart';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/errors.dart';
import 'support/fake_route_kernel.dart';

Map<String, Object?> poolRule(String name, {int id = 1}) => {
      'id': id,
      'name': name,
      'type': 'custom',
      'disabled': false,
      'action': 'route',
      'outbound_id': -1,
      'domain_suffix': <String>['example.test'],
    };

void main() {
  late StreamController<dynamic> events;
  late List<Map<String, Object?>> poolRules;
  late List<Map<String, Object?>> savedPool;

  Map<String, Object?>? routeFixtures(ActionMethod method, Object? data) {
    switch (method) {
      case ActionMethod.getGlobalRules:
        return {'rules': poolRules};
      case ActionMethod.saveGlobalRules:
        final payload = data is Map ? data['rules'] : null;
        savedPool = [
          for (final rule in payload as List? ?? const [])
            Map<String, Object?>.from(rule as Map),
        ];
        poolRules = savedPool;
        return {'rules': savedPool};
      case ActionMethod.deleteGlobalRule:
        return null;
      default:
        return null;
    }
  }

  Future<void> mount(WidgetTester tester, {List<Map<String, Object?>>? pool}) async {
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(360, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    poolRules = pool ?? [poolRule('Pool A')];
    savedPool = <Map<String, Object?>>[];
    const channel = MethodChannel('test.routes-page');
    events = StreamController<dynamic>.broadcast();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'ready':
          return {
            'version': 'test',
            'coreVersion': 'test',
            'preferences': {'locale': 'en'},
            'dashboard': {'status': 'Stopped'},
          };
        case 'groups.nodes':
          return {
            'nodes': [
              {'id': 10, 'tag': 'Node A'},
            ],
          };
      }
      return null;
    });
    final box = BoxController(channel: channel, events: events.stream);
    box.kernel.debugAttach(FakeRouteKernel(routeFixtures), NoopKernelWorker());
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await events.close();
      messenger.setMockMethodCallHandler(channel, null);
    });
  }

  Future<void> openRouting(WidgetTester tester) async {
    openPage(tester.element(find.byType(HomePage)), const RoutingPage());
    await tester.pumpAndSettle();
  }

  testWidgets('the routing page is the rule list with an Add rule action', (tester) async {
    reportFlutterErrors();
    await mount(tester);
    await openRouting(tester);

    expect(find.text('Pool A'), findsOneWidget);
    expect(find.byTooltip('Add rule'), findsOneWidget);
    expect(find.byTooltip('Import rules from JSON'), findsNothing);
    expect(find.text('Per-profile rules'), findsNothing);
    expect(find.text('Restore defaults'), findsNothing);
    // The engine switches stay: they set how rules resolve, not which rules exist.
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Route settings'), findsOneWidget);
    expect(find.text('Automatic updates'), findsOneWidget);
    expect(find.text('Per-profile rules'), findsNothing);
    expect(find.text('Restore defaults'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Add rule opens the built-in type picker', (tester) async {
    reportFlutterErrors();
    await mount(tester);
    await openRouting(tester);

    await tester.tap(find.byTooltip('Add rule'));
    await tester.pumpAndSettle();

    expect(find.text('Rule type'), findsWidgets);
    expect(find.text('Target'), findsWidgets);
    expect(find.text(ruleKinds.first.label), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the type picker offers all 33 built-in FlClash types', (tester) async {
    reportFlutterErrors();
    await mount(tester);
    await openRouting(tester);
    await tester.tap(find.byTooltip('Add rule'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rule type').last);
    await tester.pumpAndSettle();

    for (final kind in ruleKinds) {
      expect(find.text(kind.label), findsWidgets, reason: '${kind.label} must be offered');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('adding a rule writes it to the pool', (tester) async {
    reportFlutterErrors();
    await mount(tester, pool: []);
    await openRouting(tester);
    await tester.tap(find.byTooltip('Add rule'));
    await tester.pumpAndSettle();

    // The page's search field comes first, then the sheet's Name and Content.
    await tester.enterText(find.byType(TextField).at(2), 'example.test');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add rule').last);
    await tester.pumpAndSettle();

    expect(savedPool.length, 1);
    expect(savedPool.single['domain'], ['example.test']);
    expect(savedPool.single['action'], 'route');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a rule without content is refused', (tester) async {
    reportFlutterErrors();
    await mount(tester, pool: []);
    await openRouting(tester);
    await tester.tap(find.byTooltip('Add rule'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add rule').last);
    await tester.pumpAndSettle();

    expect(find.text('Content is required'), findsOneWidget);
    expect(savedPool, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the search field filters the pool', (tester) async {
    reportFlutterErrors();
    await mount(tester, pool: [poolRule('Keep me'), poolRule('Hide me', id: 2)]);
    await openRouting(tester);

    expect(find.text('Keep me'), findsOneWidget);
    expect(find.text('Hide me'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Keep');
    await tester.pumpAndSettle();
    expect(find.text('Keep me'), findsOneWidget);
    expect(find.text('Hide me'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection mode opens from the bar and can delete', (tester) async {
    reportFlutterErrors();
    await mount(tester);
    await openRouting(tester);

    expect(find.byTooltip('Delete selected'), findsNothing);
    await tester.tap(find.byTooltip('Select'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Delete selected'), findsOneWidget);
    expect(find.byTooltip('Select all'), findsOneWidget);
    await tester.tap(find.byTooltip('Select all'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete selected'));
    await tester.pumpAndSettle();
    expect(find.text('Delete selected'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the rule list no longer offers per-profile disable or enable', (tester) async {
    reportFlutterErrors();
    await mount(tester);
    await openRouting(tester);

    await tester.longPress(find.text('Pool A'));
    await tester.pumpAndSettle();
    expect(find.text('Disable for a profile'), findsNothing);
    expect(find.text('Enable for a profile'), findsNothing);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the built-in list carries the 33 FlClash rule types', (tester) async {
    expect(ruleKinds.length, 33);
    expect(ruleKinds.map((kind) => kind.label).toSet().length, 33);
  });
}
