import '../widgets.dart';
import 'access.dart';
import 'appearance.dart';
import 'backup.dart';

export 'appearance.dart';
export 'access.dart';
export 'about.dart';
export 'backup.dart';

/// A host setting rendered as a switch, as every service setting upstream is.
class NativeToggle extends StatelessWidget {
  const NativeToggle(this.title, this.setting, {super.key, this.restart = true, this.autoRestart = false});
  final String title, setting;
  final bool restart, autoRestart;
  @override Widget build(BuildContext context) {
    final box = context.box;
    return ListItem.toggle(
      title: Text(context.tr(title)), value: box.settings[setting] == true,
      onChanged: box.serviceSettingsChanging || autoRestart && box.transitioning && !box.remote
        ? null : (value) => box.setSetting(setting, value, restart: restart, autoRestart: autoRestart),
    );
  }
}

/// The settings entries in Throne's `global_preferences.xml` order. The Tools page lists them
/// directly, so every setting is one tap from the drawer and there is no Settings page in between.
///
/// Inbound, TUN, routing, DNS and the rest are pages of their own rather than items behind a
/// "General" container; General is the connection/behaviour page upstream calls General.
List<ListItem> settingsEntries(BuildContext context) {
  return [
    ListItem.open(leading: const GlyphIcon(AppGlyphs.settings), title: Text(context.tr('General')), widget: const GeneralPage()),
    ListItem.open(leading: const GlyphIcon(AppGlyphs.status), title: Text(context.tr('Notification')), widget: const NotificationPage()),
    ListItem.open(leading: const GlyphIcon(AppGlyphs.paintbrush), title: Text(context.tr('Appearance')), widget: const AppearancePage()),
    ListItem.open(leading: const GlyphIcon(AppGlyphs.devices), title: Text(context.tr('Inbound')), widget: const InboundPage()),
    ListItem.open(leading: const GlyphIcon(AppGlyphs.split), title: Text(context.tr('TUN')), widget: const TunPage()),
    ListItem.open(leading: const GlyphIcon(AppGlyphs.rules), title: Text(context.tr('Routing')), widget: const RoutingPage()),
    ListItem.open(leading: const GlyphIcon(AppGlyphs.dns), title: Text(context.tr('DNS')), widget: const DnsPage()),
    ListItem.open(leading: const GlyphIcon(AppGlyphs.sliders), title: Text(context.tr('Node presets')), widget: const PresetsPage()),
    ListItem.open(leading: const GlyphIcon(AppGlyphs.speed), title: Text(context.tr('Testing')), widget: const TestingPage()),
    ListItem.open(leading: const GlyphIcon(AppGlyphs.profiles), title: Text(context.tr('Subscriptions')), widget: const SubscriptionPage()),
    ListItem.open(leading: const GlyphIcon(AppGlyphs.cpu), title: Text(context.tr('Core')), widget: const CorePage()),
    ListItem.open(leading: const GlyphIcon(AppGlyphs.appsList), title: Text(context.tr('Access control')), widget: const AccessPage()),
    ListItem.open(leading: const GlyphIcon(AppGlyphs.cloudSync), title: Text(context.tr('Backup and restore')), widget: const BackupPage()),
  ];
}

/// The service notification's rows, one tap from the settings list. They used to
/// live on the General page, where they outgrew the section they were squeezed into.
class NotificationPage extends StatelessWidget {
  const NotificationPage({super.key});
  @override Widget build(BuildContext context) {
    return BoxPage(title: 'Notification', children: [
      generateSection(items: [
        // Both are read by the host on its next update, so they need no core restart.
        const NativeToggle('Show group name in the notification', 'showGroupInNotification', restart: false),
        const NativeToggle('Show proxy speed', 'showProxySpeed', restart: false),
        const NativeToggle('Show direct speed', 'showDirectSpeed', restart: false),
        const NativeToggle('Show traffic total', 'showTrafficTotal', restart: false),
        const SettingText('Notification title template', 'notificationTitleTemplate',
            hint: 'Use {title} for the profile name, for example 🚀 {title}', restart: false),
        const SettingText('Notification content template', 'notificationContentTemplate',
            hint: 'Leave empty for the built-in speed line; {up} {down} {totalUp} {totalDown}', restart: false),
        const NotificationActionsSetting(),
      ]),
    ]);
  }
}

/// Throne's General page: connection, behaviour, and the update entry upstream keeps here.
///
/// Removed here, because Throne has no equivalent: auto redirect, dynamic notification, deprecation
/// warnings, the core memory killer and its limit, and power reports.
class GeneralPage extends StatelessWidget {
  const GeneralPage({super.key});
  @override Widget build(BuildContext context) {
    final caps = context.box.capabilities;
    return BoxPage(title: 'General', loading: context.box.serviceSettingsChanging, children: [
      generateSection(items: [
        ListItem<String>.options(
          title: Text(context.tr('Service mode')), options: const ['vpn', 'proxy'],
          value: context.box.settings['serviceMode'] == 'proxy' ? 'proxy' : 'vpn',
          textBuilder: (value) => context.tr(value == 'vpn' ? 'VPN' : 'Proxy only'),
          onChanged: (value) => context.box.setSetting('serviceMode', value, autoRestart: true),
        ),
        // "Allow bypass" lives on the Access screen as the per-app mode; the private-range switch is
        // under TUN, because upstream keeps them in two different stores.
        const NativeToggle('Always show the address', 'alwaysShowAddress', restart: false),
        // The notification rows are a page of their own on the settings list.
      ]),
      generateSection(title: context.tr('Connections'), items: [
        const NativeToggle('Reset connections on network change', 'networkChangeResetConnections', restart: false),
        const NativeToggle('Reset connections when waking up', 'wakeResetConnections', restart: false),
      ]),
      generateSection(title: context.tr('Behaviour'), items: [
        const NativeToggle('Connect after reboot', 'rememberEnable', restart: false),
        const NativeToggle('Hide from recent apps', 'hideFromRecentApps', restart: false),
        const NativeToggle('Treat the VPN as metered', 'meteredNetwork', autoRestart: true),
        const NativeToggle('Skip delete confirmation', 'skipDeleteConfirmation', restart: false),
        // A failed rule-set download normally blocks a start; this lets the core come up anyway.
        const NativeToggle('Start without rule sets', 'startWithoutRuleSets', restart: false),
        ListItem(title: Text(context.tr('Battery optimization')),
          subtitle: Text(context.tr(context.box.settings['batteryExempt'] == true ? 'Unrestricted' : 'Allow background operation')),
          onTap: () => context.box.batteryOpen()),
      ]),
      // Upstream keeps the two update switches in a section of this page.
      if (caps.of('update')) generateSection(title: context.tr('Updates'), items: [
        ListItem.open(leading: const GlyphIcon(AppGlyphs.sync), title: Text(context.tr('Update settings')), widget: const UpdatePage()),
      ]),
    ]);
  }
}

/// The service notification's buttons. The host keeps a fixed order (stop, previous, next,
/// switch, reset) and shows the first three enabled ones, so the picker is a checkbox list
/// and whatever it saves is re-ordered and truncated by `ServiceNotification` itself.
///
/// An empty selection is valid and means "no buttons"; a missing key (older host) renders as
/// the built-in default set.
class NotificationActionsSetting extends StatelessWidget {
  const NotificationActionsSetting({super.key});

  /// The host's button ids in its `ACTION_ORDER`, with the label the dialog shows.
  static const actions = <(String, String)>[
    ('stop', 'Stop'),
    ('previous', 'Previous'),
    ('next', 'Next'),
    ('switch', 'Switch…'),
    ('reset', 'Reset connections'),
  ];

  static const defaults = <String>['stop', 'next', 'switch'];

  @override
  Widget build(BuildContext context) {
    final box = context.box;
    final raw = box.settings['notificationActions'];
    final selected = raw is List ? raw.whereType<String>().toList() : defaults;
    return ListItem(
      title: Text(context.tr('Notification buttons')),
      subtitle: Text(_summary(context, selected), maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () async {
        final saved = await showDialog<List<String>>(
          context: context,
          builder: (context) => _NotificationActionsEditor(initial: selected),
        );
        if (saved != null) await box.setSetting('notificationActions', saved, restart: false);
      },
    );
  }

  String _summary(BuildContext context, List<String> selected) {
    if (selected.isEmpty) return context.tr('None');
    final names = selected.map((id) => _label(context, id));
    return names.join(', ');
  }

  String _label(BuildContext context, String id) => context.tr(
      actions.firstWhere((action) => action.$1 == id, orElse: () => (id, id)).$2);
}

class _NotificationActionsEditor extends StatefulWidget {
  const _NotificationActionsEditor({required this.initial});

  final List<String> initial;

  @override
  State<_NotificationActionsEditor> createState() => _NotificationActionsEditorState();
}

class _NotificationActionsEditorState extends State<_NotificationActionsEditor> {
  late final Set<String> _selected = {...widget.initial};

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: context.tr('Notification buttons'),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Cancel'))),
      TextButton(
        // Keep the host's order, not the dialog's: the save is what the service reads.
        onPressed: () => Navigator.pop(context,
            NotificationActionsSetting.actions.map((a) => a.$1).where(_selected.contains).toList()),
        child: Text(context.tr('Save')),
      ),
    ],
    child: Material(
      type: MaterialType.transparency,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(context.tr('The first three of the enabled ones show, in a fixed order'),
              style: AppTextStyle.caption1.of(context)),
        ),
        for (final (id, label) in NotificationActionsSetting.actions)
          CheckboxListTile(
            value: _selected.contains(id),
            title: Text(context.tr(label)),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            onChanged: (value) => setState(() {
              if (value == true) {
                _selected.add(id);
              } else {
                _selected.remove(id);
              }
            }),
          ),
      ]),
    ),
  );
}

class RemotePage extends StatefulWidget {
  const RemotePage({super.key});
  @override State<RemotePage> createState() => _RemotePageState();
}
class _RemotePageState extends State<RemotePage> {
  Future<List<Json>>? _servers;
  @override void didChangeDependencies() { super.didChangeDependencies(); _servers ??= _load(); }
  Future<List<Json>> _load() async => rows(await context.box.remoteList());
  Future<void> _edit([Json? server]) async {
    await openForm(context, RemoteForm(initial: server ?? {}));
    if (mounted) setState(() => _servers = _load());
  }
  @override Widget build(BuildContext context) => Scaffold(
    title: context.tr('Remote control'),
    primaryAction: IconButtonData(glyph: AppGlyphs.add, tooltip: context.tr('Add server'), onPressed: _edit),
    body: FutureBuilder<List<Json>>(future: _servers, builder: (context, snapshot) => ListView(
      padding: EdgeInsets.fromLTRB(16, context.contentTopPadding, 16, 24 + context.bottomInset),
      children: [
        if (context.box.remote) ListItem(title: Text(context.box.dashboard['remote'].toString()), trailing: TextButton(
          onPressed: () => context.box.remoteDisconnect(), child: Text(context.tr('Disconnect')))),
        if (snapshot.hasError) ErrorState(snapshot.error!),
        if (snapshot.hasData && snapshot.data!.isEmpty) const EmptyState('No remote servers'),
        for (final server in snapshot.data ?? <Json>[]) Padding(padding: const EdgeInsets.only(bottom: 12), child: Card(
          onPressed: () => context.box.remoteConnect(server['id']),
          child: ListItem(title: Text(server['name'].toString()), subtitle: Text(server['url'].toString()), trailing: BoxMenu(items: [
            PopupMenuItem(glyph: AppGlyphs.edit, label: context.tr('Edit'), onPressed: () => _edit(server)),
            PopupMenuItem(glyph: AppGlyphs.delete, label: context.tr('Delete'), danger: true, onPressed: () async {
              if (await confirm(context, 'Delete', message: server['name'].toString()) && context.mounted) {
                await context.box.remoteDelete(server['id']);
                if (mounted) setState(() => _servers = _load());
              }
            }),
          ])),
        )),
      ],
    )),
  );
}

class RemoteForm extends StatefulWidget {
  const RemoteForm({super.key, required this.initial});
  final Json initial;
  @override State<RemoteForm> createState() => _RemoteFormState();
}
class _RemoteFormState extends State<RemoteForm> {
  late final _name = TextEditingController(text: widget.initial['name'] as String? ?? '');
  late final _url = TextEditingController(text: widget.initial['url'] as String? ?? '');
  late final _secret = TextEditingController(text: widget.initial['secret'] as String? ?? '');
  bool _saving = false;
  @override void dispose() { _name.dispose(); _url.dispose(); _secret.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => BoxPage(title: 'Remote control', loading: _saving,
    confirmationAction: IconButtonData(glyph: AppGlyphs.check, tooltip: context.tr('Save'), onPressed: _saving ? null : () async {
      setState(() => _saving = true);
      final saved = await context.box.remoteSave({...widget.initial, 'name': _name.text, 'url': _url.text, 'secret': _secret.text});
      if (context.mounted) {
        setState(() => _saving = false);
        if (saved) context.safeNestedPop();
      }
    }),
    children: [
      TextField(controller: _name, decoration: InputDecoration(labelText: context.tr('Name'))),
      const SizedBox(height: 16),
      TextField(controller: _url, keyboardType: TextInputType.text, decoration: InputDecoration(labelText: context.tr('Address'))),
      const SizedBox(height: 16),
      TextField(controller: _secret, obscureText: true, decoration: InputDecoration(labelText: context.tr('Secret'))),
    ],
  );
}
