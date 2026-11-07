// The rules in drag order — the list *is* the profile's rule order.

import '../widgets.dart';

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
