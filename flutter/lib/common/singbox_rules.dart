// Importing a sing-box JSON fragment into the route editor's rule shape.
//
// A fragment is any of: one rule object, an array of rules, a `route` / `dns` object, or a whole
// config carrying both. Route rules are converted to the map `routes.saveRules` takes; DNS rules
// are kept verbatim because the DNS object is stored as JSON. Both are checked against the
// bundled schema first (`#/$defs/Rule`, `#/$defs/DNSRule`), so a misspelt key shows up in the
// editor instead of failing the core at start-up.

import '../ui/json/engine/json_tree.dart';
import '../ui/json/engine/schema_document.dart';
import '../ui/json/engine/schema_store.dart';
import '../ui/json/engine/schema_validator.dart';

/// The list a bare, structurally ambiguous rule is assumed to belong to. Explicit `route` and
/// `dns` containers, and rules carrying DNS-only members such as `query_type` or `server`, are
/// classified automatically regardless of this fallback.
enum RuleImportKind { route, dns }

/// One rule the importer left out, and why. [rule] is "rule #N" in the fragment's own order.
class RuleImportProblem {
  const RuleImportProblem(this.rule, this.reason);
  final String rule;
  final String reason;
}

/// What one fragment yields: the rules to add, what was left out, and the schema's complaints.
class RuleImportResult {
  const RuleImportResult({
    this.routeRules = const [],
    this.dnsRules = const [],
    this.problems = const [],
    this.issues = const [],
    this.error,
  });

  /// Editor maps, ready for `routes.saveRules`.
  final List<Map<String, dynamic>> routeRules;

  /// sing-box DNS rule objects, kept as written.
  final List<Map<String, dynamic>> dnsRules;

  final List<RuleImportProblem> problems;

  /// Schema issues over the fragment as pasted, for the editor's underline strip.
  final List<JsonIssue> issues;

  /// Set when the text is not JSON at all, or its shape names no rules.
  final String? error;

  int get total => routeRules.length + dnsRules.length;

  bool get hasErrors => error != null || issues.any((issue) => issue.severity == Severity.error);
}

/// The stored-rule members, mirroring `RouteRule.STRING_FIELDS` / `LIST_FIELDS` / `BOOL_FIELDS`.
const _stringFields = [
  'ip_version', 'network', 'protocol', 'reject_method', 'override_address', 'override_port',
  'tls_fragment_fallback_delay', 'tls_spoof', 'tls_spoof_method', 'strategy',
];

const _listFields = [
  'inbound', 'domain', 'domain_suffix', 'domain_keyword', 'domain_regex', 'source_ip_cidr',
  'ip_cidr', 'source_port', 'source_port_range', 'port', 'port_range', 'process_name',
  'process_path', 'process_path_regex', 'package_name', 'package_name_regex', 'network_type',
  'wifi_ssid', 'wifi_bssid', 'rule_set', 'sniffers',
];

const _boolFields = [
  'source_ip_is_private', 'ip_is_private', 'invert', 'no_drop', 'sniff_override_dest',
  'network_is_expensive', 'tls_fragment', 'tls_record_fragment',
];

/// The fixed outbound tags of the generated config (`OutboundIds.toName`) and the ids they stand for.
const _fixedOutbounds = {'proxy': -1, 'direct': -2, 'block': -3, 'warp-bypass': -5};

/// The actions a stored rule can carry, `RuleRule`'s set minus the ones the core only accepts from
/// its own generated config.
const _actions = {
  'route', 'route-options', 'bypass', 'reject', 'hijack-dns', 'sniff', 'resolve',
};

/// Rule keys the bundled schema does not describe but the stored rule keeps.
const _extraRuleKeys = ['sniffers'];

/// Keys that make an object a rule rather than a `{"rules": [...]}` container. A logical rule
/// carries `type` and `rules` together, and must not be mistaken for the container.
const _ruleMarkers = {
  'type', 'action', 'outbound', 'inbound', 'domain', 'domain_suffix', 'domain_keyword',
  'domain_regex', 'ip_cidr', 'port', 'port_range', 'rule_set', 'protocol', 'network',
  'process_name', 'process_path', 'package_name', 'server', 'query_type',
};

/// Members that only a DNS rule can carry (ordinary route rules use `outbound` instead of
/// `server`). These are enough to separate mixed bare arrays without asking for a rule kind.
const _dnsOnlyMarkers = {
  'query_type', 'query_client_subnet', 'query_dnssec', 'server', 'response_rcode',
  'response_answer', 'response_ns', 'response_extra', 'match_response',
};

const _routeOnlyActions = {'sniff', 'resolve', 'hijack-dns', 'bypass'};

bool _looksLikeRule(Map<dynamic, dynamic> map) => _ruleMarkers.any(map.containsKey);

/// A rule this build cannot store, with the reason shown in the preview.
class _Skip implements Exception {
  const _Skip(this.reason);
  final String reason;
}

/// Converts a sing-box fragment into rules the editor can add.
class RuleImporter {
  const RuleImporter({this.outboundIds = const {}, this.schema});

  /// sing-box outbound tag to profile id, for the rules that name a server.
  final Map<String, int> outboundIds;

  /// The schema to check against; null reads the bundled one. Tests pass the same asset parsed
  /// from disk, because the asset bundle is not loaded under `flutter test`.
  final SchemaDocument? schema;

  Future<RuleImportResult> run(String text, {RuleImportKind kind = RuleImportKind.route}) async {
    final parsed = JsonTree.parse(text);
    final root = parsed.root;
    if (root == null) {
      return RuleImportResult(error: parsed.error, issues: [
        JsonIssue(Severity.error, parsed.error, '', parsed.errorSpan),
      ]);
    }
    final shape = _shape(JsonTree.toPlain(root), kind);
    if (shape.error != null) return RuleImportResult(error: shape.error);

    final document = schema ?? await SchemaStore.get();
    final issues = document == null ? const <JsonIssue>[] : _validate(document, shape, root);

    final routeRules = <Map<String, dynamic>>[];
    final dnsRules = <Map<String, dynamic>>[];
    final problems = <RuleImportProblem>[];

    for (final (index, raw) in shape.route.indexed) {
      try {
        routeRules.add(_convertRule(raw, 'imported rule #${index + 1}'));
      } on _Skip catch (skip) {
        problems.add(RuleImportProblem('rule #${index + 1}', skip.reason));
      }
    }
    for (final (index, raw) in shape.dns.indexed) {
      if (raw is Map) {
        dnsRules.add(Map<String, dynamic>.from(raw));
      } else {
        problems.add(RuleImportProblem('DNS rule #${index + 1}', 'not a JSON object'));
      }
    }

    return RuleImportResult(
      routeRules: routeRules,
      dnsRules: dnsRules,
      problems: problems,
      issues: issues,
    );
  }

  /// The rule list(s) the document names, plus the schema node that describes its shape.
  _Shape _shape(Object? plain, RuleImportKind kind) {
    if (plain is List) {
      return _Shape.rules(plain, kind, list: true);
    }
    if (plain is! Map) {
      return const _Shape.error('The fragment must be a JSON object or an array of rules');
    }
    final route = plain['route'];
    final dns = plain['dns'];
    if (plain.containsKey('route') || plain.containsKey('dns')) {
      if (route != null && route is! Map) {
        return const _Shape.error('"route" must be a JSON object with a "rules" array');
      }
      if (dns != null && dns is! Map) {
        return const _Shape.error('"dns" must be a JSON object with a "rules" array');
      }
      if (route is Map && route['rules'] != null && route['rules'] is! List) {
        return const _Shape.error('"route.rules" must be an array');
      }
      if (dns is Map && dns['rules'] != null && dns['rules'] is! List) {
        return const _Shape.error('"dns.rules" must be an array');
      }
      return _Shape(
        route: route is Map ? _rulesOf(route) : const [],
        dns: dns is Map ? _rulesOf(dns) : const [],
        schemaNode: null,
      );
    }
    final rules = plain['rules'];
    // A logical rule carries its own `rules` array; only a bare container is a list of rules.
    if (rules is List && !_looksLikeRule(plain)) {
      return _Shape.rules(rules, kind, list: true);
    }
    // A bare rule object: classify from its members, falling back to the page it was opened from.
    return _Shape.rules([plain], kind, list: false);
  }

  List<Object?> _rulesOf(Map<dynamic, dynamic> container) {
    final rules = container['rules'];
    return rules is List ? rules : const [];
  }

  /// Validates the document as pasted, so every issue carries a pointer into the user's own text.
  List<JsonIssue> _validate(SchemaDocument schema, _Shape shape, JsonValue root) {
    final node = shape.schemaNode;
    final validator = node == null
        ? SchemaValidator.create(schema)
        : SchemaValidator.createForNode(schema, node);
    if (validator == null) return const [];
    // The stored rule keeps `sniffers`, which sing-box spells `sniffer` on the action. The
    // pointer addresses the rule object itself: '' at the root, then one segment per nesting.
    for (final key in _extraRuleKeys) {
      for (var depth = 0; depth <= 4; depth++) {
        validator.allowExtraKey('/${List.filled(depth, '*').join('/')}', key);
      }
    }
    return validator.validate(root);
  }

  /// One sing-box rule as the editor's map, or a [_Skip] saying why it cannot be stored.
  Map<String, dynamic> _convertRule(Object? raw, String name) {
    if (raw is! Map) throw const _Skip('not a JSON object');
    final rule = <String, dynamic>{
      'name': _text(raw['name']).isEmpty ? name : _text(raw['name']),
      'type': 'custom',
      'disabled': false,
      'action': 'route',
      'outbound_id': -2,
    };
    for (final field in _stringFields) {
      rule[field] = '';
    }
    for (final field in _listFields) {
      rule[field] = <String>[];
    }
    for (final field in _boolFields) {
      rule[field] = false;
    }

    if (_text(raw['type']) == 'logical') {
      throw const _Skip('logical rules have no stored form; add their parts separately');
    }
    for (final field in _listFields) {
      if (field == 'sniffers' && !raw.containsKey('sniffers') && raw['sniffer'] != null) {
        rule[field] = _strings(raw['sniffer']);
        continue;
      }
      if (raw.containsKey(field)) rule[field] = _strings(raw[field]);
    }
    for (final field in _boolFields) {
      if (raw.containsKey(field)) rule[field] = raw[field] == true;
    }
    // The scalars the fragment may spell differently from the stored member.
    rule['ip_version'] = _text(raw['ip_version']);
    rule['network'] = _text(raw['network']);
    rule['protocol'] = _text(raw['protocol']);
    rule['strategy'] = _text(raw['strategy']);
    rule['reject_method'] = _text(raw['method']);
    rule['override_address'] = _text(raw['override_address']);
    rule['override_port'] = _text(raw['override_port']);
    rule['tls_fragment_fallback_delay'] = _text(raw['tls_fragment_fallback_delay']);
    rule['tls_spoof'] = _text(raw['tls_spoof']);
    rule['tls_spoof_method'] = _text(raw['tls_spoof_method']);
    rule['sniff_override_dest'] = raw['override_destination'] == true;

    final action = _text(raw['action']);
    if (action.isNotEmpty && !_actions.contains(action)) {
      throw _Skip('unsupported action "$action"');
    }
    rule['action'] = action.isEmpty ? 'route' : action;

    final outbound = raw['outbound'];
    if (outbound != null && (rule['action'] == 'route' || rule['action'] == 'bypass')) {
      rule['outbound_id'] = _outboundId(outbound);
    }
    return rule;
  }

  /// A sing-box outbound tag as the profile id it stands for; unknown tags are refused rather than
  /// silently pointed at Direct, because that would change where the rule sends traffic.
  int _outboundId(Object? outbound) {
    if (outbound is num) return outbound.toInt();
    final tag = _text(outbound).trim();
    final fixed = _fixedOutbounds[tag] ?? _fixedOutbounds[tag.replaceAll('_', '-')];
    if (fixed != null) return fixed;
    final id = outboundIds[tag];
    if (id != null) return id;
    throw _Skip('unknown outbound "$tag"; import it after that profile exists');
  }
}

/// The document's rule lists and the schema node describing its shape; [schemaNode] null means the
/// whole document is a config and the schema root applies.
class _Shape {
  const _Shape({required this.route, required this.dns, required this.schemaNode}) : error = null;
  const _Shape.error(this.error) : route = const [], dns = const [], schemaNode = null;

  factory _Shape.rules(List<Object?> rules, RuleImportKind fallback, {required bool list}) {
    final route = <Object?>[];
    final dns = <Object?>[];
    for (final rule in rules) {
      final map = rule is Map ? rule : null;
      if (map != null && _looksLikeDnsRule(map, fallback)) {
        dns.add(rule);
      } else if (map == null && fallback == RuleImportKind.dns) {
        dns.add(rule);
      } else {
        route.add(rule);
      }
    }
    final onlyRoute = dns.isEmpty && route.isNotEmpty;
    final onlyDns = route.isEmpty && dns.isNotEmpty;
    final ref = onlyDns ? SchemaStore.dnsRule : SchemaStore.rule;
    final schemaNode = onlyRoute || onlyDns
        ? list
            ? {'type': 'array', 'items': {r'$ref': ref}}
            : {r'$ref': ref}
        : null;
    return _Shape(route: route, dns: dns, schemaNode: schemaNode);
  }

  final List<Object?> route;
  final List<Object?> dns;
  final Map<String, dynamic>? schemaNode;
  final String? error;
}

bool _looksLikeDnsRule(Map<dynamic, dynamic> rule, RuleImportKind fallback) {
  if (_dnsOnlyMarkers.any(rule.containsKey)) return true;
  if (rule.containsKey('outbound')) return false;
  final action = _text(rule['action']);
  if (_routeOnlyActions.contains(action)) return false;
  final nested = rule['rules'];
  if (rule['type'] == 'logical' && nested is List && nested.any((item) =>
      item is Map && _dnsOnlyMarkers.any(item.containsKey))) {
    return true;
  }
  return fallback == RuleImportKind.dns;
}

/// A list member as strings: sing-box writes arrays, but a single value is accepted too.
List<String> _strings(Object? value) {
  if (value == null) return const [];
  if (value is List) {
    return [for (final item in value) if (_text(item).isNotEmpty) _text(item)];
  }
  final text = _text(value);
  return text.isEmpty ? const [] : [text];
}

/// A scalar member as text; numbers keep their own spelling (`4`, not `4.0`).
String _text(Object? value) => switch (value) {
  null => '',
  final num number => number == number.roundToDouble() ? '${number.toInt()}' : '$number',
  _ => '$value'.trim(),
};
