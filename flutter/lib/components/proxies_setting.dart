// FlClash's ProxiesSetting sheet: every display choice in one place.
//
// The controls used to be a chain of `PopupMenuItem` sub-menus in the overflow
// menu — a nested popup two levels deep, where only the last level showed what
// the current value was. FlClash's shape is one bottom sheet of horizontal chip
// groups, each row showing every option at once with the active one filled. This
// is that sheet, built from the app's own prism primitives (`showSheet` +
// `generateSection` + `ListItem`), not a new vocabulary.

import '../widgets.dart';

/// One choice row: a title and the options as chips in a row.
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.title,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String title;
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: context.listCaptionStyle),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in options)
                Chip(
                  label: context.tr(option),
                  selected: option == value,
                  onPressed: () => onChanged(option),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Shows the display settings and answers nothing: every tap writes through
/// `box.setPreference` so the page behind re-renders live, which is how FlClash's
/// sheet behaves.
Future<void> showProxiesSetting(BuildContext context) => showSheet<void>(
      context: context,
      builder: (_) => const ProxiesSettingSheet(),
    );

class ProxiesSettingSheet extends StatelessWidget {
  const ProxiesSettingSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final box = context.box;
    final prefs = box.preferences;
    String read(String key, String fallback) =>
        (prefs[key] ?? fallback).toString();
    void write(String key, String value) => box.setPreference(key, value);

    final list = read('proxyLayout', 'Tabs') == 'List';

    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.fromLTRB(0, context.sectionsTopPadding, 0, 24 + context.bottomInset),
      children: [
        generateSection(title: context.tr('Appearance'), items: [
          _ChoiceRow(
            title: context.tr('Style'),
            value: read('proxyLayout', 'Tabs'),
            options: const ['Tabs', 'List'],
            onChanged: (value) => write('proxyLayout', value),
          ),
          _ChoiceRow(
            title: context.tr('Sort'),
            value: read('proxySort', 'Default'),
            options: const ['Default', 'Latency', 'Name'],
            onChanged: (value) => write('proxySort', value),
          ),
          _ChoiceRow(
            title: context.tr('Layout'),
            value: read('proxyDensity', 'Standard'),
            options: const ['Tight', 'Standard', 'Loose'],
            onChanged: (value) => write('proxyDensity', value),
          ),
          _ChoiceRow(
            title: context.tr('Size'),
            value: read('proxyCardSize', 'Standard'),
            options: const ['Compact', 'Standard', 'Loose'],
            onChanged: (value) => write('proxyCardSize', value),
          ),
          if (list)
            _ChoiceRow(
              title: context.tr('Icon style'),
              value: read('proxyIconStyle', 'Filled'),
              options: const ['Filled', 'Plain', 'Hidden'],
              onChanged: (value) => write('proxyIconStyle', value),
            ),
        ]),
        generateSection(title: context.tr('Behaviour'), items: [
          ListItem(
            title: Text(context.tr('Hide timeout proxies')),
            trailing: Switch(
              value: prefs['hideTimeoutProxies'] == true,
              onChanged: (value) => box.setPreference('hideTimeoutProxies', value),
            ),
          ),
          ListItem(
            title: Text(context.tr('Close connections after switching')),
            trailing: Switch(
              value: prefs['closeConnectionsOnSelect'] == true,
              onChanged: (value) =>
                  box.setPreference('closeConnectionsOnSelect', value),
            ),
          ),
        ]),
      ],
    );
  }
}
