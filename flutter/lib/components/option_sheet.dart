// A single-choice list in a sheet: what Material's SimpleDialog was used for
// at every call site in this app (a title over a list of options, one popped
// value). Prism has no dialog for that shape — its own vocabulary is a sheet
// with a titled section of rows — so this is that composition, not a new
// widget: showSheet + generateSection + ListItem.open.

import 'package:flutter/widgets.dart';
import 'package:flrone/ui/context.dart';
import 'package:flrone/ui/icons/app_glyphs.dart';
import 'package:flrone/ui/icons/glyph_icon.dart';
import 'package:flrone/ui/list.dart';
import 'package:flrone/ui/list_item.dart';
import 'package:flrone/ui/sheet.dart';

/// Shows [options] under [title] and answers the picked value, or null.
///
/// Each option is one row; picking it closes the sheet and returns [T]. The
/// sheet is prism's own (bottom sheet on a phone, side sheet elsewhere), so
/// dismissal, drag and the surface come from the same place as every other
/// sheet in the app. [selected] marks the current value, which the caller's
/// picker showed as a heavier label.
Future<T?> showOptionSheet<T>({
  required BuildContext context,
  required String title,
  required List<(T, String)> options,
  T? selected,
}) {
  return showSheet<T>(
    context: context,
    builder: (sheetContext) => _OptionSheet<T>(
      title: title,
      options: options,
      selected: selected,
    ),
  );
}

class _OptionSheet<T> extends StatelessWidget {
  const _OptionSheet({required this.title, required this.options, this.selected});

  final String title;
  final List<(T, String)> options;
  final T? selected;

  @override
  Widget build(BuildContext context) {
    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.fromLTRB(16, context.sectionsTopPadding, 16, 24 + context.bottomInset),
      children: [
        generateSection(
          title: title,
          items: [
            for (final (value, label) in options)
              ListItem(
                title: Text(
                  label,
                  style: value == selected
                      ? const TextStyle(fontWeight: FontWeight.bold)
                      : null,
                ),
                trailing: value == selected
                    ? const GlyphIcon(AppGlyphs.check, size: 18)
                    : null,
                onTap: () => Navigator.pop(context, value),
              ),
          ],
        ),
      ],
    );
  }
}
