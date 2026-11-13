// The shared global added-rules pool (FlClash's 控制全局附加规则 source).
//
// One authored rule set applied in front of every usable route profile's own
// rules, minus the ids a profile keeps off. This file holds the pool body as a
// reusable section, so the Routing page can be the pool itself. The
// per-profile subtraction is driven from a pool rule's own menu ("Disable for
// a profile"); the screen that used to own those switches is gone.

import '../widgets.dart';

/// One rule together with its pool id; the list stores by stable id so a delete
/// does not have to rewrite the whole pool.
class _PoolRef {
  const _PoolRef({required this.id, required this.rule});
  final int id;
  final Json rule;
}

/// What the pool body needs from whoever hosts it: the toolbar actions live on
/// the host (the Routing page's app bar or the standalone page's), while the
/// list itself is shared.
class GlobalRulesBody extends StatefulWidget {
  const GlobalRulesBody({super.key, this.controller});

  /// The host hands its toolbar here so "add" and "import" stay in the app bar
  /// where every other page puts its primary actions.
  final GlobalRulesController? controller;

  @override
  State<GlobalRulesBody> createState() => GlobalRulesBodyState();
}

/// The toolbar surface a host drives: the pool body owns the data, the host
/// owns the buttons, and this is the handle between them.
class GlobalRulesController extends ChangeNotifier {
  GlobalRulesBodyState? _state;

  void _attach(GlobalRulesBodyState state) => _state = state;
  void _detach(GlobalRulesBodyState state) {
    if (identical(_state, state)) _state = null;
  }

  /// The body pushes state changes here; the host listens.
  /// Called by the body whenever its state changes.
  void bodyChanged() => notifyListeners();

  bool get ready => _state != null;
  bool get loading => _state?.loading ?? true;
  bool get selectionActive => _state?.selectionActive ?? false;

  Future<void> reload() async => _state?.load();
  Future<void> add() async => _state?.addRule();
  Future<void> importRules() async => _state?.importRules();
  Future<void> deleteSelected() async => _state?.deleteSelected();

  /// Selection mode and the search field, driven from the host's toolbar.
  void cancelSelection() => _state?.cancelSelectMode();
  void selectAllVisible() => _state?.selectAllVisible();
  void search(String query) => _state?.setQuery(query);
  void startSelection() => _state?.startSelectMode();
}

class GlobalRulesBodyState extends State<GlobalRulesBody> {
  List<_PoolRef> _rules = const [];
  bool _loading = true;
  String? _error;
  final Set<int> _selected = {};

  /// Selection mode, distinct from "something is selected".
  ///
  /// It used to be derived from `_selected.isNotEmpty`, which made the mode
  /// unreachable: the first tick needs the mode already on. The Routing page's
  /// "Delete selected" button was therefore never drawn. A long press enters the
  /// mode with nothing ticked, which is how the per-profile rule list works.
  bool _selectMode = false;

  /// The filter the host's search field drives; empty shows everything.
  String _query = '';

  bool get loading => _loading;
  bool get selectionActive => _selectMode;
  Future<void> load() => _load();
  Future<void> addRule() => _add();
  Future<void> importRules() => _import();
  Future<void> deleteSelected() => _deleteSelected();

  /// Entering with nothing ticked is deliberate: the user asked to pick, not to
  /// act on a guess.
  void startSelectMode() {
    if (_selectMode) return;
    setState(() => _selectMode = true);
    widget.controller?.bodyChanged();
  }

  void cancelSelectMode() {
    if (!_selectMode && _selected.isEmpty) return;
    setState(() {
      _selectMode = false;
      _selected.clear();
    });
    widget.controller?.bodyChanged();
  }

  /// Ticks everything the filter currently shows, so "select all" cannot reach
  /// rows the user cannot see.
  void selectAllVisible() {
    setState(() => _selected.addAll(_visible.map((ref) => ref.id)));
    widget.controller?.bodyChanged();
  }

  void setQuery(String value) {
    final next = value.trim();
    if (next == _query) return;
    setState(() => _query = next);
    widget.controller?.bodyChanged();
  }

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final box = context.box;
    try {
      final data = json(await box.routeGlobalRules(0));
      if (!mounted) return;
      final rules = rows(data['rules']).map((rule) {
        final id = (rule['id'] as num?)?.toInt() ?? 0;
        return _PoolRef(id: id, rule: rule);
      }).toList();
      setState(() {
        _rules = rules;
        _loading = false;
      });
      widget.controller?.bodyChanged();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = BoxController.describe(error);
        _loading = false;
      });
      widget.controller?.bodyChanged();
    }
  }

  List<_PoolRef> get _sorted => _rules.toList();

  /// The rules the search field lets through, in pool order.
  ///
  /// Reordering is disabled while a filter is on: a drag inside a subset would
  /// have to translate its target index back into the full list, and guessing
  /// that wrong silently reorders rules the user cannot see.
  List<_PoolRef> get _visible {
    if (_query.isEmpty) return _rules;
    final needle = _query.toLowerCase();
    return [
      for (var i = 0; i < _rules.length; i++)
        if (ruleName(_rules[i].rule, i).toLowerCase().contains(needle)) _rules[i],
    ];
  }

  bool get _filtered => _query.isNotEmpty;

  Future<void> _edit(_PoolRef ref) async {
    final saved = await openPage<Json>(
      context,
      RuleEditorPage(
        profileId: 0,
        index: _rules.indexOf(ref),
        rule: ref.rule,
        rules: _rules.map((e) => e.rule).toList(),
        pool: true,
      ),
    );
    if (saved == null || !mounted) return;
    await _load();
  }

  Future<void> _add() async {
    final saved = await openPage<Json>(
      context,
      RuleEditorPage(
        profileId: 0,
        index: -1,
        rule: const {},
        rules: _rules.map((e) => e.rule).toList(),
        pool: true,
      ),
    );
    if (saved == null || !mounted) return;
    await _load();
  }

  Future<void> _import() async {
    final box = context.box;
    final request = await showDialog<RuleImportRequest>(
      context: context,
      builder: (_) => RuleImportPage(profileId: 0, intoPool: true),
    );
    if (request == null || !mounted) return;
    try {
      await applyRuleImport(box, request, profileId: 0, intoPool: true);
      if (mounted) await _load();
    } catch (error) {
      box.report(error);
    }
  }

  /// Persists a drag. `onReorderItem` hands over an insertion index that
  /// already accounts for the removed row (Flutter's own doc for the callback
  /// says so, and `additional_rules.dart` relies on the same contract), so the
  /// index is used as-is. Subtracting one here again — as this used to — made
  /// every downward drag persist one slot short, so the stored order stopped
  /// matching what the user saw.
  Future<void> _reorder(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    final ordered = _sorted;
    final moved = ordered.removeAt(oldIndex);
    ordered.insert(newIndex, moved);
    setState(() => _rules = ordered);
    try {
      await context.box.routeSaveGlobalRules(ordered.map((e) => e.rule).toList());
      if (mounted) await _load();
    } catch (error) {
      if (mounted) context.box.report(error);
    }
  }

  /// Turns this pool rule on or off for one configuration.
  ///
  /// The per-profile switches used to live on the profile's override screen,
  /// which is gone, and `_disabled` is stored per profile on the host. Listing
  /// the profiles here keeps the capability — and it takes both directions:
  /// with only "disable", a configuration that had a rule off stayed that way
  /// with no way to change its mind.
  Future<void> _setDisabledForProfile(_PoolRef ref, {required bool disabled}) async {
    final box = context.box;
    List<Json> profiles;
    try {
      final data = json(await box.routeProfiles.list());
      profiles = (data['profiles'] as List? ?? const [])
          .map((item) => json(item))
          .where((profile) => (profile['isRaw'] as bool?) != true)
          .toList();
    } catch (error) {
      if (mounted) box.report(error);
      return;
    }
    if (!mounted || profiles.isEmpty) return;
    final picked = await showDialog<Json>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(context.tr(
            disabled ? 'Disable for a profile' : 'Enable for a profile')),
        children: [
          for (final profile in profiles)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, profile),
              child: Text(
                '${profile['name'] ?? context.tr('Untitled')}'
                '${profile['current'] == true ? ' · ${context.tr('Current')}' : ''}',
              ),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    final profileId = (picked['id'] as num?)?.toInt() ?? 0;
    if (profileId <= 0) return;
    try {
      final data = json(await box.routeGlobalRules(profileId));
      final current = {
        for (final rule in rows(data['rules']))
          if (rule['enabled'] != true) (rule['id'] as num?)?.toInt(),
      }..remove(null);
      // A set either way: the write replaces the whole disabled list, so the
      // add and the remove are the same call with one member changed.
      if (disabled) {
        current.add(ref.id);
      } else {
        current.remove(ref.id);
      }
      await box.routeSetGlobalRuleDisabled(profileId, current.toList());
      if (mounted) {
        showAppBanner(
          context,
          '${context.tr(disabled ? 'Disabled for' : 'Enabled for')} '
          '${picked['name'] ?? context.tr('Untitled')}',
        );
      }
    } catch (error) {
      if (mounted) box.report(error);
    }
  }

  Future<void> _deleteOne(_PoolRef ref) async {
    final ok = await confirm(
      context,
      'Delete this rule?',
      message: ruleName(ref.rule, _rules.indexOf(ref)),
      action: 'Delete',
    );
    if (ok != true || !mounted) return;
    try {
      await context.box.routeDeleteGlobalRule(ref.id);
      setState(() => _selected.remove(ref.id));
      if (mounted) await _load();
    } catch (error) {
      if (mounted) context.box.report(error);
    }
  }

  Future<void> _deleteSelected() async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    final ok = await confirm(
      context,
      'Delete selected',
      message: '${ids.length} ${context.tr('Selected')}',
      action: 'Delete',
    );
    if (ok != true || !mounted) return;
    final box = context.box;
    try {
      for (final id in ids) {
        await box.routeDeleteGlobalRule(id);
      }
      setState(() => _selected.clear());
      widget.controller?.bodyChanged();
      if (mounted) await _load();
    } catch (error) {
      if (mounted) box.report(error);
    }
  }

  void _toggleSelected(_PoolRef ref) {
    setState(() {
      if (!_selected.remove(ref.id)) _selected.add(ref.id);
    });
    widget.controller?.bodyChanged();
  }

  /// The list on its own, sized for a host that supplies its own scroll view
  /// (the Routing page's ListView). The standalone page stretches it.
  Widget _list({required bool shrinkWrap}) {
    final visible = _visible;
    final selectionActive = _selectMode;
    // A filtered list cannot be dragged: the target index would be a position
    // inside the subset, and applying it to the full pool moves the wrong rows.
    final canReorder = !selectionActive && !_filtered;
    return ReorderableListView.builder(
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      buildDefaultDragHandles: false,
      padding: shrinkWrap
          ? EdgeInsets.zero
          : EdgeInsets.fromLTRB(
              16,
              context.sectionsTopPadding,
              16,
              24 + context.bottomInset,
            ),
      itemCount: visible.length,
      onReorderItem: canReorder ? _reorder : (_, _) {},
      itemBuilder: (context, index) {
        final ref = visible[index];
        // DecorationListItem rounds its own corners from the row's position in
        // the group; a reorderable list is not built through generateGroup, so
        // without this the rows came out square while every other list on every
        // other page is a rounded card.
        final position = ItemPosition.get(index, visible.length);
        final Widget row = ItemPositionProvider(
          position: position,
          child: DecorationListItem(
            contentPadding: const EdgeInsets.only(left: 16),
            title: Text(ruleName(ref.rule, _rules.indexOf(ref))),
            subtitle: ruleRowSubtitle(context, ref.rule),
            leading: GlyphIcon(
              selectionActive
                  ? (_selected.contains(ref.id) ? AppGlyphs.checkCircle : AppGlyphs.rules)
                  : AppGlyphs.rules,
            ),
            trailing: canReorder ? SortHandle(index: index) : null,
            onPressed: () {
              if (selectionActive) {
                _toggleSelected(ref);
                return;
              }
              _edit(ref);
            },
          ),
        );
        if (selectionActive || !canReorder) {
          return KeyedSubtree(key: ObjectKey(ref.id), child: row);
        }
        return ReorderableDelayedDragStartListener(
          key: ObjectKey(ref.id),
          index: index,
          child: ContextMenuRegion(
            menuItems: [
              PopupMenuItem(
                glyph: AppGlyphs.edit,
                label: context.tr('Edit'),
                onPressed: () => _edit(ref),
              ),
              // The per-configuration opt-out the profile screens used to own.
              // The rule stays in the pool and every other configuration keeps
              // it; this is the only way to turn it off for one of them.
              PopupMenuItem(
                glyph: AppGlyphs.eyeOff,
                label: context.tr('Disable for a profile'),
                onPressed: () => _setDisabledForProfile(ref, disabled: true),
              ),
              // The other half of that switch: before it, a rule turned off for a
              // configuration could never be turned back on from here.
              PopupMenuItem(
                glyph: AppGlyphs.eye,
                label: context.tr('Enable for a profile'),
                onPressed: () => _setDisabledForProfile(ref, disabled: false),
              ),
              PopupMenuItem(
                glyph: AppGlyphs.delete,
                label: context.tr('Delete'),
                onPressed: () => _deleteOne(ref),
              ),
            ],
            child: row,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // The body is always hosted inside a scroll view (the Routing page's own
    // ListView, or the standalone page's), so NullStatusSwitcher — which asks
    // for an unbounded expand — cannot size the empty state here. The states
    // are inlined instead, with a flat empty card that fits a sliver.
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: ActivityIndicator()),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          _error!,
          style: context.listCaptionStyle.copyWith(color: context.colorScheme.error),
        ),
      );
    }
    if (_rules.isEmpty) {
      return generateSection(
        items: [
          ListItem(
            leading: const GlyphIcon(AppGlyphs.rules),
            title: Text(context.tr('No global rules yet')),
            subtitle: Text(context.tr('Manage the shared rule pool applied to every profile.')),
          ),
        ],
      );
    }
    return _list(shrinkWrap: true);
  }
}
