import 'dart:async';
import 'dart:convert';

import 'package:flrone/main.dart';
import 'package:flrone/pages/auto_selector.dart';
import 'package:flrone/pages/group_settings.dart';
import 'package:flrone/pages/protocol_form.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/errors.dart';

void main() {
  Future<void> mount(WidgetTester tester, Future<dynamic> Function(MethodCall) handler) async {
    reportFlutterErrors();
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const channel = MethodChannel('test.maintenance-pages');
    final events = StreamController<dynamic>.broadcast();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {
          'version': 'test',
          'coreVersion': 'test',
          'preferences': {'locale': 'en'},
          'dashboard': {'status': 'Stopped'},
        };
      }
      return handler(call);
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

  testWidgets('typed protocol form renders a loaded protocol document', (tester) async {
    await mount(tester, (call) async {
      if (call.method == 'profiles.nodeConfig') {
        return {
          'name': 'Node A',
          'json': jsonEncode({
            'type': 'shadowsocks',
            'tag': 'Node A',
            'server': 'example.com',
            'server_port': 8388,
            'method': 'aes-256-gcm',
            'password': 'secret',
          }),
        };
      }
      return null;
    });
    openPage(tester.element(find.byType(HomePage)), const ProtocolFormPage(id: 1));
    await tester.pumpAndSettle();
    expect(find.text('Edit settings'), findsWidgets);
    expect(find.text('Node A'), findsWidgets);
    expect(find.byTooltip('Save'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('group settings renders a basic group and exposes save', (tester) async {
    await mount(tester, (call) async {
      if (call.method == 'groupSettings.get') {
        return {
          'id': 7,
          'name': 'Primary',
          'type': 'basic',
          'url': '',
          'skipAutoUpdate': false,
          'autoClearUnavailable': false,
          'importSubRoute': false,
          'frontProxyId': -1,
          'landingProxyId': -1,
          'routeId': '-1',
          'sortMethod': 0,
          'sortDescending': false,
          'testSortBy': 0,
          'trafficSortBy': 0,
          'testItemsToShow': 0,
          'options': <String, dynamic>{},
          'defaults': <String, dynamic>{},
          'groups': <dynamic>[],
        };
      }
      return null;
    });
    openPage(tester.element(find.byType(HomePage)), const GroupSettingsPage(id: 7));
    await tester.pumpAndSettle();
    expect(find.text('Group settings'), findsWidgets);
    expect(find.text('Basic'), findsOneWidget);
    expect(find.text('Primary'), findsWidgets);
    expect(find.byTooltip('Save'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('auto selector renders idle status and its filters', (tester) async {
    await mount(tester, (call) async {
      if (call.method == 'profiles.autoSelectorInfo') {
        return {
          'id': 9,
          'name': 'Auto',
          'gids': [1],
          'groups': [{'id': 1, 'name': 'Source'}],
          'members': <dynamic>[],
          'balance': false,
        };
      }
      if (call.method == 'profiles.autoSelectorStatus') {
        return {'phase': 'idle', 'driver': 'ffi'};
      }
      return null;
    });
    openPage(tester.element(find.byType(HomePage)), const AutoSelectorPage(id: 9));
    await tester.pumpAndSettle();
    expect(find.text('Auto selector'), findsWidgets);
    expect(find.text('Filters'), findsWidgets);
    expect(find.byTooltip('Save'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
