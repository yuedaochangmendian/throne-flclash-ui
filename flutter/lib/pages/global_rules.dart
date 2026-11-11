// The shared global added-rules pool (FlClash's 控制全局附加规则 source).
//
// One authored rule set applied in front of every usable route profile's own
// rules, minus the ids a profile keeps off. This file holds the pool body as a
// reusable section so the Routing page can be the pool (the user's ask: the
// routing screen shows nothing but the global rules, and every other control
// moves into the menu), and [GlobalRulesPage] keeps a standalone page for the
// places that still open one.

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
}

class GlobalRulesBodyState extends State<GlobalRulesBody> {
  List<_PoolRef> _rules = const [];
  bool _loading = true;
  String? _error;
  final Set<int> _selected = {};

  bool get loading => _loading;
  bool get selectionActive => _selected.isNotEmpty;
  Future<void> load() => _load();
  Future<void> addRule() => _add();
  Future<void> importRules() => _import();
  Future<void> deleteSelected() => _deleteSelected();

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

  Future<void> _reorder(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    final ordered = _sorted;
    final moved = ordered.removeAt(oldIndex);
    ordered.insert(newIndex > oldIndex ? newIndex - 1 : newIndex, moved);
    setState(() => _rules = ordered);
    try {
      await context.box.routeSaveGlobalRules(ordered.map((e) => e.rule).toList());
      if (mounted) await _load();
    } catch (error) {
      if (mounted) context.box.report(error);
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
    final selectionActive = _selected.isNotEmpty;
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
      itemCount: _rules.length,
      onReorderItem: _reorder,
      itemBuilder: (context, index) {
        final ref = _rules[index];
        // DecorationListItem rounds its own corners from the row's position in
        // the group; a reorderable list is not built through generateGroup, so
        // without this the rows came out square while every other list on every
        // other page is a rounded card.
        final position = ItemPosition.get(index, _rules.length);
        final Widget row = ItemPositionProvider(
          position: position,
          child: DecorationListItem(
            contentPadding: const EdgeInsets.only(left: 16),
            title: Text(ruleName(ref.rule, index)),
            subtitle: ruleRowSubtitle(context, ref.rule),
            leading: GlyphIcon(
              selectionActive
                  ? (_selected.contains(ref.id) ? AppGlyphs.checkCircle : AppGlyphs.rules)
                  : AppGlyphs.rules,
            ),
            trailing: selectionActive ? null : SortHandle(index: index),
            onPressed: () {
              if (selectionActive) {
                _toggleSelected(ref);
                return;
              }
              _edit(ref);
            },
          ),
        );
        if (selectionActive) {
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

class GlobalRulesPage extends StatefulWidget {
  const GlobalRulesPage({super.key});

  @override
  State<GlobalRulesPage> createState() => _GlobalRulesPageState();
}

class _GlobalRulesPageState extends State<GlobalRulesPage> {
  final _controller = GlobalRulesController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final selectionActive = _controller.selectionActive;
        return Scaffold(
          title: context.tr('Global rules'),
          iconActions: [
            if (selectionActive)
              IconButtonData(
                glyph: AppGlyphs.delete,
                tooltip: context.tr('Delete selected'),
                onPressed: _controller.deleteSelected,
              )
            else ...[
              IconButtonData(
                glyph: AppGlyphs.code,
                tooltip: context.tr('Import rules from JSON'),
                onPressed: _controller.loading ? null : _controller.importRules,
              ),
              IconButtonData(
                glyph: AppGlyphs.add,
                tooltip: context.tr('Add rule'),
                onPressed: _controller.loading ? null : _controller.add,
              ),
            ],
          ],
          body: ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              context.sectionsTopPadding,
              16,
              24 + context.bottomInset,
            ),
            children: [
              GlobalRulesBody(controller: _controller),
            ],
          ),
        );
      },
    );
  }
}
