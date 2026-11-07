import 'package:material_ui/material_ui.dart' as material;
import '../widgets.dart';
import '../components/form.dart';

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

/// Route profiles: the named rule sets a configuration is built with, one of them the global choice.
///
/// The list shows every profile and which one is current; the editor holds the name, the default
/// outbound, the remote subscription and the simple address rules as `prefix:value -> outbound`
/// lines — the same shape the native importer accepts.
class RouteProfilesPage extends StatefulWidget {
  const RouteProfilesPage({super.key});
  @override
  State<RouteProfilesPage> createState() => _RouteProfilesPageState();
}

class _RouteProfilesPageState extends State<RouteProfilesPage> {
  List<Json> _profiles = const [];
  int _currentId = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      // The source reads Room's file over dart:ffi and falls back to
      // `routes.list` over the channel on any failure; the page does not care
      // which one answered.
      final data = json(await context.box.routeProfiles.list());
      if (!mounted) return;
      setState(() {
        _profiles = (data['profiles'] as List? ?? const []).map((item) => json(item)).toList();
        _currentId = (data['currentId'] as num?)?.toInt() ?? 0;
        _loading = false;
      });
    } catch (error) {
      if (mounted) setState(() => _loading = false);
      if (mounted) context.box.report(error);
    }
  }

  Future<void> _open(Json profile) async {
    await openPage(context, RouteEditorPage(id: (profile['id'] as num?)?.toInt() ?? 0));
    if (mounted) await _load();
  }

  /// The official routeprofiles bundles: pick a country and its remote profiles are added,
  /// prefilled from the snapshot and fetched online — the native "Download profiles" flow.
  Future<void> _addPresets() async {
    final box = context.box;
    List<Json> bundles;
    try {
      final data = json(await box.routePresets());
      bundles = (data['bundles'] as List? ?? const []).map((e) => json(e)).toList();
    } catch (error) {
      box.report(error);
      return;
    }
    if (!mounted) return;
    if (bundles.isEmpty) {
      box.report(StateError(context.tr('No official profiles are bundled in this build')));
      return;
    }
    final picked = await showDialog<Json>(context: context, builder: (context) => SimpleDialog(
      title: Text(context.tr('Throne official profiles')),
      children: [
        for (final bundle in bundles)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, bundle),
            child: Text('${bundle['country']} (${((bundle['entries'] as List?) ?? const []).length})'),
          ),
      ],
    ));
    if (picked == null || !mounted) return;
    try {
      final result = json(await box.routeAddPreset(picked['country']));
      final added = (result['added'] as num?)?.toInt() ?? 0;
      if (mounted) {
        showAppBanner(context, '$added ${context.tr('route profiles added')}');
        await _load();
      }
    } catch (error) {
      box.report(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return BoxPage(title: 'Route profiles', children: [
      if (_loading)
        generateSection(items: [ListItem(title: Text(context.tr('Loading')))])
      else ...[
        generateSection(items: [
          for (final profile in _profiles)
            ListItem(
              title: Text(profile['name'].toString().isEmpty ? context.tr('Untitled') : profile['name'].toString()),
              subtitle: Text(_summary(profile)),
              trailing: (profile['id'] as num?)?.toInt() == _currentId
                  ? const GlyphIcon(AppGlyphs.checkCircle)
                  : null,
              onTap: () => _open(profile),
            ),
        ], footer: context.tr('The current profile builds every configuration that has no group override.')),
        generateSection(items: [
          ListItem(
            leading: const GlyphIcon(AppGlyphs.add),
            title: Text(context.tr('Add route profile')),
            onTap: () => _open(const {'id': 0}),
          ),
          ListItem(
            leading: const GlyphIcon(AppGlyphs.cloudDownload),
            title: Text(context.tr('Throne official profiles')),
            onTap: _addPresets,
          ),
        ], footer: context.tr('The official profiles are remote route profiles of the routeprofiles repository.')),
      ],
    ]);
  }

  /// Throne's profile_summary line: "Default: proxy · 3 rules", with the two
  /// markers that mean something here appended (a raw profile is read-only, a
  /// remote one is fetched).
  String _summary(Json profile) {
    final rules = (profile['ruleCount'] as num?)?.toInt() ?? 0;
    final marks = <String>[
      '${context.tr('Default')}: ${profile['defaultOutbound']?.toString() ?? 'direct'}',
      '$rules ${context.tr('rules')}',
      if (profile['isRemote'] == true) context.tr('Remote'),
      if (profile['isRaw'] == true) context.tr('Read-only'),
    ];
    return marks.join(' · ');
  }
}

/// The profile editor. Save rebuilds the simple address rules from the text and leaves every other
/// rule kind in place.
class RouteEditorPage extends StatefulWidget {
  const RouteEditorPage({super.key, required this.id});
  final int id;
  @override
  State<RouteEditorPage> createState() => _RouteEditorPageState();
}

class _RouteEditorPageState extends State<RouteEditorPage> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  String _defaultOutbound = 'direct';
  bool _isRemote = false;
  bool _autoUpdate = false;
  bool _current = false;
  bool _isRaw = false;
  bool _saving = false;
  String? _error;
  String _endpointIds = '';
  List<Json> _rules = const [];

  @override
  void initState() {
    super.initState();
    _name = TextEditingController();
    _url = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final box = context.box;
    try {
      final data = json(await box.routeGet(widget.id));
      // Same source as the list page, so `currentId` agrees whichever path
      // answered (SQLite or the channel fallback).
      final list = json(await box.routeProfiles.list());
      if (!mounted) return;
      setState(() {
        _name.text = data['name']?.toString() ?? '';
        _defaultOutbound = data['defaultOutbound']?.toString() ?? 'direct';
        _isRemote = data['isRemote'] == true;
        _url.text = data['remoteUrl']?.toString() ?? '';
        _autoUpdate = data['autoUpdate'] == true;
        _isRaw = data['isRaw'] == true;
        _endpointIds = (data['endpointIds'] as List? ?? const []).join(', ');
        _current = (list['currentId'] as num?)?.toInt() == widget.id;
      });
      await _loadRules();
    } catch (error) {
      if (mounted) setState(() => _error = BoxController.describe(error));
    }
  }

  Future<void> _loadRules() async {
    if (widget.id == 0) return;
    final box = context.box;
    try {
      final data = json(await box.routeRules(widget.id));
      if (!mounted) return;
      setState(() => _rules = (data['rules'] as List? ?? const []).map((e) => json(e)).toList());
    } catch (error) {
      if (mounted) context.box.report(error);
    }
  }

  Future<void> _editRule(int index) async {
    if (widget.id == 0) {
      context.box.report(StateError(context.tr('Save the profile first')));
      return;
    }
    final added = await openPage<bool>(context, RuleEditorPage(
      profileId: widget.id,
      index: index,
      rule: index < 0 ? const {} : _rules[index],
      rules: _rules,
    ));
    if (added == true && mounted) await _loadRules();
  }

  Future<void> _batchAdd() async {
    if (widget.id == 0) {
      context.box.report(StateError(context.tr('Save the profile first')));
      return;
    }
    final text = await showDialog<String>(context: context, builder: (context) => const _BatchAddDialog());
    if (text == null || text.trim().isEmpty || !mounted) return;
    final box = context.box;
    try {
      await box.routeBatchAddRules(widget.id, text);
      if (mounted) await _loadRules();
    } catch (error) {
      if (mounted) box.report(error);
    }
  }

  /// The Default chain's own rules — one hijack-dns rule that routes DNS. Replaces the list outright.
  Future<void> _resetRules() async {
    if (widget.id == 0) {
      context.box.report(StateError(context.tr('Save the profile first')));
      return;
    }
    final ok = await confirm(context, 'Restore default rules?',
        message: 'The rules become the Default profile\'s own: one hijack-dns rule that routes DNS.',
        action: 'Restore');
    if (!ok || !mounted) return;
    final box = context.box;
    try {
      await box.routeResetRules(widget.id);
      if (mounted) await _loadRules();
    } catch (error) {
      if (mounted) box.report(error);
    }
  }

  Future<void> _save() async {
    setState(() { _saving = true; _error = null; });
    try {
      await context.box.routeSave({
        'id': widget.id,
        'name': _name.text,
        'defaultOutbound': _defaultOutbound,
        'isRemote': _isRemote,
        'remoteUrl': _url.text,
        'autoUpdate': _autoUpdate,
        'endpointIds': _endpointIds.split(',').map((e) => int.tryParse(e.trim())).whereType<int>().toList(),
      });
      if (mounted) context.safeNestedPop();
    } catch (error) {
      if (mounted) setState(() { _saving = false; _error = BoxController.describe(error); });
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(context: context, builder: (context) => material.AlertDialog(
      title: Text(context.tr('Delete route profile?')),
      content: Text(_name.text),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.tr('Cancel'))),
        TextButton(onPressed: () => Navigator.pop(context, true), child: Text(context.tr('Delete'))),
      ],
    ));
    if (confirmed != true || !mounted) return;
    try {
      await context.box.routeDelete(widget.id);
      if (mounted) { context.safeNestedPop(); }
    } catch (error) {
      if (mounted) context.box.report(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FormPage(
      title: widget.id == 0 ? 'Add route profile' : 'Edit',
      saving: _saving,
      onSave: _isRaw ? null : _save,
      error: _error,
      actions: [
        if (widget.id > 0 && !_isRaw)
          IconButtonData(glyph: AppGlyphs.delete, tooltip: 'Delete', onPressed: _delete),
      ],
      children: [
        if (_isRaw) generateSection(items: [
          ListItem(
            leading: const GlyphIcon(AppGlyphs.info),
            title: Text(context.tr('Read-only')),
            subtitle: Text(context.tr('This profile is built in and cannot be changed here.')),
          ),
        ]),
        generateSection(items: [
          FormRow(title: context.tr('Name'), trailing: FormRowTextField(
            controller: _name, hintText: context.tr('Required'),
            autocorrect: false,
          )),
          ListItem(
            title: Text(context.tr('Default outbound')),
            trailing: Text(context.tr(_outboundLabel(_defaultOutbound))),
            onTap: () async {
              final picked = await showDialog<String>(context: context, builder: (context) => SimpleDialog(
                title: Text(context.tr('Default outbound')),
                children: [
                  for (final value in const ['proxy', 'direct', 'block', 'warp-bypass'])
                    SimpleDialogOption(
                      onPressed: () => Navigator.pop(context, value),
                      child: Text(context.tr(_outboundLabel(value))),
                    ),
                ],
              ));
              if (picked != null && mounted) setState(() => _defaultOutbound = picked);
            },
          ),
        ]),
        generateSection(title: context.tr('Remote'), items: [
          ListItem.toggle(
            title: Text(context.tr('Remote profile')),
            value: _isRemote,
            onChanged: (value) => setState(() {
              _isRemote = value;
              if (!value) _autoUpdate = false;
            }),
          ),
          if (_isRemote) FormRow(title: context.tr('URL'), trailing: FormRowTextField(
            controller: _url, hintText: 'https://', keyboardType: TextInputType.text,
            autocorrect: false,
          )),
          if (_isRemote) ListItem.toggle(
            title: Text(context.tr('Auto update')),
            value: _autoUpdate,
            onChanged: (value) => setState(() => _autoUpdate = value),
          ),
        ], footer: context.tr('A remote profile downloads its rules from the URL.')),
        generateSection(title: context.tr('Endpoints'), items: [
          FormRow(title: context.tr('Endpoint ids'), trailing: FormRowTextField(
            initialValue: _endpointIds,
            hintText: '1, 2, 3',
            keyboardType: TextInputType.number,
            autocorrect: false,
            onChanged: (value) => _endpointIds = value,
          )),
        ], footer: context.tr('Profile ids whose endpoints this route can prefer; used by preferred-by rules.')),
        generateSection(title: context.tr('Rules'), items: [
          for (final (index, rule) in _rules.indexed)
            ListItem(
              title: Text(ruleName(rule, index)),
              subtitle: ruleRowSubtitle(context, rule),
              onTap: _isRaw ? null : () => _editRule(index),
            ),
          if (!_isRaw) ListItem(
            leading: const GlyphIcon(AppGlyphs.add),
            title: Text(context.tr('Add rule')),
            onTap: () => _editRule(-1),
          ),
          if (!_isRaw && _rules.length >= 2) ListItem(
            leading: const GlyphIcon(AppGlyphs.sort),
            title: Text(context.tr('Reorder rules')),
            subtitle: Text(context.tr('Drag a rule to change the order; the first match wins')),
            onTap: () async {
              final changed = await openPage<bool>(context, RuleOrderPage(profileId: widget.id, rules: _rules));
              if (changed == true && mounted) await _loadRules();
            },
          ),
          if (!_isRaw) ListItem(
            leading: const GlyphIcon(AppGlyphs.importFile),
            title: Text(context.tr('Batch add simple rules'), style: AppTextStyle.title3.of(context, emphasized: true)),
            onTap: _batchAdd,
          ),
          if (!_isRaw) ListItem(
            leading: const GlyphIcon(AppGlyphs.reset),
            title: Text(context.tr('Restore default rules')),
            onTap: _resetRules,
          ),
        ], footer: _isRaw
            ? context.tr('This profile is built in and cannot be changed here.')
            : context.tr('Rules run top to bottom; the first match wins.')),
        if (widget.id > 0) generateSection(items: [
          ListItem.toggle(
            title: Text(context.tr('Use this profile')),
            value: _current,
            onChanged: (value) async {
              if (!value) return;
              final box = context.box;
              try {
                await box.routeSetCurrent(widget.id);
                if (mounted) setState(() => _current = true);
              } catch (error) {
                if (mounted) box.report(error);
              }
            },
          ),
        ]),
      ],
    );
  }

  String _outboundLabel(String value) => switch (value) {
    'proxy' => 'Proxy',
    'block' => 'Block',
    'warp-bypass' => 'WARP bypass',
    _ => 'Direct',
  };
}

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
    final items = raw is List
        ? raw.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList()
        : (raw?.toString().trim() is String && raw.toString().trim().isNotEmpty
            ? [raw.toString().trim()]
            : const <String>[]);
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
  return Text.rich(
    TextSpan(children: [
      TextSpan(
          text: ruleActionText(rule),
          style: base.copyWith(color: actionColor, fontWeight: FontWeight.w500)),
      TextSpan(
          text: '\n${ruleConditions(context, rule)}',
          style: base.copyWith(fontWeight: FontWeight.normal)),
    ]),
  );
}

/// The rules in drag order. The list *is* the profile's rule order, so a reorder saves the same
/// rules permuted — the bridge stores rules in list order and nothing else changes.
class RuleOrderPage extends StatefulWidget {
  const RuleOrderPage({super.key, required this.profileId, required this.rules});
  final int profileId;
  final List<Json> rules;
  @override
  State<RuleOrderPage> createState() => _RuleOrderPageState();
}

class _RuleOrderPageState extends State<RuleOrderPage> {
  late final List<Json> _rules = List.of(widget.rules);
  bool _saving = false;

  Widget _item(int index) => ReorderableDelayedDragStartListener(
    key: ObjectKey(_rules[index]), index: index,
    child: ItemPositionProvider(position: ItemPosition.get(index, _rules.length),
      child: DecorationListItem(contentPadding: const EdgeInsets.only(left: 16),
        title: Text(ruleName(_rules[index], index)),
        subtitle: ruleRowSubtitle(context, _rules[index]),
        trailing: SortHandle(index: index))),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    title: context.tr('Reorder rules'),
    confirmationAction: IconButtonData(glyph: AppGlyphs.check, tooltip: context.tr('Save'), isLoading: _saving,
      onPressed: _saving ? null : () async {
        setState(() => _saving = true);
        try {
          await context.box.routeSaveRules(widget.profileId, _rules);
          if (context.mounted) context.safeNestedPop(true);
        } catch (error) {
          if (context.mounted) { setState(() => _saving = false); context.box.report(error); }
        }
      }),
    body: AbsorbPointer(absorbing: _saving, child: ReorderableListView.builder(
      buildDefaultDragHandles: false,
      padding: EdgeInsets.fromLTRB(16, context.contentTopPadding, 16, 32 + context.bottomInset),
      itemCount: _rules.length,
      proxyDecorator: (child, index, animation) => commonProxyDecorator(_item(index), index, animation),
      onReorderItem: (old, next) => setState(() => _rules.insert(next, _rules.removeAt(old))),
      itemBuilder: (_, index) => _item(index),
    )),
  );
}

/// One route rule as a form: the match attributes on top, the action fields below, exactly the
/// members the stored [RouteRule] carries. Values of list members are comma-separated text here.
class RuleEditorPage extends StatefulWidget {
  const RuleEditorPage({super.key, required this.profileId, required this.index, required this.rule, required this.rules});
  final int profileId, index;
  final Json rule;
  final List<Json> rules;
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
      final rules = [...widget.rules];
      if (widget.index < 0) {
        rules.add(_rule);
      } else {
        rules[widget.index] = _rule;
      }
      await box.routeSaveRules(widget.profileId, rules);
      if (mounted) context.safeNestedPop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() { _saving = false; _error = BoxController.describe(error); });
    }
  }

  Future<void> _delete() async {
    if (widget.index < 0) { context.safeNestedPop(false); return; }
    final confirmed = await showDialog<bool>(context: context, builder: (context) => material.AlertDialog(
      title: Text(context.tr('Delete rule?')),
      content: Text(_rule['name']?.toString() ?? '#${widget.index + 1}'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.tr('Cancel'))),
        TextButton(onPressed: () => Navigator.pop(context, true), child: Text(context.tr('Delete'))),
      ],
    ));
    if (confirmed != true || !mounted) return;
    final box = context.box;
    try {
      final rules = [...widget.rules]..removeAt(widget.index);
      await box.routeSaveRules(widget.profileId, rules);
      if (mounted) context.safeNestedPop(true);
    } catch (error) {
      if (mounted) box.report(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final outboundId = (_rule['outbound_id'] as num?)?.toInt() ?? -2;
    final typeToken = _rule['type']?.toString() ?? 'custom';
    final isSimple = typeToken.startsWith('simple_');
    final isEndpoint = typeToken == 'endpoint_preferred_by';
    final simpleAction = isSimple ? _actionFromToken(typeToken) : '';
    final simpleKind = isSimple
        ? typeToken.substring('simple_'.length, typeToken.length - simpleAction.length - 1)
        : '';
    final typeLabel = isSimple ? _simpleKindName(simpleKind)
        : isEndpoint ? 'Endpoint preferred by' : 'Custom';
    // A custom rule is the one Throne's full editor describes (Rule + Match +
    // a collapsed Advanced block). Simple and endpoint rules keep their short
    // dedicated layouts.
    final custom = !isSimple && !isEndpoint;
    return FormPage(
      title: widget.index < 0 ? 'Add rule' : 'Edit rule',
      saving: _saving,
      onSave: _save,
      error: _error,
      actions: [
        IconButtonData(glyph: AppGlyphs.delete, tooltip: 'Delete', onPressed: _delete),
      ],
      children: [
        generateSection(title: context.tr('Rule'), items: [
          FormRow(title: context.tr('Name'), trailing: FormRowTextField(
            initialValue: '${_rule['name'] ?? ''}', hintText: context.tr('Optional'),
            autocorrect: false,
            onChanged: (value) => _set('name', value),
          )),
          ListItem.toggle(
            title: Text(context.tr('Disabled')),
            value: _rule['disabled'] == true,
            onChanged: (value) => _set('disabled', value),
          ),
          ListItem(
            title: Text(context.tr('Type')),
            trailing: Text(context.tr(typeLabel)),
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
                _applySimple(picked, simpleAction.isEmpty ? 'proxy' : simpleAction);
              }
            },
          ),
          if (isSimple) ListItem(
            title: Text(context.tr('Target')),
            trailing: Text(context.tr(_simpleActionName(simpleAction))),
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
              if (picked != null) _applySimple(simpleKind, picked);
            },
          ),
          if (!isSimple) ListItem(
            title: Text(context.tr(isEndpoint ? 'Preferred endpoint' : 'Outbound')),
            trailing: Text(_outboundName(outboundId)),
            onTap: () async {
              // The catalog the UI holds is counts-only; the picker asks for the names it shows.
              final List<Json> nodes;
              try {
                nodes = await context.box.groupNodes();
              } catch (error) {
                // A dead service or an old host: report like every other load
                // on this page instead of dying as an uncaught async error.
                if (context.mounted) context.box.report(error);
                return;
              }
              if (!context.mounted) return;
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
          if (custom) ...[
            _actionRow(),
            _enumRow('Reject method', 'reject_method'),
            _enumRow('Strategy', 'strategy'),
            ListItem.toggle(
              title: Text(context.tr('Sniff override destination')),
              value: _rule['sniff_override_dest'] == true,
              onChanged: (value) => _set('sniff_override_dest', value),
            ),
          ],
        ], footer: isSimple
            ? context.tr('Simple rules share one outbound and one action; the match goes in the fields below.')
            : isEndpoint
                ? context.tr('This rule names one endpoint as preferred; it has no match conditions.')
                : null),
        if (!custom && !isEndpoint && (!isSimple || simpleKind == 'address')) generateSection(title: context.tr('Domains'), items: [
          _csvRow('Domain', 'domain'),
          _csvRow('Domain suffix', 'domain_suffix'),
          _csvRow('Domain keyword', 'domain_keyword'),
          _csvRow('Domain regex', 'domain_regex'),
        ]),
        if (!custom && !isEndpoint && (!isSimple || simpleKind == 'address')) generateSection(title: context.tr('IP and ports'), items: [
          _csvRow('IP CIDR', 'ip_cidr'),
          _csvRow('Source IP CIDR', 'source_ip_cidr'),
          _ruleSetRow(),
          _csvRow('Port', 'port'),
          _csvRow('Port range', 'port_range'),
          _csvRow('Source port', 'source_port'),
          _csvRow('Source port range', 'source_port_range'),
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
        if (!custom && !isEndpoint && (!isSimple || simpleKind == 'process_name' || simpleKind == 'process_path'))
          generateSection(title: context.tr('Processes and apps'), items: [
            if (!isSimple || simpleKind == 'process_name') _csvRow('Process name', 'process_name'),
            if (!isSimple || simpleKind == 'process_path') _csvRow('Process path', 'process_path'),
            if (!isSimple) ...[
              _csvRow('Process path regex', 'process_path_regex'),
              _csvRow('Package name', 'package_name'),
              _csvRow('Package name regex', 'package_name_regex'),
            ],
          ]),
        // Throne's native editor shows two basic categories (Rule, Match) and
        // hides the long tail behind "Advanced". Same split here: the fields a
        // rule is usually written with stay visible; everything else folds away
        // until tapped, which is what keeps the page from reading as a wall of
        // rows.
        if (custom) ...[
          generateSection(title: context.tr('Match'), items: [
            _csvRow('Domain suffix', 'domain_suffix'),
            _csvRow('Domain', 'domain'),
            _csvRow('IP CIDR', 'ip_cidr'),
            _ruleSetRow(),
            _csvRow('Package name', 'package_name'),
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
              _csvRow('Domain keyword', 'domain_keyword'),
              _csvRow('Domain regex', 'domain_regex'),
            ]),
            generateSection(title: context.tr('IP and ports'), items: [
              _csvRow('Source IP CIDR', 'source_ip_cidr'),
              _csvRow('Port', 'port'),
              _csvRow('Port range', 'port_range'),
              _csvRow('Source port', 'source_port'),
              _csvRow('Source port range', 'source_port_range'),
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
              _csvRow('Process name', 'process_name'),
              _csvRow('Process path', 'process_path'),
              _csvRow('Process path regex', 'process_path_regex'),
              _csvRow('Package name regex', 'package_name_regex'),
            ]),
            generateSection(title: context.tr('Network'), items: [
              _csvRow('Inbound', 'inbound'),
              _csvRow('Wi-Fi SSID', 'wifi_ssid'),
              _csvRow('Wi-Fi BSSID', 'wifi_bssid'),
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
              _csvRow('Sniffers', 'sniffers'),
            ]),
          ],
        ],
      ],
    );
  }

  Widget _csvRow(String title, String key, {String? hint}) => FormRow(
    title: context.tr(title),
    trailing: FormRowTextField(
      initialValue: _listOf(key).join(', '),
      hintText: hint ?? context.tr('Comma-separated'),
      autocorrect: false,
      onChanged: (value) => _setList(key, value),
    ),
  );

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
      trailing: Text(context.tr(ruleEnumLabel('action', current))),
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
      trailing: Text(context.tr(ruleEnumLabel(key, current))),
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
  Widget build(BuildContext context) => material.AlertDialog(
    title: Text(widget.title, style: AppTextStyle.title3.of(context, emphasized: true)),
    content: Column(mainAxisSize: MainAxisSize.min, children: [
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

/// The batch-add dialog: one simple rule per line, `prefix:value` with an optional `-> target`.
/// The controller lives here so the closing animation is safe (the same rule as the other editors).
class _BatchAddDialog extends StatefulWidget {
  const _BatchAddDialog();
  @override
  State<_BatchAddDialog> createState() => _BatchAddDialogState();
}

class _BatchAddDialogState extends State<_BatchAddDialog> {
  late final TextEditingController _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => material.AlertDialog(
    title: Text(context.tr('Batch add simple rules'), style: AppTextStyle.title3.of(context, emphasized: true)),
    content: SizedBox(
      width: 360,
      child: TextField(
        controller: _text, minLines: 5, maxLines: 10, autocorrect: false,
        keyboardType: TextInputType.multiline,
        decoration: InputDecoration(
          labelText: context.tr('Rules'),
          helperText: context.tr('One rule per line: suffix:example.com -> proxy. Outbounds are proxy, direct, block and warp-bypass.'),
          border: const OutlineInputBorder(),
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Cancel'))),
      TextButton(onPressed: () => Navigator.pop(context, _text.text), child: Text(context.tr('Add'))),
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

  @override Widget build(BuildContext context) => material.AlertDialog(
    title: Text(context.tr('Throne preset rules'), style: AppTextStyle.title3.of(context, emphasized: true)),
    content: SizedBox(
      width: 420, height: 420,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          controller: _values, autocorrect: false,
          minLines: 1, maxLines: 2,
          decoration: InputDecoration(
            labelText: context.tr('Rule set'),
            helperText: context.tr('Comma-separated'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _query, autocorrect: false,
          decoration: InputDecoration(
            labelText: context.tr('Search'),
            border: const OutlineInputBorder(),
            prefixIcon: const GlyphIcon(AppGlyphs.search),
          ),
          onChanged: (_) => _search(),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
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