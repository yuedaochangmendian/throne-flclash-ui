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

  /// Names for the owner picker (a rule added while every profile is listed
  /// has to name its owner), and the read-only set: a built-in profile refuses
  /// writes, so its rows must not be draggable or addable here.
  Map<int, String> _names = const {};
  Set<int> _readOnly = const {};
  bool _loading = true;
  String _query = '';
  String? _error;

  /// Selection mode: rows turn into checkboxes and the app bar swaps to a
  /// select-all / delete-selected pair (FlClash's multi-delete).
  bool _selecting = false;
  final Set<int> _selected = {};

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
    // Read before the first await: no BuildContext crosses an async gap below.
    final box = context.box;
    final untitled = context.tr('Untitled');
    try {
      final profiles = widget.profileId > 0
          ? [
              {
                'id': widget.profileId,
                'name': widget.profileName,
              },
            ]
          : rows(json(await box.routeProfiles.list())['profiles']);
      final byProfile = <int, List<Json>>{};
      final names = <int, String>{};
      final readOnly = <int>{};
      final refs = <_RuleRef>[];
      for (final profile in profiles) {
        final id = (profile['id'] as num?)?.toInt() ?? 0;
        if (id <= 0) continue;
        final name = profile['name']?.toString().trim() ?? '';
        names[id] = name.isEmpty ? untitled : name;
        if (profile['isRaw'] == true) readOnly.add(id);
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
        _names = names;
        _readOnly = readOnly;
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

  String _profileName(int id) => _names[id] ?? '#$id';

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
      final ids = _byProfile.keys.where((id) => !_readOnly.contains(id)).toList();
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
                child: Text(_profileName(id)),
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

  /// Persists a drag. `onReorderItem` hands over an insertion index that
  /// already accounts for the removed row, so it is used as-is. The list spans
  /// profiles, so a drag only reorders within the dragged row's own profile —
  /// that is the order the profile stores and the router evaluates.
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
    // The global insertion index becomes an index inside this profile by
    // counting how many of its rows the drop landed after.
    final to = siblings.indexWhere((ref) => _rules.indexOf(ref) >= newIndex);
    if (from < 0) return;
    final ordered = List<Json>.of(_byProfile[moved.profileId] ?? const []);
    if (from >= ordered.length) return;
    final rule = ordered.removeAt(from);
    final target = (to < 0 ? siblings.length : to).clamp(0, ordered.length);
    ordered.insert(target, rule);
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

  /// Deletes every selected rule, rebuilding each affected profile's list. The
  /// selection is cleared afterwards; an empty selection is a no-op.
  Future<void> _deleteSelected() async {
    final refs = _filtered.where((ref) => _selected.contains(ref.index)).toList();
    if (refs.isEmpty) return;
    final ok = await confirm(
      context,
      'Delete selected',
      message: '${refs.length} ${context.tr('Selected')}',
      action: 'Delete',
    );
    if (ok != true || !mounted) return;
    final box = context.box;
    try {
      final byProfile = <int, List<Json>>{};
      for (final ref in refs) {
        final ordered = List<Json>.of(_byProfile[ref.profileId] ?? const [])
          ..removeAt(ref.index);
        byProfile[ref.profileId] = ordered;
      }
      for (final entry in byProfile.entries) {
        await box.routeSaveRules(entry.key, entry.value);
      }
      setState(() => _selected.clear());
      if (mounted) await _load();
    } catch (error) {
      if (mounted) box.report(error);
    }
  }

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
    final selectionActive = _selecting && _selected.isNotEmpty;
    return Scaffold(
      title: context.tr('Additional rules'),
      searchState: AppBarSearchState(
        onSearch: (query) => setState(() => _query = query),
        query: _query,
      ),
      iconActions: [
        if (_selecting) ...[
          IconButtonData(
            glyph: AppGlyphs.selectAll,
            tooltip: context.tr('Select all'),
            onPressed: _loading ? null : () => setState(() {
              _selected.clear();
              for (final ref in _filtered) {
                _selected.add(ref.index);
              }
            }),
          ),
          IconButtonData(
            glyph: AppGlyphs.delete,
            tooltip: context.tr('Delete selected'),
            onPressed: selectionActive ? _deleteSelected : null,
          ),
          IconButtonData(
            glyph: AppGlyphs.close,
            tooltip: context.tr('Cancel'),
            onPressed: () => setState(() {
              _selecting = false;
              _selected.clear();
            }),
          ),
        ] else ...[
          IconButtonData(
            glyph: AppGlyphs.checkCircle,
            tooltip: context.tr('Select'),
            onPressed: _loading ? null : () => setState(() => _selecting = true),
          ),
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
                onReorderItem: _selecting ? (a, b) {} : _reorder,
                itemBuilder: (context, index) {
                  final ref = filtered[index];
                  // A built-in profile's rules are view-only: the save endpoint
                  // refuses them, so offering drag, edit and delete here would
                  // only produce an error after the fact.
                  final readOnly = _readOnly.contains(ref.profileId);
                  final row = DecorationListItem(
                    contentPadding: const EdgeInsets.only(left: 16),
                    title: Text(ruleName(ref.rule, ref.index)),
                    subtitle: ruleRowSubtitle(context, ref.rule),
                    leading: _selecting
                        ? GlyphIcon(_selected.contains(ref.index)
                            ? AppGlyphs.checkCircle
                            : AppGlyphs.rules)
                        : const GlyphIcon(AppGlyphs.rules),
                    trailing: _selecting ? null : (readOnly ? null : SortHandle(index: index)),
                    onPressed: () {
                      if (_selecting) {
                        setState(() {
                          if (_selected.contains(ref.index)) {
                            _selected.remove(ref.index);
                          } else {
                            _selected.add(ref.index);
                          }
                        });
                        return;
                      }
                      if (!readOnly) _edit(ref);
                    },
                  );
                  if (_selecting || readOnly) {
                    return KeyedSubtree(key: ObjectKey(ref.rule), child: row);
                  }
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
                      child: row,
                    ),
                  );
                },
              ),
      ),
    );
  }
}
