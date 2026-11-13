// The built-in rule types behind the FlClash-style add-rule sheet.
//
// This is the one place a Clash rule type becomes a Throne `RouteRule` row, so
// the mapping is pinned here: a type that quietly writes to no column would
// produce a rule that looks saved and matches nothing.

import 'package:flrone/pages/rule_picker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the built-in list carries the 33 FlClash rule types', () {
    expect(ruleKinds.length, 33);
    expect(ruleKinds.map((kind) => kind.label).toSet().length, 33);
  });

  test('MATCH is a catch-all with no condition', () {
    final kind = ruleKinds.singleWhere((kind) => kind.label == 'MATCH');
    final rule = buildRuleFromPicker(kind: kind, content: '', target: -1);
    expect(rule['action'], 'route');
    expect(rule['outbound_id'], -1);
    expect(rule.containsKey('domain'), isFalse);
  });

  test('a domain type writes its own column', () {
    final kind = ruleKinds.singleWhere((kind) => kind.label == 'DOMAIN-SUFFIX');
    final rule = buildRuleFromPicker(
      kind: kind,
      content: ' example.com , foo.test ,, ',
      target: -2,
    );
    expect(rule['domain_suffix'], ['example.com', 'foo.test']);
    expect(rule['outbound_id'], -2);
  });

  test('RULE-SET and GEO types use the rule_set column', () {
    for (final label in ['RULE-SET', 'GEOSITE', 'GEOIP', 'IP-ASN']) {
      final kind = ruleKinds.singleWhere((k) => k.label == label);
      final rule = buildRuleFromPicker(kind: kind, content: 'cn', target: -1);
      expect(rule['rule_set'], ['cn'], reason: '$label must map to rule_set');
    }
  });

  test('REJECT becomes an action, not an outbound', () {
    final kind = ruleKinds.singleWhere((kind) => kind.label == 'DOMAIN');
    final rule = buildRuleFromPicker(kind: kind, content: 'ads.test', target: -3);
    expect(rule['action'], 'reject');
    expect(rule['outbound_id'], isNot(-3));
  });

  test('a node target keeps its id', () {
    final kind = ruleKinds.singleWhere((kind) => kind.label == 'IP-CIDR');
    final rule = buildRuleFromPicker(kind: kind, content: '1.2.3.0/24', target: 42);
    expect(rule['outbound_id'], 42);
    expect(rule['ip_cidr'], ['1.2.3.0/24']);
  });

  test('unsupported types are named, not silently mapped', () {
    for (final label in unsupportedRuleKinds) {
      expect(ruleKinds.any((kind) => kind.label == label), isTrue,
          reason: '$label must still appear in the list so the user can see it');
    }
  });

  test('a name and disabled state are always set', () {
    final rule = buildRuleFromPicker(
      kind: ruleKinds.first,
      content: 'x.test',
      target: -1,
      name: 'My rule',
    );
    expect(rule['name'], 'My rule');
    expect(rule['disabled'], false);
    expect(rule['type'], 'custom');
  });
}
