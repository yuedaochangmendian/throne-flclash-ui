// FlClash-style "add a rule": a rule *type* from a built-in list, one content
// value, and a target. It replaces the 45-column Throne form.
//
// FlClash's AddRuleDialog (views/profiles/override_profile.dart) builds one
// `RuleAction` from an OptionsDialog, types a content string, and picks a
// target from proxy groups + DIRECT/REJECT. Its rules are Clash strings; ours
// are Throne's structured `RouteRule` rows, so each type maps onto the stored
// column that carries the same condition. Types sing-box has no column for are
// marked unsupported rather than silently dropped — a rule that looks saved but
// matches nothing is worse than one the UI refuses to offer.
//
// The dialog answers a Json rule the caller writes through the pool/profile
// save path; it does not write anything itself.

import '../widgets.dart';
import '../components/form.dart';

/// One built-in rule type: the FlClash label and the Throne column it fills.
typedef RuleKind = ({
  String label,
  String? field,
  bool hasContent,
  String? action,
  int? outboundId,
});

/// The 33 FlClash `RuleAction` values, mapped to Throne columns.
///
/// `field == null` with `hasContent == false` is MATCH: a catch-all with no
/// condition. `action`/`outboundId` override the rule's default when the type
/// itself decides where traffic goes.
const List<RuleKind> ruleKinds = [
  (label: 'DOMAIN', field: 'domain', hasContent: true, action: null, outboundId: null),
  (label: 'DOMAIN-SUFFIX', field: 'domain_suffix', hasContent: true, action: null, outboundId: null),
  (label: 'DOMAIN-KEYWORD', field: 'domain_keyword', hasContent: true, action: null, outboundId: null),
  (label: 'DOMAIN-REGEX', field: 'domain_regex', hasContent: true, action: null, outboundId: null),
  (label: 'GEOSITE', field: 'rule_set', hasContent: true, action: null, outboundId: null),
  (label: 'IP-CIDR', field: 'ip_cidr', hasContent: true, action: null, outboundId: null),
  (label: 'IP-CIDR6', field: 'ip_cidr', hasContent: true, action: null, outboundId: null),
  (label: 'IP-SUFFIX', field: 'ip_cidr', hasContent: true, action: null, outboundId: null),
  (label: 'IP-ASN', field: 'rule_set', hasContent: true, action: null, outboundId: null),
  (label: 'GEOIP', field: 'rule_set', hasContent: true, action: null, outboundId: null),
  (label: 'SRC-GEOIP', field: 'source_ip_cidr', hasContent: true, action: null, outboundId: null),
  (label: 'SRC-IP-ASN', field: 'source_ip_cidr', hasContent: true, action: null, outboundId: null),
  (label: 'SRC-IP-CIDR', field: 'source_ip_cidr', hasContent: true, action: null, outboundId: null),
  (label: 'SRC-IP-SUFFIX', field: 'source_ip_cidr', hasContent: true, action: null, outboundId: null),
  (label: 'DST-PORT', field: 'port', hasContent: true, action: null, outboundId: null),
  (label: 'SRC-PORT', field: 'source_port', hasContent: true, action: null, outboundId: null),
  (label: 'IN-PORT', field: 'port', hasContent: true, action: null, outboundId: null),
  (label: 'IN-TYPE', field: 'network', hasContent: true, action: null, outboundId: null),
  (label: 'IN-USER', field: 'inbound', hasContent: true, action: null, outboundId: null),
  (label: 'IN-NAME', field: 'inbound', hasContent: true, action: null, outboundId: null),
  (label: 'PROCESS-PATH', field: 'process_path', hasContent: true, action: null, outboundId: null),
  (label: 'PROCESS-PATH-REGEX', field: 'process_path_regex', hasContent: true, action: null, outboundId: null),
  (label: 'PROCESS-NAME', field: 'process_name', hasContent: true, action: null, outboundId: null),
  (label: 'PROCESS-NAME-REGEX', field: 'process_name_regex', hasContent: true, action: null, outboundId: null),
  (label: 'UID', field: 'package_name', hasContent: true, action: null, outboundId: null),
  (label: 'NETWORK', field: 'network', hasContent: true, action: null, outboundId: null),
  (label: 'DSCP', field: null, hasContent: true, action: null, outboundId: null),
  (label: 'RULE-SET', field: 'rule_set', hasContent: true, action: null, outboundId: null),
  (label: 'AND', field: null, hasContent: false, action: null, outboundId: null),
  (label: 'OR', field: null, hasContent: false, action: null, outboundId: null),
  (label: 'NOT', field: null, hasContent: false, action: null, outboundId: null),
  (label: 'SUB-RULE', field: 'rule_set', hasContent: true, action: null, outboundId: null),
  (label: 'MATCH', field: null, hasContent: false, action: 'route', outboundId: -1),
];

/// Types Throne cannot store are offered in the list but refuse to save, with a
/// reason the user can read. Silently producing a rule that never matches is
/// not an option.
const Set<String> unsupportedRuleKinds = {
  'DSCP', 'AND', 'OR', 'NOT',
};

/// The four fixed targets FlClash's DIRECT/REJECT and Throne's outbound ids share.
const List<(int, String)> ruleTargets = [
  (-1, 'Proxy'),
  (-2, 'Direct'),
  (-3, 'Reject'),
  (-5, 'WARP bypass'),
];

/// Turns the picked type, content and target into a stored rule row.
///
/// Pure so the mapping is testable without a widget. `target` is the outbound
/// id; -3 is a reject action rather than an outbound.
Json buildRuleFromPicker({
  required RuleKind kind,
  required String content,
  required int target,
  String name = '',
}) {
  final rule = <String, Object?>{
    'name': name,
    'type': 'custom',
    'action': target == -3 ? 'reject' : (kind.action ?? 'route'),
    'outbound_id': target == -3 ? -2 : target,
    'disabled': false,
  };
  final field = kind.field;
  if (field != null && kind.hasContent) {
    final values = content
        .split(',')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    rule[field] = values;
  }
  return rule;
}

/// Infers the picked type from an existing rule's first populated condition.
/// Falls back to MATCH for a rule with no condition, which is what that type
/// produces.
RuleKind _kindOf(Json? rule) {
  if (rule == null) return ruleKinds.first;
  for (final kind in ruleKinds) {
    final field = kind.field;
    if (field == null) continue;
    final value = rule[field];
    if (value is List && value.isNotEmpty) return kind;
    if (value is String && value.isNotEmpty) return kind;
  }
  return ruleKinds.singleWhere((kind) => kind.label == 'MATCH');
}

/// The stored condition back into the sheet's comma-separated text field.
String _contentOf(Json? rule, RuleKind kind) {
  if (rule == null || kind.field == null) return '';
  final value = rule[kind.field];
  if (value is List) return value.join(', ');
  return value?.toString() ?? '';
}

/// Shows the add-rule sheet and answers the new rule, or null on dismissal.
///
/// [initial] pre-fills the sheet when editing an existing rule: the type is
/// inferred from the first populated condition column, and the target from
/// `outbound_id`.
Future<Json?> showRulePicker(BuildContext context, {Json? initial}) =>
    showSheet<Json>(
      context: context,
      builder: (sheetContext) => _RulePickerSheet(initial: initial),
    );

class _RulePickerSheet extends StatefulWidget {
  const _RulePickerSheet({this.initial});

  final Json? initial;

  @override
  State<_RulePickerSheet> createState() => _RulePickerSheetState();
}

class _RulePickerSheetState extends State<_RulePickerSheet> {
  late RuleKind _kind = _kindOf(widget.initial);
  late int _target = (widget.initial?['action'] == 'reject')
      ? -3
      : (widget.initial?['outbound_id'] as num?)?.toInt() ?? -1;
  late final TextEditingController _content =
      TextEditingController(text: _contentOf(widget.initial, _kind));
  late final TextEditingController _name =
      TextEditingController(text: '${widget.initial?['name'] ?? ''}');
  String? _error;

  @override
  void dispose() {
    _content.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _pickKind() async {
    final picked = await showOptionSheet<int>(
      context: context,
      title: context.tr('Rule type'),
      options: [
        for (var i = 0; i < ruleKinds.length; i++) (i, ruleKinds[i].label),
      ],
      selected: ruleKinds.indexOf(_kind),
    );
    if (picked != null && mounted) setState(() => _kind = ruleKinds[picked]);
  }

  Future<void> _pickTarget(List<Json> nodes) async {
    final picked = await showOptionSheet<int>(
      context: context,
      title: context.tr('Target'),
      options: [
        for (final (id, label) in ruleTargets) (id, label),
        for (final node in nodes)
          ((node['id'] as num?)?.toInt() ?? 0, '${node['tag']}'),
      ],
      selected: _target,
    );
    if (picked != null && mounted) setState(() => _target = picked);
  }

  void _save() {
    if (unsupportedRuleKinds.contains(_kind.label)) {
      setState(() => _error = context.tr('This rule type is not supported'));
      return;
    }
    if (_kind.hasContent && _content.text.trim().isEmpty) {
      setState(() => _error = context.tr('Content is required'));
      return;
    }
    final rule = buildRuleFromPicker(
      kind: _kind,
      content: _content.text,
      target: _target,
      name: _name.text.trim(),
    );
    Navigator.pop(context, rule);
  }

  @override
  Widget build(BuildContext context) {
    final box = context.box;
    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.fromLTRB(16, context.sectionsTopPadding, 16, 24 + context.bottomInset),
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_error!, style: context.listCaptionStyle.copyWith(color: context.colorScheme.error)),
          ),
        generateSection(title: context.tr('Add rule'), items: [
          ListItem(
            title: Text(context.tr('Name')),
            subtitle: Text(context.tr('Optional')),
            trailing: SizedBox(
              width: 180,
              child: FormRowTextField(controller: _name, hintText: context.tr('Optional'), autocorrect: false),
            ),
          ),
          ListItem(
            title: Text(context.tr('Rule type')),
            subtitle: Text(_kind.label),
            onTap: _pickKind,
          ),
          if (_kind.hasContent)
            ListItem(
              title: Text(context.tr('Content')),
              subtitle: Text(context.tr('Comma-separated')),
              trailing: SizedBox(
                width: 180,
                child: FormRowTextField(controller: _content, hintText: _kind.label, autocorrect: false),
              ),
            ),
          ListItem(
            title: Text(context.tr('Target')),
            subtitle: Text(ruleTargets.where((t) => t.$1 == _target).firstOrNull?.$2 ?? '#$_target'),
            onTap: () async {
              List<Json> nodes;
              try {
                nodes = await box.groupNodes();
              } catch (_) {
                nodes = const [];
              }
              if (mounted) await _pickTarget(nodes);
            },
          ),
        ]),
        const SizedBox(height: 8),
        generateSection(items: [
          ListItem(
            title: Text(context.tr('Add rule')),
            leading: const GlyphIcon(AppGlyphs.add),
            onTap: _save,
          ),
        ]),
      ],
    );
  }
}
