// One route rule as a form: the match attributes on top, the action fields
// below, exactly the members the stored Rule carries.

import '../widgets.dart';
import '../components/form.dart';

/// One route rule as a form: the match attributes on top, the action fields below, exactly the
/// members the stored [RouteRule] carries. Values of list members are comma-separated text here.
class RuleEditorPage extends StatefulWidget {
  const RuleEditorPage({super.key, required this.profileId, required this.index, required this.rule, required this.rules, this.pool = false});
  final int profileId, index;
  final Json rule;
  final List<Json> rules;
  /// When true the rule is one of the shared global pool, saved with
  /// [BoxController.routeSaveGlobalRules] instead of a profile's own rules.
  final bool pool;
  @override
  State<RuleEditorPage> createState() => _RuleEditorPageState();
}

class _RuleEditorPageState extends State<RuleEditorPage> {
  late Json _rule;
  bool _saving = false;
  /// Whether the Advanced block is expanded. Collapsed by default so a custom
  /// rule opens on Throne's two basic categories (Rule + Match), the way the
  /// native editor hides `advancedCategory` behind `advancedToggle`.
  bool _advancedOpen = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _rule = {
      ...widget.rule,
      if (widget.index < 0) 'name': '',
      if (widget.index < 0) 'type': 'custom',
      if (widget.index < 0) 'action': 'route',
      if (widget.index < 0) 'outbound_id': -2,
    };
  }

  void _set(String key, Object? value) => setState(() => _rule = {..._rule, key: value});

  /// A rule field as display strings. The bridge emits list fields as lists and scalar fields as
  /// strings; a scalar reaching a list row must not take the whole editor down with a cast error,
  /// so anything non-list renders as its single value.
  List<String> _listOf(String key) {
    final value = _rule[key];
    if (value == null) return const [];
    if (value is List) return value.map((e) => '$e').toList();
    final text = '$value';
    return text.isEmpty ? const [] : [text];
  }

  void _setList(String key, String text) => _set(key, text
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList());

  Future<void> _save() async {
    setState(() { _saving = true; _error = null; });
    final box = context.box;
    try {
      // A rule that matches Wi-Fi needs the location walk-through (RouteRuleActivity.finishWith
      // ran it before completing the save); a refusal leaves the rules inactive but the save stands.
      final usesWifi = _listOf('wifi_ssid').any((v) => v.trim().isNotEmpty)
          || _listOf('wifi_bssid').any((v) => v.trim().isNotEmpty);
      if (usesWifi && !box.remote) await box.wifiPermissionsEnsure();
      if (widget.pool) {
        // The global pool is edited as a whole list; re-emit it with this rule
        // in place so the host replaces the pool in list order.
        final rules = [...widget.rules];
        if (widget.index < 0) {
          rules.add(_rule);
        } else {
          rules[widget.index] = _rule;
        }
        final saved = json(await box.routeSaveGlobalRules(rules));
        if (mounted) context.safeNestedPop(saved);
        return;
      }
      final rules = [...widget.rules];
      if (widget.index < 0) {
        rules.add(_rule);
      } else {
        rules[widget.index] = _rule;
      }
      final saved = json(await box.routeSaveRules(widget.profileId, rules));
      if (mounted) context.safeNestedPop(saved);
    } catch (error) {
      if (!mounted) return;
      setState(() { _saving = false; _error = BoxController.describe(error); });
    }
  }

  Future<void> _delete() async {
    if (widget.pool) {
      // The pool rule has a stable id; drop it directly rather than rewriting
      // the whole pool, which would renumber every other rule's id.
      final id = (widget.rule['id'] as num?)?.toInt();
      if (id == null) { context.safeNestedPop(false); return; }
      final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
        title: context.tr('Delete rule?'),
        child: Text(_rule['name']?.toString() ?? '#${widget.index + 1}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.tr('Cancel'))),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(context.tr('Delete'))),
        ],
      ));
      if (confirmed != true || !mounted) return;
      final box = context.box;
      try {
        await box.routeDeleteGlobalRule(id);
        if (mounted) context.safeNestedPop(true);
      } catch (error) {
        if (mounted) box.report(error);
      }
      return;
    }
    if (widget.index < 0) { context.safeNestedPop(false); return; }
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: context.tr('Delete rule?'),
      child: Text(_rule['name']?.toString() ?? '#${widget.index + 1}'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.tr('Cancel'))),
        TextButton(onPressed: () => Navigator.pop(context, true), child: Text(context.tr('Delete'))),
      ],
    ));
    if (confirmed != true || !mounted) return;
    final box = context.box;
    try {
      final rules = [...widget.rules]..removeAt(widget.index);
      final saved = json(await box.routeSaveRules(widget.profileId, rules));
      if (mounted) context.safeNestedPop(saved);
    } catch (error) {
      if (mounted) box.report(error);
    }
  }

  // --- rule shape ---------------------------------------------------------
  //
  // One rule is one of three layouts: custom (Throne's full editor), a simple
  // rule (address / process_name / process_path), or an endpoint preference.
  // The layout decides which sections the page builds, so the flags live in
  // getters instead of being threaded through every builder.

  String get _typeToken => _rule['type']?.toString() ?? 'custom';

  bool get _isSimple => _typeToken.startsWith('simple_');

  bool get _isEndpoint => _typeToken == 'endpoint_preferred_by';

  /// A custom rule is the one Throne's full editor describes (Rule + Match +
  /// a collapsed Advanced block). Simple and endpoint rules keep their short
  /// dedicated layouts.
  bool get _isCustom => !_isSimple && !_isEndpoint;

  String get _simpleAction => _isSimple ? _actionFromToken(_typeToken) : '';

  String get _simpleKind => _isSimple
      ? _typeToken.substring('simple_'.length, _typeToken.length - _simpleAction.length - 1)
      : '';

  String get _typeLabel => _isSimple
      ? _simpleKindName(_simpleKind)
      : _isEndpoint ? 'Endpoint preferred by' : 'Custom';

  @override
  Widget build(BuildContext context) => BoxPage(
      title: widget.index < 0 ? 'Add rule' : 'Edit rule',
      confirmationAction: IconButtonData(glyph: AppGlyphs.check, tooltip: context.tr('Save'), isLoading: _saving, onPressed: _saving ? null : _save),
      actions: [
      IconButtonData(glyph: AppGlyphs.delete, tooltip: 'Delete', onPressed: _delete),
    ],
      error: _error,
      loading: _saving,
      absorbing: _saving,
      children: [
      _ruleSection(),
      ..._simpleSections(),
      ..._customSections(),
    ],
    );

  /// Throne's "Rule" category: name, state, type and target, then — for a
  /// custom rule — the action fields, which decide what the rule does rather
  /// than which detail it matches on.
  Widget _ruleSection() {
    final outboundId = (_rule['outbound_id'] as num?)?.toInt() ?? -2;
    return generateSection(title: context.tr('Rule'), items: [
      FormRow(title: context.tr('Name'), trailing: FormRowTextField(
        initialValue: '${_rule['name'] ?? ''}', hintText: context.tr('Optional'),
        autocorrect: false,
        onChanged: (value) => _set('name', value),
      )),
      ListItem.toggle(
        title: Text(context.tr('Enabled')),
        subtitle: Text(context.tr(_rule['disabled'] == true ? 'Disabled' : 'Enabled')),
        value: _rule['disabled'] != true,
        onChanged: (value) => _set('disabled', !value),
      ),
      ListItem(
        title: Text(context.tr('Type')),
        trailing: Text(context.tr(_typeLabel), style: context.listValueStyle),
        onTap: () async {
          final picked = await showDialog<String>(context: context, builder: (context) => SimpleDialog(
            title: _dialogTitle(context, 'Type'),
            children: [
              for (final (value, label) in [
                ('custom', 'Custom'), ('address', 'Simple address'),
                ('process_name', 'Simple process name'), ('process_path', 'Simple process path'),
                ('endpoint_preferred_by', 'Endpoint preferred by'),
              ])
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, value),
                  child: _optionText(context, label),
                ),
            ],
          ));
          if (picked == null) return;
          if (picked == 'custom' || picked == 'endpoint_preferred_by') {
            setState(() => _rule = {..._rule, 'type': picked});
          } else {
            _applySimple(picked, _simpleAction.isEmpty ? 'proxy' : _simpleAction);
          }
        },
      ),
      if (_isSimple) ListItem(
        title: Text(context.tr('Target')),
        trailing: Text(context.tr(_simpleActionName(_simpleAction)), style: context.listValueStyle),
        onTap: () async {
          final picked = await showDialog<String>(context: context, builder: (context) => SimpleDialog(
            title: _dialogTitle(context, 'Target'),
            children: [
              for (final value in const ['proxy', 'bypass', 'block', 'warp_bypass'])
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, value),
                  child: _optionText(context, _simpleActionName(value)),
                ),
            ],
          ));
          if (picked != null) _applySimple(_simpleKind, picked);
        },
      ),
      if (!_isSimple) ListItem(
        title: Text(context.tr(_isEndpoint ? 'Preferred endpoint' : 'Outbound')),
        trailing: Text(_outboundName(outboundId), style: context.listValueStyle),
        onTap: () async {
          // The catalog the UI holds is counts-only; the picker asks for the names it shows.
          final List<Json> nodes;
          try {
            nodes = await context.box.groupNodes();
          } catch (error) {
            // A dead service or an old host: report like every other load
            // on this page instead of dying as an uncaught async error.
            if (mounted) context.box.report(error);
            return;
          }
          if (!mounted) return;
          final picked = await showDialog<int>(
            context: context,
            builder: (context) => _outboundDialog(context, nodes),
          );
          if (picked != null) _set('outbound_id', picked);
        },
      ),
      // Throne's "Rule" category also carries action / reject method /
      // strategy / override destination. They stay up top because they
      // decide what the rule does, not which detail it matches on.
      if (_isCustom) ...[
        _actionRow(),
        _enumRow('Reject method', 'reject_method'),
        _enumRow('Strategy', 'strategy'),
        ListItem.toggle(
          title: Text(context.tr('Sniff override destination')),
          value: _rule['sniff_override_dest'] == true,
          onChanged: (value) => _set('sniff_override_dest', value),
        ),
      ],
    ], footer: _isSimple
        ? context.tr('Simple rules share one outbound and one action; the match goes in the fields below.')
        : _isEndpoint
            ? context.tr('This rule names one endpoint as preferred; it has no match conditions.')
            : null);
  }

  /// The three match sections a simple or endpoint rule keeps visible: their
  /// own fields only, with no Advanced fold.
  List<Widget> _simpleSections() {
    if (_isCustom || _isEndpoint) return const [];
    final address = !_isSimple || _simpleKind == 'address';
    final process = !_isSimple || _simpleKind == 'process_name' || _simpleKind == 'process_path';
    return [
      if (address) generateSection(title: context.tr('Domains'), items: [
        _valuesRow('Domain', 'domain'),
        _valuesRow('Domain suffix', 'domain_suffix'),
        _valuesRow('Domain keyword', 'domain_keyword'),
        _valuesRow('Domain regex', 'domain_regex'),
      ]),
      if (address) generateSection(title: context.tr('IP and ports'), items: [
        _valuesRow('IP CIDR', 'ip_cidr'),
        _valuesRow('Source IP CIDR', 'source_ip_cidr'),
        _ruleSetRow(),
        _valuesRow('Port', 'port'),
        _valuesRow('Port range', 'port_range'),
        _valuesRow('Source port', 'source_port'),
        _valuesRow('Source port range', 'source_port_range'),
        ListItem.toggle(
          title: Text(context.tr('Source IP is private')),
          value: _rule['source_ip_is_private'] == true,
          onChanged: (value) => _set('source_ip_is_private', value),
        ),
        ListItem.toggle(
          title: Text(context.tr('IP is private')),
          value: _rule['ip_is_private'] == true,
          onChanged: (value) => _set('ip_is_private', value),
        ),
      ]),
      if (process)
        generateSection(title: context.tr('Processes and apps'), items: [
          if (!_isSimple || _simpleKind == 'process_name') _valuesRow('Process name', 'process_name'),
          if (!_isSimple || _simpleKind == 'process_path') _valuesRow('Process path', 'process_path'),
          if (!_isSimple) ...[
            _valuesRow('Process path regex', 'process_path_regex'),
            _valuesRow('Package name', 'package_name'),
            _valuesRow('Package name regex', 'package_name_regex'),
          ],
        ]),
    ];
  }

  // Throne's native editor shows two basic categories (Rule, Match) and hides
  // the long tail behind "Advanced". Same split here: the fields a rule is
  // usually written with stay visible; everything else folds away until
  // tapped, which is what keeps the page from reading as a wall of rows.
  List<Widget> _customSections() {
    if (!_isCustom) return const [];
    return [
      generateSection(title: context.tr('Match'), items: [
        _valuesRow('Domain suffix', 'domain_suffix'),
        _valuesRow('Domain', 'domain'),
        _valuesRow('IP CIDR', 'ip_cidr'),
        _ruleSetRow(),
        _valuesRow('Package name', 'package_name'),
        _networkTypeRow(),
      ]),
      generateSection(items: [
        ListItem(
          title: Text(context.tr('Advanced')),
          trailing: GlyphIcon(_advancedOpen ? AppGlyphs.chevronUp : AppGlyphs.chevronDown),
          onTap: () => setState(() => _advancedOpen = !_advancedOpen),
        ),
      ]),
      if (_advancedOpen) ...[
        generateSection(title: context.tr('Domains'), items: [
          _valuesRow('Domain keyword', 'domain_keyword'),
          _valuesRow('Domain regex', 'domain_regex'),
        ]),
        generateSection(title: context.tr('IP and ports'), items: [
          _valuesRow('Source IP CIDR', 'source_ip_cidr'),
          _valuesRow('Port', 'port'),
          _valuesRow('Port range', 'port_range'),
          _valuesRow('Source port', 'source_port'),
          _valuesRow('Source port range', 'source_port_range'),
          ListItem.toggle(
            title: Text(context.tr('IP is private')),
            value: _rule['ip_is_private'] == true,
            onChanged: (value) => _set('ip_is_private', value),
          ),
          ListItem.toggle(
            title: Text(context.tr('Source IP is private')),
            value: _rule['source_ip_is_private'] == true,
            onChanged: (value) => _set('source_ip_is_private', value),
          ),
        ]),
        generateSection(title: context.tr('Processes and apps'), items: [
          _valuesRow('Process name', 'process_name'),
          _valuesRow('Process path', 'process_path'),
          _valuesRow('Process path regex', 'process_path_regex'),
          _valuesRow('Package name regex', 'package_name_regex'),
        ]),
        generateSection(title: context.tr('Network'), items: [
          _valuesRow('Inbound', 'inbound'),
          _valuesRow('Wi-Fi SSID', 'wifi_ssid'),
          _valuesRow('Wi-Fi BSSID', 'wifi_bssid'),
          _enumRow('IP version', 'ip_version'),
          _enumRow('Network', 'network'),
          _enumRow('Protocol', 'protocol'),
          ListItem.toggle(
            title: Text(context.tr('Network is expensive')),
            value: _rule['network_is_expensive'] == true,
            onChanged: (value) => _set('network_is_expensive', value),
          ),
          ListItem.toggle(
            title: Text(context.tr('Invert the match')),
            value: _rule['invert'] == true,
            onChanged: (value) => _set('invert', value),
          ),
        ]),
        generateSection(title: context.tr('Action'), items: [
          ListItem.toggle(
            title: Text(context.tr('No drop')),
            value: _rule['no_drop'] == true,
            onChanged: (value) => _set('no_drop', value),
          ),
          _textRow('Override address', 'override_address'),
          _textRow('Override port', 'override_port'),
          ListItem.toggle(
            title: Text(context.tr('TLS fragment')),
            value: _rule['tls_fragment'] == true,
            onChanged: (value) => _set('tls_fragment', value),
          ),
          _textRow('TLS fragment fallback delay', 'tls_fragment_fallback_delay'),
          ListItem.toggle(
            title: Text(context.tr('TLS record fragment')),
            value: _rule['tls_record_fragment'] == true,
            onChanged: (value) => _set('tls_record_fragment', value),
          ),
          _textRow('TLS spoof', 'tls_spoof'),
          _textRow('TLS spoof method', 'tls_spoof_method'),
          _valuesRow('Sniffers', 'sniffers'),
        ]),
      ],
    ];
  }

  /// A list member as a row that opens the per-line editor, the way Throne for Android's
  /// `RouteRuleActivity` edits its list preferences: the row shows what is set (or "Not set"),
  /// and the dialog takes one value per line instead of a comma-joined single line.
  Widget _valuesRow(String title, String key) {
    final values = _listOf(key);
    return ListItem(
      title: Text(context.tr(title)),
      subtitle: Text(
        values.isEmpty ? context.tr('Not set') : values.join(', '),
        maxLines: 1, overflow: TextOverflow.ellipsis,
      ),
      onTap: () async {
        final saved = await showDialog<String>(
          context: context,
          builder: (context) => _RuleValuesDialog(
            title: context.tr(title),
            hint: ruleFieldHint(context, key),
            initial: values.join('\n'),
          ),
        );
        if (saved == null) return;
        _set(key, saved.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty).toList());
      },
    );
  }

  /// sing-box's network types as a multi-choice, the way the native rule editor offers them
  /// (RouteRuleActivity's multi-choice dialog over route_rule_network_type_entries); the empty
  /// selection means the condition does not narrow the match, as upstream.
  Widget _networkTypeRow() {
    const options = ['wifi', 'cellular', 'ethernet', 'other'];
    final current = _listOf('network_type');
    return ListItem(
      title: Text(context.tr('Network type')),
      subtitle: Text(current.isEmpty ? context.tr('Any') : current.map(_networkTypeName).join(', ')),
      onTap: () async {
        final picked = await showDialog<Set<String>>(
          context: context,
          builder: (context) => _MultiChoiceDialog(
            title: context.tr('Network type'), options: options, initial: current.toSet(),
          ),
        );
        if (picked != null) _setList('network_type', options.where(picked.contains).join(','));
      },
    );
  }

  /// The rule-set row opens the picker over Throne's preset rule sets (the routeprofiles srslist),
  /// which keeps hand-typed entries in the same field — the native picker's contract.
  Widget _ruleSetRow() {
    final current = _listOf('rule_set');
    return ListItem(
      title: Text(context.tr('Rule set')),
      subtitle: Text(current.isEmpty ? context.tr('Comma-separated') : current.join(', ')),
      onTap: () async {
        final box = context.box;
        final value = await showDialog<String>(
          context: context,
          builder: (context) => _RuleSetDialog(box: box, initial: current),
        );
        if (value != null) _setList('rule_set', value);
      },
    );
  }

  Widget _textRow(String title, String key, {String? hint}) => FormRow(
    title: context.tr(title),
    trailing: FormRowTextField(
      initialValue: '${_rule[key] ?? ''}',
      hintText: hint,
      autocorrect: false,
      onChanged: (value) => _set(key, value),
    ),
  );

  /// Dialogs on this page use the app's own type scale. Material's defaults
  /// (a 24sp title over 14sp options) sat next to ListItem rows set in
  /// AppTextStyle, so the popups read as a different app; title and options are
  /// pinned here instead.
  Widget _dialogTitle(BuildContext context, String title) =>
      Text(context.tr(title), style: AppTextStyle.title3.of(context, emphasized: true));

  Text _optionText(BuildContext context, String text, {bool translate = true}) =>
      Text(translate ? context.tr(text) : text, style: AppTextStyle.body.of(context));

  /// The action field, kept as a menu (Throne's `action` SimpleMenuPreference).
  /// The stored value is the label here, so the row and the dialog agree.
  Widget _actionRow() {
    final current = _rule['action']?.toString() ?? 'route';
    return ListItem(
      title: Text(context.tr('Action')),
      trailing: Text(context.tr(ruleEnumLabel('action', current)), style: context.listValueStyle),
      onTap: () async {
        final picked = await showDialog<String>(
          context: context,
          builder: (context) => SimpleDialog(
            title: _dialogTitle(context, 'Action'),
            children: [
              for (final option in ruleEnumOptions('action', current))
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, option.value),
                  child: _optionText(context, option.label),
                ),
            ],
          ),
        );
        if (picked != null) setState(() => _rule = ruleEnumApply(_rule, 'action', picked));
      },
    );
  }

  /// A scalar field with a fixed set of legal values, shown as a menu the way
  /// Throne for Android's `SimpleMenuPreference` does. The first (empty) option
  /// clears the field. An unknown stored value is appended by [ruleEnumOptions]
  /// so an old rule opened and saved unchanged keeps its value (ensureValue).
  Widget _enumRow(String title, String key) {
    final current = _rule[key]?.toString() ?? '';
    final options = ruleEnumOptions(key, current);
    return ListItem(
      title: Text(context.tr(title)),
      trailing: Text(context.tr(ruleEnumLabel(key, current)), style: context.listValueStyle),
      onTap: () async {
        final picked = await showDialog<String>(
          context: context,
          builder: (context) => SimpleDialog(
            title: _dialogTitle(context, title),
            children: [
              for (final option in options)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, option.value),
                  child: _optionText(context, option.label),
                ),
            ],
          ),
        );
        if (picked != null) setState(() => _rule = ruleEnumApply(_rule, key, picked));
      },
    );
  }

  String _outboundName(int id) => switch (id) {
    -1 => 'Proxy',
    -3 => 'Block',
    -5 => 'WARP bypass',
    -2 => 'Direct',
    > 0 => '#$id',
    _ => '$id',
  };

  /// The action suffix of a simple token (`warp_bypass` contains an underscore, so match longest first).
  static String _actionFromToken(String token) {
    for (final action in const ['warp_bypass', 'proxy', 'bypass', 'block']) {
      if (token.endsWith('_$action')) return action;
    }
    return '';
  }

  /// A simple rule's kind is its match and its action its fixed target: `simple_<kind>_<action>`.
  /// Block rejects (action=reject, outbound BLOCK); the rest route with the matching outbound.
  void _applySimple(String kind, String action) {
    final token = 'simple_${kind}_$action';
    final isBlock = action == 'block';
    setState(() => _rule = {
      ..._rule,
      'type': token,
      'action': isBlock ? 'reject' : 'route',
      'outbound_id': switch (action) {
        'proxy' => -1, 'bypass' => -2, 'warp_bypass' => -5, _ => -3,
      },
    });
  }

  String _simpleKindName(String kind) => switch (kind) {
    'address' => 'Simple address',
    'process_name' => 'Simple process name',
    'process_path' => 'Simple process path',
    _ => 'Custom',
  };

  String _simpleActionName(String action) => switch (action) {
    'proxy' => 'Proxy',
    'bypass' => 'Direct',
    'block' => 'Block',
    'warp_bypass' => 'WARP bypass',
    _ => 'Proxy',
  };

  Widget _outboundDialog(BuildContext context, List<Json> nodes) {
    return SimpleDialog(
      title: _dialogTitle(context, 'Outbound'),
      children: [
        for (final (id, label) in [(-1, 'Proxy'), (-2, 'Direct'), (-3, 'Block'), (-5, 'WARP bypass')])
          SimpleDialogOption(onPressed: () => Navigator.pop(context, id), child: _optionText(context, label)),
        for (final node in nodes)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, (node['id'] as num?)?.toInt()),
            child: _optionText(context, '${node['tag']}', translate: false),
          ),
      ],
    );
  }
}

String _networkTypeName(String value) => switch (value) {
  'wifi' => 'Wi-Fi', 'cellular' => 'Cellular', 'ethernet' => 'Ethernet', _ => 'Other',
};

/// The per-line editor of one list member, the dialog Throne for Android's rule editor opens for
/// its list preferences: a hint saying what one line is, then one value per line. The controller
/// lives here so the closing animation is safe (the same rule as the other editors).
class _RuleValuesDialog extends StatefulWidget {
  const _RuleValuesDialog({required this.title, required this.initial, this.hint});
  final String title, initial;
  final String? hint;
  @override State<_RuleValuesDialog> createState() => _RuleValuesDialogState();
}

class _RuleValuesDialogState extends State<_RuleValuesDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: widget.title,
    child: SizedBox(
      width: 360,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (widget.hint != null) Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(widget.hint!, style: AppTextStyle.caption1.of(context)),
        ),
        TextField(
          controller: _controller, minLines: 4, maxLines: 10, autocorrect: false,
          keyboardType: TextInputType.multiline,
          decoration: const InputDecoration(border: AppShape.input),
        ),
      ]),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Cancel'))),
      TextButton(onPressed: () => Navigator.pop(context, _controller.text), child: Text(context.tr('OK'))),
    ],
  );
}

/// A multi-choice dialog over a fixed option set; the answer is the selected subset.
class _MultiChoiceDialog extends StatefulWidget {
  const _MultiChoiceDialog({required this.title, required this.options, required this.initial});
  final String title;
  final List<String> options;
  final Set<String> initial;
  @override
  State<_MultiChoiceDialog> createState() => _MultiChoiceDialogState();
}

class _MultiChoiceDialogState extends State<_MultiChoiceDialog> {
  late final _selected = widget.initial.toSet();

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: widget.title,
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      for (final option in widget.options)
        ListItem.checkbox(
          value: _selected.contains(option),
          title: Text(context.tr(_networkTypeName(option))),
          onChanged: (value) => setState(() {
            if (value == true) { _selected.add(option); } else { _selected.remove(option); }
          }),
        ),
    ]),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Cancel'))),
      TextButton(onPressed: () => Navigator.pop(context, _selected), child: Text(context.tr('Save'))),
    ],
  );
}

/// Throne's preset rule sets (the routeprofiles srslist) over the rule's own list: search the
/// catalog, tick what belongs in the rule, and hand-typed entries in the field above survive —
/// the same contract as the native multi-select picker (unknown entries stay selected).
class _RuleSetDialog extends StatefulWidget {
  const _RuleSetDialog({required this.box, required this.initial});
  final BoxController box;
  final List<String> initial;
  @override State<_RuleSetDialog> createState() => _RuleSetDialogState();
}

class _RuleSetDialogState extends State<_RuleSetDialog> {
  late final TextEditingController _values = TextEditingController(text: widget.initial.join(', '));
  late final TextEditingController _query = TextEditingController();
  List<Json> _entries = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _values.dispose();
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() => _loading = true);
    try {
      final wire = json(await widget.box.routeRuleSets(_query.text, 200));
      if (mounted) setState(() { _entries = rows(wire['entries']); _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Set<String> get _selected =>
      _values.text.split(',').map((value) => value.trim()).where((value) => value.isNotEmpty).toSet();

  void _toggle(String name) {
    final selected = _selected;
    if (!selected.remove(name)) selected.add(name);
    setState(() => _values.text = selected.join(', '));
  }

  @override Widget build(BuildContext context) => AlertDialog(
    title: context.tr('Throne preset rules'),
    child: SizedBox(
      width: 420, height: 420,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          controller: _values, autocorrect: false,
          minLines: 1, maxLines: 2,
          decoration: InputDecoration(
            hintText: context.tr('Rule set'),
            helperText: context.tr('Comma-separated'),
            border: AppShape.input,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _query, autocorrect: false,
          decoration: InputDecoration(
            hintText: context.tr('Search'),
            border: AppShape.input,
            prefixIcon: const GlyphIcon(AppGlyphs.search),
          ),
          onChanged: (_) => _search(),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _loading
              ? const Center(child: ActivityIndicator())
              : _entries.isEmpty
                  ? Center(child: Text(context.tr('No results')))
                  : ListView(children: [
                      for (final entry in _entries)
                        CheckboxListTile(
                          dense: true,
                          value: _selected.contains('${entry['name']}'),
                          title: Text('${entry['name']}'),
                          onChanged: (_) => _toggle('${entry['name']}'),
                        ),
                    ]),
        ),
      ]),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Cancel'))),
      TextButton(onPressed: () => Navigator.pop(context, _values.text), child: Text(context.tr('Save'))),
    ],
  );
}
