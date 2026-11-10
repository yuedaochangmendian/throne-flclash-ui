// The route profile editor: name, default outbound, remote subscription and
// the profile's rules.

import 'package:material_ui/material_ui.dart' as material;

import '../widgets.dart';
import '../components/form.dart';

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
      setState(
        () => _rules = (data['rules'] as List? ?? const [])
            .map((e) => json(e))
            .toList(),
      );
    } catch (error) {
      if (mounted) context.box.report(error);
    }
  }

  Future<void> _editRule(int index) async {
    if (widget.id == 0) {
      context.box.report(StateError(context.tr('Save the profile first')));
      return;
    }
    final saved = await openPage<Json>(
      context,
      RuleEditorPage(
        profileId: widget.id,
        index: index,
        rule: index < 0 ? const {} : _rules[index],
        rules: _rules,
      ),
    );
    if (saved == null || !mounted) return;
    setState(() => _rules = rows(saved['rules']));
    await _loadRules();
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
      if (mounted) context.safeNestedPop();
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = BoxController.describe(error);
        });
      }
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => material.AlertDialog(
        title: Text(context.tr('Delete route profile?')),
        content: Text(_name.text),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.tr('Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.tr('Delete')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await context.box.routeDelete(widget.id);
      if (mounted) {
        context.safeNestedPop();
      }
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
          IconButtonData(
            glyph: AppGlyphs.delete,
            tooltip: 'Delete',
            onPressed: _delete,
          ),
      ],
      children: [
        if (_isRaw)
          generateSection(
            items: [
              ListItem(
                leading: const GlyphIcon(AppGlyphs.info),
                title: Text(context.tr('Read-only')),
                subtitle: Text(
                  context.tr(
                    'This profile is built in and cannot be changed here.',
                  ),
                ),
              ),
            ],
          ),
        generateSection(
          items: [
            FormRow(
              title: context.tr('Name'),
              trailing: FormRowTextField(
                controller: _name,
                hintText: context.tr('Required'),
                autocorrect: false,
              ),
            ),
            ListItem(
              title: Text(context.tr('Default outbound')),
              trailing: Text(
                context.tr(_outboundLabel(_defaultOutbound)),
                style: context.listValueStyle,
              ),
              onTap: () async {
                final picked = await showDialog<String>(
                  context: context,
                  builder: (context) => SimpleDialog(
                    title: Text(context.tr('Default outbound')),
                    children: [
                      for (final value in const [
                        'proxy',
                        'direct',
                        'block',
                        'warp-bypass',
                      ])
                        SimpleDialogOption(
                          onPressed: () => Navigator.pop(context, value),
                          child: Text(context.tr(_outboundLabel(value))),
                        ),
                    ],
                  ),
                );
                if (picked != null && mounted) {
                  setState(() => _defaultOutbound = picked);
                }
              },
            ),
          ],
        ),
        generateSection(
          title: context.tr('Remote'),
          items: [
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
                  keyboardType: TextInputType.text,
                  autocorrect: false,
                ),
              ),
            if (_isRemote)
              ListItem.toggle(
                title: Text(context.tr('Auto update')),
                value: _autoUpdate,
                onChanged: (value) => setState(() => _autoUpdate = value),
              ),
          ],
          footer: context.tr(
            'A remote profile downloads its rules from the URL.',
          ),
        ),
        if (_isRaw)
          generateSection(
            title: context.tr('Rules'),
            items: [
              for (final (index, rule) in _rules.indexed)
                ListItem(
                  title: Text(ruleName(rule, index)),
                  subtitle: ruleRowSubtitle(context, rule),
                ),
            ],
            footer: context.tr(
              'This profile is built in and cannot be changed here.',
            ),
          )
        else
          RuleOrderSection(
            profileId: widget.id,
            rules: _rules,
            onChanged: (rules) => setState(() => _rules = rules),
            onEdit: _editRule,
          ),
        if (widget.id > 0)
          generateSection(
            items: [
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
            ],
          ),
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
