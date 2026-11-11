// A route profile as FlClash's override screen (覆写 / ExtendView).
//
// FlClash keeps a profile's own rules on their own screen and offers, on the
// profile card, the few global controls that apply to it: the match target
// (the default outbound a rule without one falls back to), the shared global
// rules with per-profile on/off switches, and the entry to its own rules. This
// is that screen.

import '../widgets.dart';
import '../components/form.dart';

/// The four built-in match targets, as FlClash exposes them — not arbitrary
/// proxy groups or nodes. A rule whose action is `route` with no explicit
/// outbound takes this one.
const matchTargets = <(String, String)>[
  ('proxy', 'Proxy'),
  ('direct', 'Direct'),
  ('block', 'Block'),
  ('warp-bypass', 'WARP bypass'),
];

class RouteOverridePage extends StatefulWidget {
  const RouteOverridePage({super.key, required this.id, this.name = ''});

  final int id;
  final String name;

  @override
  State<RouteOverridePage> createState() => _RouteOverridePageState();
}

class _RouteOverridePageState extends State<RouteOverridePage> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  String _defaultOutbound = 'direct';
  bool _current = false;
  bool _isRaw = false;
  bool _isRemote = false;
  bool _autoUpdate = false;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  /// Pool rules with this profile's on/off state, for the per-profile switches.
  List<Json> _globalRules = const [];
  final Set<int> _disabled = {};

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.name);
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
      final list = json(await box.routeProfiles.list());
      final globals = json(await box.routeGlobalRules(widget.id));
      if (!mounted) return;
      setState(() {
        _defaultOutbound = data['defaultOutbound']?.toString() ?? 'direct';
        _isRaw = data['isRaw'] == true;
        _isRemote = data['isRemote'] == true;
        _url.text = data['remoteUrl']?.toString() ?? '';
        _autoUpdate = data['autoUpdate'] == true;
        _current = (list['currentId'] as num?)?.toInt() == widget.id;
        _globalRules = rows(globals['rules']);
        _disabled.clear();
        for (final rule in _globalRules) {
          if (rule['enabled'] != true) {
            final id = (rule['id'] as num?)?.toInt();
            if (id != null) _disabled.add(id);
          }
        }
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = BoxController.describe(error);
        _loading = false;
      });
    }
  }

  Future<void> _setTarget(String value) async {
    setState(() => _defaultOutbound = value);
    await _save();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await context.box.routeSave({
        'id': widget.id,
        'name': _name.text,
        'defaultOutbound': _defaultOutbound,
        'isRemote': _isRemote,
        'remoteUrl': _url.text,
        'autoUpdate': _autoUpdate,
      });
      if (mounted) setState(() => _saving = false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = BoxController.describe(error);
        });
      }
    }
  }

  Future<void> _setCurrent(bool value) async {
    if (!value) return;
    final box = context.box;
    try {
      await box.routeSetCurrent(widget.id);
      if (mounted) setState(() => _current = true);
    } catch (error) {
      if (mounted) box.report(error);
    }
  }

  Future<void> _toggleGlobal(int id, bool enabled) async {
    if (enabled) {
      _disabled.remove(id);
    } else {
      _disabled.add(id);
    }
    setState(() {});
    final box = context.box;
    try {
      await box.routeSetGlobalRuleDisabled(widget.id, _disabled.toList());
    } catch (error) {
      // Roll back the optimistic flip on failure so the switch agrees with the host.
      if (enabled) {
        _disabled.add(id);
      } else {
        _disabled.remove(id);
      }
      if (mounted) {
        setState(() {});
        box.report(error);
      }
    }
  }

  Future<void> _openRules() async {
    final saved = await openPage<Json>(
      context,
      AdditionalRulesPage(profileId: widget.id, profileName: _name.text),
    );
    if (saved != null && mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final untitled = _name.text.trim().isEmpty ? context.tr('Untitled') : _name.text.trim();
    return FormPage(
      title: widget.id == 0 ? context.tr('Add profile') : untitled,
      saving: _saving,
      error: _error,
      children: [
        if (_error == null && _loading)
          generateSection(items: [ListItem(title: Text(context.tr('Loading')))])
        else ...[
          generateSection(title: context.tr('Profile settings'), items: [
            FormRow(
              title: context.tr('Name'),
              trailing: FormRowTextField(
                controller: _name,
                hintText: context.tr('Required'),
                autocorrect: false,
              ),
            ),
          ]),
          generateSection(title: context.tr('Match target'), items: [
            ListItem(
              title: Text(context.tr('Default outbound')),
              subtitle: Text(context.tr('The action a rule without an explicit outbound falls back to.')),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: SegmentedControl<String>(
                segments: matchTargets,
                value: _defaultOutbound,
                onChanged: _setTarget,
              ),
            ),
          ]),
          if (widget.id > 0) generateSection(title: context.tr('Additional rules'), items: [
            ListItem(
              leading: const GlyphIcon(AppGlyphs.rules),
              title: Text(context.tr('Additional rules')),
              subtitle: Text(context.tr('Rules run top to bottom; the first match wins.')),
              onTap: _openRules,
            ),
          ]),
          generateSection(title: context.tr('Global rules'), items: [
            ListItem(
              title: Text(context.tr('Manage global rules')),
              subtitle: Text(context.tr('Global added rules apply in front of every profile; turn them off per profile here.')),
              onTap: () async {
                await openPage(context, const GlobalRulesPage());
                if (mounted) await _load();
              },
            ),
            if (_globalRules.isNotEmpty) ...[
              for (final rule in _globalRules)
                ListItem.checkbox(
                  title: Text(ruleName(rule, _globalRules.indexOf(rule))),
                  subtitle: ruleRowSubtitle(context, rule),
                  value: !_disabled.contains((rule['id'] as num?)?.toInt()),
                  onChanged: (value) => _toggleGlobal((rule['id'] as num?)?.toInt() ?? 0, value == true),
                ),
            ] else
              ListItem(
                title: Text(context.tr('No global rules yet')),
                subtitle: Text(context.tr('Manage the shared rule pool applied to every profile.')),
              ),
          ]),
          if (widget.id > 0 && !_isRaw) generateSection(title: context.tr('Remote'), items: [
            ListItem.toggle(
              title: Text(context.tr('Remote profile')),
              value: _isRemote,
              onChanged: (value) => setState(() {
                _isRemote = value;
                if (!value) _autoUpdate = false;
              }),
            ),
            if (_isRemote)
              FormRow(
                title: context.tr('URL'),
                trailing: FormRowTextField(
                  controller: _url,
                  hintText: 'https://',
                  autocorrect: false,
                ),
              ),
            if (_isRemote)
              ListItem.toggle(
                title: Text(context.tr('Auto update')),
                value: _autoUpdate,
                onChanged: (value) => setState(() => _autoUpdate = value),
              ),
          ]),
          if (widget.id > 0 && !_isRaw) generateSection(items: [
            ListItem.toggle(
              title: Text(context.tr('Use this profile')),
              value: _current,
              onChanged: _setCurrent,
            ),
          ]),
        ],
      ],
    );
  }
}
