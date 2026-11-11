// The shared global added-rules pool (FlClash's 控制全局附加规则 source).
//
// One authored rule set applied in front of every usable route profile's own
// rules, minus the ids a profile keeps off. This is that pool: edit, add,
// reorder, delete and import rules into it. The per-profile switches that turn a
// pool rule off for one profile live on each rule's sheet and on the profile's
// override screen.

import '../widgets.dart';

/// One rule together with its pool id; the list stores by stable id so a delete
/// does not have to rewrite the whole pool.
class _PoolRef {
  const _PoolRef({required this.id, required this.rule});
  final int id;
  final Json rule;
}

class GlobalRulesPage extends StatefulWidget {
  const GlobalRulesPage({super.key});

  @override
  State<GlobalRulesPage> createState() => _GlobalRulesPageState();
}

class _GlobalRulesPageState extends State<GlobalRulesPage> {
  List<_PoolRef> _rules = const [];
  bool _loading = true;
  String? _error;
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
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = BoxController.describe(error);
        _loading = false;
      });
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
      if (mounted) await _load();
    } catch (error) {
      if (mounted) box.report(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectionActive = _selected.isNotEmpty;
    return Scaffold(
      title: context.tr('Global rules'),
      iconActions: [
        if (selectionActive)
          IconButtonData(
            glyph: AppGlyphs.delete,
            tooltip: context.tr('Delete selected'),
            onPressed: _deleteSelected,
          )
        else ...[
          IconButtonData(
            glyph: AppGlyphs.code,
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
        isEmpty: !_loading && _rules.isEmpty,
        nullStatus: NullStatus(
          label: context.tr('No global rules yet'),
          description: context.tr('Manage the shared rule pool applied to every profile.'),
          illustration: NullStatusIllustration.rules,
        ),
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error!,
                  style: context.listCaptionStyle.copyWith(color: context.colorScheme.error),
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
                itemCount: _rules.length,
                onReorderItem: _reorder,
                itemBuilder: (context, index) {
                  final ref = _rules[index];
                  final Widget row = DecorationListItem(
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
                        setState(() {
                          if (_selected.contains(ref.id)) {
                            _selected.remove(ref.id);
                          } else {
                            _selected.add(ref.id);
                          }
                        });
                        return;
                      }
                      _edit(ref);
                    },
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
              ),
      ),
    );
  }
}
