import '../widgets.dart';

/// Drag-to-reorder rules directly inside the editor. Reordering persists the
/// complete list through the same channel the editor uses for add/delete.
class RuleOrderSection extends StatefulWidget {
  const RuleOrderSection({
    super.key,
    required this.profileId,
    required this.rules,
    required this.onChanged,
    required this.onEdit,
  });
  final int profileId;
  final List<Json> rules;
  final ValueChanged<List<Json>> onChanged;
  final ValueChanged<int> onEdit;
  @override
  State<RuleOrderSection> createState() => _RuleOrderSectionState();
}

class _RuleOrderSectionState extends State<RuleOrderSection> {
  bool _saving = false;

  Widget _item(int index) => ReorderableDelayedDragStartListener(
    key: ObjectKey(widget.rules[index]),
    index: index,
    child: ItemPositionProvider(
      position: ItemPosition.get(index, widget.rules.length),
      child: DecorationListItem(
        contentPadding: const EdgeInsets.only(left: 16),
        title: Text(ruleName(widget.rules[index], index)),
        subtitle: ruleRowSubtitle(context, widget.rules[index]),
        trailing: SortHandle(index: index),
        onPressed: () => widget.onEdit(index),
      ),
    ),
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

  @override
  Widget build(BuildContext context) => Column(
    children: [
      generateSection(
        title: context.tr('Rules'),
        footer: context.tr(
          'Drag a rule to change the order; the first match wins',
        ),
        items: [
          if (widget.rules.isEmpty)
            ListItem(title: Text(context.tr('No results')))
          else
            ReorderableListView.builder(
              buildDefaultDragHandles: false,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: widget.rules.length,
              proxyDecorator: (child, index, animation) =>
                  commonProxyDecorator(_item(index), index, animation),
              onReorderItem: _reorder,
              itemBuilder: (_, index) => _item(index),
            ),
          DecorationListItem(
            contentPadding: const EdgeInsets.only(left: 16),
            title: Text(context.tr('Add rule')),
            trailing: const GlyphIcon(AppGlyphs.add),
            onPressed: () => widget.onEdit(-1),
          ),
        ],
      ),
      if (_saving)
        const Padding(
          padding: EdgeInsets.all(8),
          child: ActivityIndicator(size: 16),
        ),
    ],
  );
}
