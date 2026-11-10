import 'dart:math' as math;

import '../widgets.dart';

/// Drag-to-reorder rules directly inside the editor. Reordering persists the
/// complete list through the same channel the editor uses for add/delete.
class RuleOrderSection extends StatefulWidget {
  const RuleOrderSection({super.key, required this.profileId, required this.rules,
    required this.onChanged, required this.onEdit});
  final int profileId;
  final List<Json> rules;
  final ValueChanged<List<Json>> onChanged;
  final ValueChanged<int> onEdit;
  @override State<RuleOrderSection> createState() => _RuleOrderSectionState();
}

class _RuleOrderSectionState extends State<RuleOrderSection> {
  bool _saving = false;

  Widget _item(int index) => ReorderableDelayedDragStartListener(
    key: ValueKey('rule-'), index: index,
    child: ItemPositionProvider(position: ItemPosition.get(index, widget.rules.length),
      child: DecorationListItem(contentPadding: const EdgeInsets.only(left: 16),
        title: Text(ruleName(widget.rules[index], index)),
        subtitle: ruleRowSubtitle(context, widget.rules[index]),
        trailing: SortHandle(index: index),
        onPressed: () => widget.onEdit(index))),
  );

  Future<void> _reorder(int oldIndex, int newIndex) async {
    final rules = List<Json>.of(widget.rules);
    rules.insert(newIndex, rules.removeAt(oldIndex));
    widget.onChanged(rules);
    setState(() => _saving = true);
    try {
      await context.box.routeSaveRules(widget.profileId, rules);
    } catch (error) {
      if (mounted) context.box.report(error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override Widget build(BuildContext context) => Column(children: [
    generateSection(title: context.tr('Rules'), footer: context.tr('Drag a rule to change the order; the first match wins'), items: [
      if (widget.rules.isEmpty) ListItem(title: Text(context.tr('No results')))
      else SizedBox(height: math.min(320.0, widget.rules.length * 64.0), child: ReorderableListView.builder(
        buildDefaultDragHandles: false,
        itemCount: widget.rules.length,
        proxyDecorator: (child, index, animation) => commonProxyDecorator(_item(index), index, animation),
        onReorderItem: _reorder,
        itemBuilder: (_, index) => _item(index),
      )),
      ListItem(leading: const GlyphIcon(AppGlyphs.add), title: Text(context.tr('Add rule')),
        onTap: () => widget.onEdit(-1)),
    ]),
    if (_saving) const Padding(padding: EdgeInsets.all(8), child: ActivityIndicator(size: 16)),
  ]);
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