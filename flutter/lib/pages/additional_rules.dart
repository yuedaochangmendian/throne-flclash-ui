// The additional rules of route profiles.
//
// FlClash keeps a profile's own rules on their own screen — a bar, an empty
// state, a search field at the foot — instead of folding them into the profile's
// settings form. This is that screen: every rule of every route profile in one
// list, ordered, reorderable by drag, editable by tap, and importable as a
// sing-box fragment.

import '../widgets.dart';

/// One rule together with the profile that owns it: the list spans profiles, so
/// a row has to remember where it goes back to.
class _RuleRef {
  const _RuleRef({required this.profileId, required this.index, required this.rule});
  final int profileId;
  final int index;
  final Json rule;
}

class AdditionalRulesPage extends StatefulWidget {
  const AdditionalRulesPage({super.key, required this.profileId, this.profileName = ''});

  /// The profile whose rules are shown; 0 lists every profile's.
  final int profileId;
  final String profileName;

  @override
  State<AdditionalRulesPage> createState() => _AdditionalRulesPageState();
}

class _AdditionalRulesPageState extends State<AdditionalRulesPage> {
  List<_RuleRef> _rules = const [];
  Map<int, List<Json>> _byProfile = const {};
  bool _loading = true;
  String _query = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final box = context.box;
      final profiles = widget.profileId > 0
          ? [
              {
                'id': widget.profileId,
                'name': widget.profileName,
              },
            ]
          : rows(json(await box.routeProfiles.list())['profiles']);
      final byProfile = <int, List<Json>>{};
      final refs = <_RuleRef>[];
      for (final profile in profiles) {
        final id = (profile['id'] as num?)?.toInt() ?? 0;
        if (id <= 0) continue;
        final data = json(await box.routeRules(id));
        final rules = rows(data['rules']);
        byProfile[id] = rules;
        for (final (index, rule) in rules.indexed) {
          refs.add(_RuleRef(profileId: id, index: index, rule: rule));
        }
      }
      if (!mounted) return;
      setState(() {
        _byProfile = byProfile;
        _rules = refs;
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

  List<_RuleRef> get _filtered {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return _rules;
    return [
      for (final ref in _rules)
        if (ruleName(ref.rule, ref.index).toLowerCase().contains(query))
          ref,
    ];
  }

  Future<void> _edit(_RuleRef ref) async {
    final saved = await openPage<Json>(
      context,
      RuleEditorPage(
        profileId: ref.profileId,
        index: ref.index,
        rule: ref.rule,
        rules: _byProfile[ref.profileId] ?? const [],
      ),
    );
    if (saved == null || !mounted) return;
    await _load();
  }

  Future<void> _add() async {
    if (widget.profileId <= 0) {
      // With every profile listed the new rule needs an owner; ask which.
      final ids = _byProfile.keys.toList();
      if (ids.isEmpty) {
        context.box.report(StateError(context.tr('No route profiles yet')));
        return;
      }
      final picked = await showDialog<int>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(context.tr('Route profile')),
          children: [
            for (final id in ids)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, id),
                child: Text(context.tr('Default')),
              ),
          ],
        ),
      );
      if (picked == null || !mounted) return;
      await _openEditor(picked, -1, const {});
      return;
    }
    await _openEditor(widget.profileId, -1, const {});
  }

  Future<void> _openEditor(int profileId, int index, Json rule) async {
    final saved = await openPage<Json>(
      context,
      RuleEditorPage(
        profileId: profileId,
        index: index,
        rule: rule,
        rules: _byProfile[profileId] ?? const [],
      ),
    );
    if (saved == null || !mounted) return;
    await _load();
  }

  Future<void> _import() async {
    if (widget.profileId <= 0) {
      await _add();
      return;
    }
    final box = context.box;
    final request = await showDialog<RuleImportRequest>(
      context: context,
      builder: (_) => RuleImportPage(profileId: widget.profileId),
    );
    if (request == null || !mounted) return;
    try {
      await applyRuleImport(box, request, profileId: widget.profileId);
      if (mounted) await _load();
    } catch (error) {
      box.report(error);
    }
  }

  /// Persists a drag: the rules of one profile are reordered among themselves,
  /// because the order that matters is each profile's own.
  Future<void> _reorder(int oldIndex, int newIndex) async {
    // A filtered view has no stable order to drag within: the row the finger
    // holds is not the row at that index in the stored list.
    if (_query.trim().isNotEmpty) return;
    if (oldIndex == newIndex) return;
    final moved = _rules[oldIndex];
    final siblings = [
      for (final ref in _rules)
        if (ref.profileId == moved.profileId) ref,
    ];
    final from = siblings.indexWhere((ref) => ref.index == moved.index);
    final to = newIndex > oldIndex ? newIndex - 1 : newIndex;
    if (from < 0 || to < 0 || to >= siblings.length) return;
    final ordered = List<Json>.of(_byProfile[moved.profileId] ?? const []);
    final rule = ordered.removeAt(from);
    ordered.insert(to.clamp(0, ordered.length), rule);
    setState(() {
      _byProfile = {..._byProfile, moved.profileId: ordered};
      _rules = _rebuild();
    });
    try {
      await context.box.routeSaveRules(moved.profileId, ordered);
      if (mounted) await _load();
    } catch (error) {
      if (mounted) context.box.report(error);
    }
  }

  List<_RuleRef> _rebuild() => [
    for (final entry in _byProfile.entries)
      for (final (index, rule) in entry.value.indexed)
        _RuleRef(profileId: entry.key, index: index, rule: rule),
  ];

  Future<void> _delete(_RuleRef ref) async {
    final ok = await confirm(
      context,
      'Delete this rule?',
      message: ruleName(ref.rule, ref.index),
      action: 'Delete',
    );
    if (!ok || !mounted) return;
    final box = context.box;
    final rules = List<Json>.of(_byProfile[ref.profileId] ?? const [])
      ..removeAt(ref.index);
    try {
      await box.routeSaveRules(ref.profileId, rules);
      if (mounted) await _load();
    } catch (error) {
      if (mounted) box.report(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return Scaffold(
      title: context.tr('Additional rules'),
      searchState: AppBarSearchState(
        onSearch: (query) => setState(() => _query = query),
        query: _query,
      ),
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.rules,
          tooltip: context.tr('Import rules from JSON'),
          onPressed: _loading ? null : _import,
        ),
        IconButtonData(
          glyph: AppGlyphs.add,
          tooltip: context.tr('Add rule'),
          onPressed: _loading ? null : _add,
        ),
      ],
      body: NullStatusSwitcher(
        isLoading: _loading,
        isEmpty: !_loading && filtered.isEmpty,
        isSearching: _query.trim().isNotEmpty,
        nullStatus: NullStatus(
          label: _query.trim().isNotEmpty
              ? context.tr('No results')
              : context.tr('No rules yet'),
          description: _query.trim().isNotEmpty
              ? null
              : context.tr("Rules added here run before the profile's own."),
          illustration: NullStatusIllustration.rules,
        ),
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error!,
                  style: context.listCaptionStyle.copyWith(
                    color: context.colorScheme.error,
                  ),
                ),
              )
            : ReorderableListView.builder(
                buildDefaultDragHandles: false,
                padding: EdgeInsets.fromLTRB(
                  16,
                  context.sectionsTopPadding,
                  16,
                  24 + context.bottomInset,
                ),
                itemCount: filtered.length,
                onReorderItem: _reorder,
                itemBuilder: (context, index) {
                  final ref = filtered[index];
                  return ReorderableDelayedDragStartListener(
                    key: ObjectKey(ref.rule),
                    index: index,
                    child: ContextMenuRegion(
                      menuItems: [
                        PopupMenuItem(
                          glyph: AppGlyphs.edit,
                          label: context.tr('Edit'),
                          onPressed: () => _edit(ref),
                        ),
                        PopupMenuItem(
                          glyph: AppGlyphs.delete,
                          label: context.tr('Delete'),
                          onPressed: () => _delete(ref),
                        ),
                      ],
                      child: DecorationListItem(
                        contentPadding: const EdgeInsets.only(left: 16),
                        title: Text(ruleName(ref.rule, ref.index)),
                        subtitle: ruleRowSubtitle(context, ref.rule),
                        leading: const GlyphIcon(AppGlyphs.rules),
                        trailing: const SortHandle(index: 0),
                        onPressed: () => _edit(ref),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
