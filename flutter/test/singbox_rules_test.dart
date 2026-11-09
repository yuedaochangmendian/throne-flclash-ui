// The sing-box fragment importer: which shapes it accepts, how a rule becomes the map
// `routes.saveRules` takes, and what it refuses instead of guessing.

import 'dart:io';

import 'package:flrone/common/singbox_rules.dart';
import 'package:flrone/ui/json/engine/schema_document.dart';
import 'package:flrone/ui/json/engine/schema_store.dart';
import 'package:flrone/ui/json/engine/schema_validator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The asset bundle is not loaded under `flutter test`, so the importer is handed the same
  // document read from disk — the file the app bundles. A parse failure throws here, which fails
  // the whole file rather than every schema assertion one by one.
  final SchemaDocument schema = SchemaStore.parse(
    File('assets/schema/sing-box.json').readAsStringSync(),
  )!;

  Future<RuleImportResult> run(
    String text, {
    RuleImportKind kind = RuleImportKind.route,
    Map<String, int> outboundIds = const {},
  }) => RuleImporter(outboundIds: outboundIds, schema: schema).run(text, kind: kind);

  group('shapes', () {
    test('a single rule object becomes one stored rule', () async {
      final result = await run('{"domain_suffix": ["google.com"], "outbound": "proxy"}');
      expect(result.error, isNull);
      expect(result.routeRules, hasLength(1));
      final rule = result.routeRules.single;
      expect(rule['name'], 'imported rule #1');
      expect(rule['type'], 'custom');
      expect(rule['action'], 'route');
      expect(rule['outbound_id'], -1);
      expect(rule['domain_suffix'], ['google.com']);
      // Every stored member is present, so the editor never reads a null.
      expect(rule['domain'], isEmpty);
      expect(rule['invert'], isFalse);
      expect(rule['reject_method'], '');
    });

    test('an array of rules numbers them in order', () async {
      final result = await run('''
        [{"domain": ["a.com"], "outbound": "direct"},
         {"domain": ["b.com"], "outbound": "block"}]
      ''');
      expect(result.routeRules.map((r) => r['name']), ['imported rule #1', 'imported rule #2']);
      expect(result.routeRules[0]['outbound_id'], -2);
      expect(result.routeRules[1]['outbound_id'], -3);
    });

    test('a route object takes its rules array', () async {
      final result = await run('{"route": {"rules": [{"domain": ["a.com"]}]}}');
      expect(result.routeRules, hasLength(1));
      expect(result.dnsRules, isEmpty);
    });

    test('a dns object takes its rules array verbatim', () async {
      final result = await run(
        '{"dns": {"rules": [{"query_type": ["A"], "action": "route", "server": "remote"}]}}',
      );
      expect(result.routeRules, isEmpty);
      expect(result.dnsRules, hasLength(1));
      expect(result.dnsRules.single['query_type'], ['A']);
      expect(result.dnsRules.single['server'], 'remote');
    });

    test('a whole config yields both lists', () async {
      final result = await run('''
        {"log": {"level": "info"},
         "route": {"rules": [{"domain": ["a.com"], "outbound": "proxy"}]},
         "dns": {"rules": [{"domain_suffix": ["b.com"], "action": "reject"}]}}
      ''');
      expect(result.routeRules, hasLength(1));
      expect(result.dnsRules, hasLength(1));
      expect(result.problems, isEmpty);
      expect(result.total, 2);
    });

    test('a bare rules array follows the selected kind', () async {
      const text = '{"rules": [{"domain_suffix": ["a.com"], "action": "reject"}]}';
      expect((await run(text)).routeRules, hasLength(1));
      final dns = await run(text, kind: RuleImportKind.dns);
      expect(dns.routeRules, isEmpty);
      expect(dns.dnsRules, hasLength(1));
    });

    test('a mixed bare array is classified automatically without a rule kind', () async {
      const text = '''
        {"rules": [
          {"domain": ["app.example"], "outbound": "proxy"},
          {"query_type": ["A"], "domain_suffix": ["dns.example"], "server": "remote"}
        ]}
      ''';
      final result = await run(text);
      expect(result.routeRules, hasLength(1));
      expect(result.dnsRules, hasLength(1));
      expect(result.routeRules.single['domain'], ['app.example']);
      expect(result.dnsRules.single['server'], 'remote');
      expect(result.problems, isEmpty);
      expect(result.hasErrors, isFalse);
      expect(result.issues.where((issue) => issue.severity == Severity.error), isEmpty);

      final topLevel = await run('''[
        {"domain": ["app.example"], "outbound": "proxy"},
        {"query_type": ["A"], "server": "remote"}
      ]''');
      expect(topLevel.routeRules, hasLength(1));
      expect(topLevel.dnsRules, hasLength(1));
      expect(topLevel.hasErrors, isFalse);
    });

    test('a non-object, non-array fragment is refused', () async {
      final result = await run('"just a string"');
      expect(result.error, isNotNull);
      expect(result.total, 0);
    });

    test('broken JSON reports the parse error', () async {
      final result = await run('{"rules": [');
      expect(result.error, isNotNull);
      expect(result.issues.single.severity, Severity.error);
    });

    test('a route whose rules is not an array is refused', () async {
      final result = await run('{"route": {"rules": {"domain": ["a.com"]}}}');
      expect(result.error, contains('must be an array'));
    });

    test('a route or dns that is not an object is refused', () async {
      expect((await run('{"route": "rules"}')).error, contains('"route" must be a JSON object'));
      expect((await run('{"dns": 1}')).error, contains('"dns" must be a JSON object'));
    });
  });

  group('conversion', () {
    test('sing-box scalars and numbers land in their stored members', () async {
      final result = await run('''
        {"ip_version": 4, "network": "tcp", "protocol": "tls",
         "port": [80, 443], "port_range": ["1000:2000"], "invert": true,
         "domain_keyword": ["ads"], "outbound": "proxy"}
      ''');
      final rule = result.routeRules.single;
      expect(rule['ip_version'], '4');
      expect(rule['network'], 'tcp');
      expect(rule['protocol'], 'tls');
      expect(rule['port'], ['80', '443']);
      expect(rule['port_range'], ['1000:2000']);
      expect(rule['invert'], isTrue);
      expect(rule['domain_keyword'], ['ads']);
    });

    test('a reject keeps its method', () async {
      final result = await run('{"domain": ["a.com"], "action": "reject", "method": "drop"}');
      final rule = result.routeRules.single;
      expect(rule['action'], 'reject');
      expect(rule['reject_method'], 'drop');
    });

    test('a sniff rule keeps its override flag', () async {
      final result = await run('{"domain": ["a.com"], "action": "sniff", "override_destination": true}');
      final rule = result.routeRules.single;
      expect(rule['action'], 'sniff');
      expect(rule['sniff_override_dest'], isTrue);
    });

    test('a resolve rule keeps its strategy', () async {
      final result = await run('{"domain": ["a.com"], "action": "resolve", "strategy": "prefer_ipv4"}');
      expect(result.routeRules.single['strategy'], 'prefer_ipv4');
    });

    test('the warp-bypass tag and its underscore spelling both resolve', () async {
      for (final tag in ['warp-bypass', 'warp_bypass']) {
        final result = await run('{"domain": ["a.com"], "outbound": "$tag"}');
        expect(result.routeRules.single['outbound_id'], -5, reason: tag);
      }
    });

    test('a server tag resolves through the supplied ids', () async {
      final result = await run(
        '{"domain": ["a.com"], "outbound": "My Server"}',
        outboundIds: {'My Server': 7},
      );
      expect(result.routeRules.single['outbound_id'], 7);
    });

    test('the sniffers member accepts sing-box\'s singular spelling', () async {
      final result = await run('{"domain": ["a.com"], "action": "sniff", "sniffer": ["tls"]}');
      expect(result.routeRules.single['sniffers'], ['tls']);
    });

    test('a rule keeps the name it carries', () async {
      final result = await run('{"name": "Ads", "domain": ["a.com"]}');
      expect(result.routeRules.single['name'], 'Ads');
    });
  });

  group('refusals', () {
    test('an unknown outbound skips the rule instead of pointing it at Direct', () async {
      final result = await run('{"domain": ["a.com"], "outbound": "missing"}');
      expect(result.routeRules, isEmpty);
      expect(result.problems.single.reason, contains('unknown outbound'));
    });

    test('a logical rule is skipped with its reason', () async {
      final result = await run('''
        {"type": "logical", "mode": "or", "rules": [{"domain": ["a.com"]}]}
      ''');
      expect(result.routeRules, isEmpty);
      expect(result.problems.single.reason, contains('logical'));
    });

    test('an unsupported action is skipped', () async {
      final result = await run('{"domain": ["a.com"], "action": "predefined"}');
      expect(result.routeRules, isEmpty);
      expect(result.problems.single.reason, contains('unsupported action'));
    });

    test('a non-object element of a rule array is reported, not dropped silently', () async {
      final result = await run('["nope"]');
      expect(result.routeRules, isEmpty);
      expect(result.problems.single.reason, 'not a JSON object');
    });

    test('a non-object DNS rule is reported', () async {
      final result = await run('{"dns": {"rules": ["nope"]}}');
      expect(result.dnsRules, isEmpty);
      expect(result.problems.single.rule, 'DNS rule #1');
    });
  });

  group('schema', () {
    test('a misspelt member is an error the editor can underline', () async {
      final result = await run('{"domain_sufix": ["a.com"], "outbound": "proxy"}');
      expect(result.issues, isNotEmpty);
      expect(result.hasErrors, isTrue);
      // The rule still converts: the preview shows the issue, the user decides.
      expect(result.routeRules, hasLength(1));
    });

    test('the Android-only members the schema carries raise no error', () async {
      final result = await run('''
        {"package_name": ["com.example"], "package_name_regex": ["^com\\\\.x"],
         "network_type": ["wifi"], "network_is_expensive": true, "outbound": "proxy"}
      ''');
      expect(result.issues.map((issue) => '${issue.pointer} ${issue.message}').toList(), isEmpty);
      expect(result.routeRules.single['package_name'], ['com.example']);
      expect(result.routeRules.single['network_type'], ['wifi']);
    });

    test('the sniffers member is allowed even though sing-box spells it sniffer', () async {
      final result = await run('{"sniffers": ["tls"], "action": "sniff"}');
      expect(result.issues.map((issue) => '${issue.pointer} ${issue.message}').toList(), isEmpty);
    });

    test('a DNS rule is checked against the DNS schema', () async {
      final result = await run('{"dns": {"rules": [{"query_typo": ["A"]}]}}');
      expect(result.issues.where((issue) => issue.severity == Severity.error), isNotEmpty);
      expect(result.dnsRules, hasLength(1));
    });

    test('a bad value type is reported at its own path', () async {
      // `domain` takes a string or an array of them; a number is neither.
      final result = await run('{"route": {"rules": [{"domain": 42}]}}');
      final errors = result.issues.where((issue) => issue.severity == Severity.error);
      expect(errors, isNotEmpty);
      expect(errors.first.pointer, contains('domain'));
    });
  });
}
