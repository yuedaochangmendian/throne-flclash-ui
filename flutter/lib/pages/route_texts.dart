// Rule text: the enum tables Throne for Android exposes as menus, and the
// formatters its `RouteTexts` uses for a rule row. Pure functions over the
// wire shape — no page state, no channel calls.

import '../widgets.dart';

/// A `(stored value, display label)` pair for a rule field that Throne for
/// Android exposes as a fixed `SimpleMenuPreference` instead of free text.
typedef RuleEnumOption = ({String value, String label});

/// The legal stored values, verbatim from Throne for Android's
/// `res/values/arrays.xml` (`route_rule_*_values` / `domain_strategy_values`).
/// The first entry is the empty string: the rule does not narrow the match on
/// that field. `action` keeps this build's `bypass` and adds the `hijack-dns`
/// value the upstream XML carries (additive only, so existing rules survive).
const Map<String, List<RuleEnumOption>> ruleEnumValues = {
  'ip_version': [
    (value: '', label: 'Any'),
    (value: '4', label: 'IPv4'),
    (value: '6', label: 'IPv6'),
  ],
  'network': [
    (value: '', label: 'Any'),
    (value: 'tcp', label: 'tcp'),
    (value: 'udp', label: 'udp'),
    (value: 'icmp', label: 'icmp'),
  ],
  'protocol': [
    (value: '', label: 'Any'),
    (value: 'http', label: 'http'),
    (value: 'tls', label: 'tls'),
    (value: 'quic', label: 'quic'),
    (value: 'stun', label: 'stun'),
    (value: 'dns', label: 'dns'),
    (value: 'bittorrent', label: 'bittorrent'),
    (value: 'dtls', label: 'dtls'),
    (value: 'ssh', label: 'ssh'),
    (value: 'rdp', label: 'rdp'),
    (value: 'ntp', label: 'ntp'),
  ],
  'reject_method': [
    (value: '', label: 'Unset'),
    (value: 'default', label: 'default'),
    (value: 'drop', label: 'drop'),
    (value: 'reply', label: 'reply'),
  ],
  'strategy': [
    (value: '', label: 'Default'),
    (value: 'ipv4_only', label: 'ipv4_only'),
    (value: 'ipv6_only', label: 'ipv6_only'),
    (value: 'prefer_ipv4', label: 'prefer_ipv4'),
    (value: 'prefer_ipv6', label: 'prefer_ipv6'),
  ],
  'action': [
    (value: 'route', label: 'route'),
    (value: 'reject', label: 'reject'),
    (value: 'hijack-dns', label: 'hijack-dns'),
    (value: 'sniff', label: 'sniff'),
    (value: 'resolve', label: 'resolve'),
    (value: 'route-options', label: 'route-options'),
    (value: 'bypass', label: 'bypass'),
  ],
};

/// Throne's `RouteRuleActivity.ensureValue`: a stored value outside the preset
/// list is appended as a selectable option, so opening and saving a rule from
/// an older build never drops or silently rewrites that value.
List<RuleEnumOption> ruleEnumOptions(String key, String current) {
  final presets = ruleEnumValues[key] ?? const <RuleEnumOption>[];
  if (current.isEmpty || presets.any((option) => option.value == current)) {
    return presets;
  }
  return <RuleEnumOption>[...presets, (value: current, label: current)];
}

/// The label for [current]; an empty value resolves to the field's "unset"
/// entry (Any / Unset / Default, depending on the field).
String ruleEnumLabel(String key, String current) {
  for (final option in ruleEnumOptions(key, current)) {
    if (option.value == current) return option.label;
  }
  return current.isEmpty ? 'Any' : current;
}

/// Apply a menu selection. The empty option removes the field entirely instead
/// of storing an empty-string key: Throne's SimpleMenuPreference writes an
/// unset value, and the rule serializer treats a missing key the same way.
Json ruleEnumApply(Json rule, String key, String value) {
  final next = <String, dynamic>{...rule};
  if (value.isEmpty) {
    next.remove(key);
  } else {
    next[key] = value;
  }
  return next;
}

/// The hint under a list field's per-line editor, matching what Throne for Android's
/// `RouteRuleActivity` shows above its own multi-line dialog: what one line is, and — for the
/// domain matches — the example that makes the difference between them clear.
const ruleFieldHints = <String, String>{
  'domain': 'One domain per line; only that exact host matches.',
  'domain_suffix': 'One suffix per line; google.com matches google.com and its subdomains.',
  'domain_keyword': 'One keyword per line; the host has to contain it.',
  'domain_regex': 'One Go regular expression per line, matched against the host.',
  'ip_cidr': 'One CIDR per line, for example 10.0.0.0/8 or 2001:db8::/32.',
  'source_ip_cidr': 'One CIDR per line; the connection\'s own address has to fall inside it.',
  'port': 'One port per line.',
  'port_range': 'One range per line, for example 1000:2000.',
  'source_port': 'One port per line; the connection\'s own source port.',
  'source_port_range': 'One range per line, for example 1000:2000.',
  'process_name': 'One process name per line.',
  'process_path': 'One absolute process path per line.',
  'process_path_regex': 'One Go regular expression per line, matched against the path.',
  'package_name': 'One Android package per line, for example com.example.app.',
  'package_name_regex': 'One regular expression per line, matched against the package name.',
  'inbound': 'One inbound tag per line.',
  'wifi_ssid': 'One network name per line.',
  'wifi_bssid': 'One access point address per line.',
  'sniffers': 'One sniffer per line.',
};

/// The hint for [key]; a field without one still gets the "one per line" reminder.
String ruleFieldHint(BuildContext context, String key) =>
    context.tr(ruleFieldHints[key] ?? 'One value per line.');

/// A rule's row title: its name, or the first match value, or its position.
String ruleName(Json rule, int index) {
  final name = rule['name']?.toString() ?? '';
  if (name.isNotEmpty) return name;
  for (final key in const ['domain', 'domain_suffix', 'ip_cidr', 'port', 'rule_set', 'package_name']) {
    final list = rule[key];
    if (list is List && list.isNotEmpty) return '${list.first}';
  }
  return '#${index + 1}';
}

/// The outbound side of "route → x", Throne's `RouteTexts.outboundName`: the
/// fixed targets as their tokens, a server profile as its id (the picker that
/// reads `groups.nodes` is the only name source, and the row stays synchronous).
String outboundToken(int id) => switch (id) {
  -1 => 'proxy',
  -2 => 'direct',
  -3 => 'block',
  -5 => 'warp-bypass',
  > 0 => '#$id',
  _ => '$id',
};

/// The action line's colour, Throne's route palette (RouteTexts.kt +
/// colors.xml): proxy blue, direct green, reject red, everything else the
/// config purple. Night lifts each hue a Material step so it keeps contrast.
Color routeActionColor(BuildContext context, String action, int outboundId) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return switch (action) {
    'reject' => dark ? const Color(0xFFEF5350) : const Color(0xFFE53935),
    'route' || 'bypass' => outboundId == -2
        ? (dark ? const Color(0xFF66BB6A) : const Color(0xFF43A047))
        : (dark ? const Color(0xFF42A5F5) : const Color(0xFF1E88E5)),
    _ => dark ? const Color(0xFFAB47BC) : const Color(0xFF8E24AA),
  };
}

/// The rule's effect line: "route → direct", "reject (drop)", "resolve
/// (strategy)" — the tokens are the sing-box / desktop names, as upstream.
String ruleActionText(Json rule) {
  final action = rule['action']?.toString() ?? 'route';
  final method = rule['reject_method']?.toString().trim() ?? '';
  final strategy = rule['strategy']?.toString().trim() ?? '';
  return switch (action) {
    'route' || 'bypass' =>
      '$action → ${outboundToken((rule['outbound_id'] as num?)?.toInt() ?? 0)}',
    'reject' => method.isEmpty ? action : '$action ($method)',
    'resolve' => strategy.isEmpty ? action : '$action ($strategy)',
    _ => action,
  };
}

/// The main conditions, Throne's `RouteTexts.ruleConditions`: "suffix:
/// google.com +2 · rule-set: geosite-ir" — first value plus a count, the field
/// tokens lowercase, in the same order the desktop lists them.
String ruleConditions(BuildContext context, Json rule) {
  String list(String label, String key) {
    final raw = rule[key];
    final List<String> items;
    if (raw is List) {
      items = raw.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
    } else {
      final value = raw?.toString().trim() ?? '';
      items = value.isEmpty ? const <String>[] : [value];
    }
    if (items.isEmpty) return '';
    return '$label: ${items.first}${items.length > 1 ? ' +${items.length - 1}' : ''}';
  }

  String scalar(String label, String key) {
    final value = rule[key]?.toString().trim() ?? '';
    return value.isEmpty ? '' : '$label: $value';
  }

  final parts = <String>[
    list('suffix', 'domain_suffix'),
    list('domain', 'domain'),
    list('keyword', 'domain_keyword'),
    list('regex', 'domain_regex'),
    list('rule-set', 'rule_set'),
    list('ip', 'ip_cidr'),
    if (rule['ip_is_private'] == true) context.tr('Private IP'),
    list('app', 'package_name'),
    list('app regex', 'package_name_regex'),
    list('process', 'process_name'),
    list('path', 'process_path'),
    list('path regex', 'process_path_regex'),
    list('port', 'port'),
    list('port range', 'port_range'),
    scalar('protocol', 'protocol'),
    scalar('network', 'network'),
    scalar('ip version', 'ip_version'),
    list('source ip', 'source_ip_cidr'),
    if (rule['source_ip_is_private'] == true) context.tr('Private source IP'),
    list('source port', 'source_port'),
    list('source port range', 'source_port_range'),
    list('inbound', 'inbound'),
    list('network type', 'network_type'),
    if (rule['network_is_expensive'] == true) context.tr('Metered'),
    list('ssid', 'wifi_ssid'),
    list('bssid', 'wifi_bssid'),
  ].where((part) => part.isNotEmpty).toList();
  if (parts.isEmpty) parts.add(context.tr('No conditions'));
  if (rule['invert'] == true) parts.add(context.tr('Inverted'));
  return parts.join(' · ');
}

/// The rule row's two lines, Throne's layout_route_rule_item: the action on
/// top in its colour, the conditions under it in the secondary tone. One Text
/// with the subtitle style the list rows already use, so the row reads like
/// any other while the action line carries the route palette.
Widget ruleRowSubtitle(BuildContext context, Json rule) {
  final action = rule['action']?.toString() ?? 'route';
  final actionColor = routeActionColor(
      context, action, (rule['outbound_id'] as num?)?.toInt() ?? 0);
  final base = context.listSubtitleStyle;
  final colorScheme = Theme.of(context).colorScheme;
  final state = context.tr(rule['disabled'] == true ? 'Disabled' : 'Enabled');
  return Text.rich(
    TextSpan(children: [
      TextSpan(text: '$state · ', style: base.copyWith(color: rule['disabled'] == true ? colorScheme.error : null)),
      TextSpan(
          text: ruleActionText(rule),
          style: base.copyWith(color: actionColor, fontWeight: FontWeight.w500)),
      TextSpan(
          text: '\n${ruleConditions(context, rule)}',
          style: base.copyWith(fontWeight: FontWeight.normal)),
    ]),
  );
}

/// The count line under a profile's "Additional rules" row, e.g. `3 rules`.
String ruleCountSummary(BuildContext context, List<Json> rules) =>
    '${rules.length} ${context.tr('rules')}';
