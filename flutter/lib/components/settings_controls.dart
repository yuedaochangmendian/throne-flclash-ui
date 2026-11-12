import '../widgets.dart';

// Settings controls shared by every settings page. Each writes through
// `settings.set` with the Throne key name, so nothing here introduces a second
// storage or a second restart story.


Widget _enabledSetting(bool enabled, Widget child) =>
    enabled ? child : Opacity(opacity: .38, child: IgnorePointer(child: child));

/// Throne settings that the B-box UI never had.
///
/// They use the same primitives as every other sheet here ([ListItem.toggle],
/// [ListItem.input], [ListItem.options]) and write through `settings.set` with the Throne key name,
/// so nothing here introduces a second storage or a second restart story.
class SettingToggle extends StatelessWidget {
  const SettingToggle(this.title, this.setting, {super.key, this.restart = true, this.autoRestart = false, this.enabled = true});
  final String title, setting;
  final bool restart, autoRestart, enabled;
  @override Widget build(BuildContext context) {
    final box = context.box;
    return _enabledSetting(enabled, ListItem.toggle(
      title: Text(context.tr(title)), value: box.settings[setting] == true,
      onChanged: !enabled || box.serviceSettingsChanging || autoRestart && box.transitioning && !box.remote
        ? null : (value) => box.setSetting(setting, value, restart: restart, autoRestart: autoRestart),
    ));
  }
}

class SettingNumber extends StatelessWidget {
  const SettingNumber(this.title, this.setting, {super.key, this.min, this.max, this.unit, this.autoRestart = false, this.enabled = true});
  final String title, setting;
  final int? min, max;
  final String? unit;
  final bool autoRestart, enabled;
  @override Widget build(BuildContext context) => _enabledSetting(enabled, ListItem.input(
    title: Text(context.tr(title)), dialogTitle: context.tr(title),
    value: (context.box.settings[setting] ?? 0).toString(),
    suffixText: unit, keyboardType: TextInputType.number,
    validator: (value) {
      final number = int.tryParse(value ?? '');
      if (number == null) return context.tr('Invalid number');
      if (min != null && number < min!) return '$min–$max';
      if (max != null && number > max!) return '$min–$max';
      return null;
    },
    onChanged: (value) { if (enabled && value != null) context.box.setSetting(setting, int.parse(value), autoRestart: autoRestart); },
  ));
}

class SettingText extends StatelessWidget {
  const SettingText(this.title, this.setting, {super.key, this.hint, this.restart = true, this.enabled = true});
  final String title, setting;
  final String? hint;
  /// False when the host applies the value on its own next read (a notification text,
  /// say) and no restart badge should appear for a running service.
  final bool restart, enabled;
  @override Widget build(BuildContext context) {
    final value = (context.box.settings[setting] ?? '').toString();
    // The row carries the stored value; the hint (an example, an "empty means…") is the dialog's
    // placeholder, and only stands in on the row while nothing is configured yet.
    return _enabledSetting(enabled, ListItem.input(
      title: Text(context.tr(title)),
      subtitle: value.isEmpty && hint != null ? Text(context.tr(hint!)) : null,
      dialogTitle: context.tr(title), value: value,
      hintText: hint == null ? null : context.tr(hint!),
      onChanged: (value) { if (enabled && value != null) context.box.setSetting(setting, value, restart: restart); },
    ));
  }
}

/// A setting Throne stores as one raw text: the custom inbound and the DNS object are JSON
/// documents, edited here as the text they are until the schema-aware editor takes over.
///
/// Unlike [SettingLines] this writes the string back unchanged — no line splitting, no trimming —
/// because the value is a document, not a list.
class SettingJson extends StatelessWidget {
  const SettingJson(this.title, this.setting, {super.key, this.hint, this.autoRestart = false});
  final String title, setting;
  final String? hint;
  final bool autoRestart;
  @override
  Widget build(BuildContext context) {
    final value = (context.box.settings[setting] ?? '').toString();
    return ListItem(
      title: Text(context.tr(title)),
      subtitle: Text(value.isEmpty ? context.tr(hint ?? 'Empty') : value,
        maxLines: 2, overflow: TextOverflow.ellipsis),
      onTap: () async {
        final saved = await showDialog<String>(
          context: context,
          builder: (context) => _JsonEditor(title: context.tr(title), initial: value, hint: hint),
        );
        if (saved != null && context.mounted) {
          context.box.setSetting(setting, saved, autoRestart: autoRestart);
        }
      },
    );
  }
}

class _JsonEditor extends StatefulWidget {
  const _JsonEditor({required this.title, required this.initial, this.hint});
  final String title, initial;
  final String? hint;
  @override
  State<_JsonEditor> createState() => _JsonEditorState();
}

class _JsonEditorState extends State<_JsonEditor> {
  late final _controller = TextEditingController(text: widget.initial);
  @override
  void dispose() { _controller.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: widget.title,
    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (widget.hint != null) Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(context.tr(widget.hint!), style: AppTextStyle.caption1.of(context)),
      ),
      TextField(
        controller: _controller, minLines: 6, maxLines: 16, autocorrect: false,
        keyboardType: TextInputType.multiline,
        style: const TextStyle(fontFamily: 'JetBrainsMono'),
        decoration: const InputDecoration(border: AppShape.input),
      ),
    ]),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Cancel'))),
      TextButton(onPressed: () => Navigator.pop(context, _controller.text), child: Text(context.tr('Save'))),
    ],
  );
}

/// A DNS server row whose dialog offers the presets and the servers typed before, as the native
/// editable combo box does (DnsServerSuggestions over DnsServerHistory::Fill). A picked server
/// saves and joins the history; the field itself takes anything.
class SettingDnsServer extends StatelessWidget {
  const SettingDnsServer(this.title, this.setting, {super.key, this.hint, required this.kind});
  final String title, setting, kind;
  final String? hint;

  @override Widget build(BuildContext context) {
    final value = (context.box.settings[setting] ?? '').toString();
    return ListItem(
      title: Text(context.tr(title)),
      subtitle: hint == null || value.isNotEmpty ? null : Text(context.tr(hint!)),
      trailing: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 180),
        child: Text(value, overflow: TextOverflow.ellipsis, textAlign: TextAlign.end),
      ),
      onTap: () async {
        // A missing suggestion list (the API is off) only leaves the field freehand.
        var suggestions = const <String>[];
        try {
          final wire = json(await context.box.dnsSuggestions());
          suggestions = (wire[kind] as List? ?? const []).whereType<String>().toList();
        } catch (_) {}
        if (!context.mounted) return;
        final picked = await showDialog<String>(context: context, builder: (context) => _DnsServerDialog(
          title: context.tr(title), initial: value, suggestions: suggestions,
        ));
        if (picked != null && context.mounted) context.box.setSetting(setting, picked);
      },
    );
  }
}

class _DnsServerDialog extends StatefulWidget {
  const _DnsServerDialog({required this.title, required this.initial, required this.suggestions});
  final String title, initial;
  final List<String> suggestions;
  @override State<_DnsServerDialog> createState() => _DnsServerDialogState();
}

class _DnsServerDialogState extends State<_DnsServerDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial);
  @override void dispose() { _controller.dispose(); super.dispose(); }

  @override Widget build(BuildContext context) => AlertDialog(
    title: widget.title,
    child: SizedBox(
      width: 360,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          controller: _controller, autocorrect: false,
          keyboardType: TextInputType.text,
          decoration: const InputDecoration(border: AppShape.input),
        ),
        if (widget.suggestions.isNotEmpty) Flexible(
          child: ListView(shrinkWrap: true, children: [
            for (final server in widget.suggestions)
              ListTile(
                dense: true, title: Text(server),
                onTap: () => Navigator.pop(context, server),
              ),
          ]),
        ),
      ]),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Cancel'))),
      TextButton(onPressed: () => Navigator.pop(context, _controller.text), child: Text(context.tr('Save'))),
    ],
  );
}

class SettingChoice<T> extends StatelessWidget {
  const SettingChoice(this.title, this.setting, {super.key, required this.options, required this.text, this.autoRestart = false, this.enabled = true});
  final String title, setting;
  final List<T> options;
  final String Function(T value) text;
  final bool autoRestart, enabled;
  @override Widget build(BuildContext context) {
    final value = context.box.settings[setting];
    return _enabledSetting(enabled, ListItem<T>.options(
      title: Text(context.tr(title)), options: options, textBuilder: (value) => context.tr(text(value)),
      value: value is T ? value : options.first,
      onChanged: (value) { if (enabled) context.box.setSetting(setting, value, autoRestart: autoRestart); },
    ));
  }
}

/// A setting Throne stores as a list of lines — private ranges, hosts rows, WARP addresses.
///
/// The sheet shows the list inline; editing opens a dialog over it, matching how the other
/// primitives edit a single value rather than pushing a page.
class SettingLines extends StatelessWidget {
  const SettingLines(this.title, this.setting, {super.key, this.hint, this.autoRestart = false});
  final String title, setting;
  final String? hint;
  final bool autoRestart;

  @override Widget build(BuildContext context) {
    // Hosts have kept this setting as a newline string at times, so both shapes are accepted here.
    final raw = context.box.settings[setting];
    final lines = raw is List
        ? raw.whereType<String>().toList()
        : raw is String
            ? raw.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty).toList()
            : const <String>[];
    return ListItem(
      title: Text(context.tr(title)),
      subtitle: lines.isEmpty
          ? Text(context.tr('Built-in defaults'))
          : Text(lines.join(', '), maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => _edit(context, lines),
    );
  }

  Future<void> _edit(BuildContext context, List<String> lines) async {
    final box = context.box;
    final saved = await showDialog<String>(
      context: context,
      builder: (context) => _LinesEditor(
        title: context.tr(title),
        hint: hint == null ? null : context.tr(hint!),
        initial: lines.join('\n'),
      ),
    );
    if (saved != null) {
      final value = saved
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();
      box.setSetting(setting, value, autoRestart: autoRestart);
    }
  }
}

/// The editor body owns its controller so the dialog's closing animation can still
/// touch the [TextField] after the pop future completes.
class _LinesEditor extends StatefulWidget {
  const _LinesEditor({required this.title, required this.initial, this.hint});
  final String title;
  final String initial;
  final String? hint;
  @override
  State<_LinesEditor> createState() => _LinesEditorState();
}

class _LinesEditorState extends State<_LinesEditor> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: widget.title,
    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (widget.hint != null) Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(widget.hint!, style: AppTextStyle.caption1.of(context)),
      ),
      TextField(
        controller: _controller, minLines: 3, maxLines: 10, autocorrect: false,
        keyboardType: TextInputType.multiline,
        decoration: const InputDecoration(border: AppShape.input),
      ),
    ]),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Cancel'))),
      TextButton(onPressed: () => Navigator.pop(context, _controller.text), child: Text(context.tr('Save'))),
    ],
  );
}

/// The page action that returns the listed settings to their Throne defaults: the rows are dropped
/// so every read falls back to the default the schema carries. Each settings page lists its own keys.
IconButtonData restoreDefaultsAction(BuildContext context, List<String> keys) => IconButtonData(
  glyph: AppGlyphs.reset, tooltip: context.tr('Restore defaults'),
  onPressed: () async {
    final box = context.box;
    final ok = await confirm(context, 'Restore defaults?', action: 'Restore',
      message: context.tr('Every setting on this page returns to its Throne default.'));
    if (ok) await box.resetSettings(keys);
  },
);
