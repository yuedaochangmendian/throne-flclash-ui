import 'dart:async';
import 'package:flutter/services.dart';
import '../widgets.dart';
import '../components/form.dart';
import '../components/profile_card.dart';
import 'profile_editor.dart';
import 'profile_details.dart';
import 'group_settings.dart';
import 'protocol_form.dart';

// libbox remote_profile.go stores the display name in the URL fragment.
String remoteProfileLink(Json profile) => Uri(
  scheme: 'sing-box', host: 'import-remote-profile',
  queryParameters: {'url': profile['url'].toString()},
  fragment: profile['name'].toString(),
).toString();

// The typed-form protocols the manual "New node" flow can start from, in the native editor's order.
const manualProtocols = <(String, String)>[
  ('chain', 'Chain Proxy'),
  ('shadowsocks', 'Shadowsocks'), ('vmess', 'VMess'), ('vless', 'VLESS'),
  ('xrayvless', 'VLESS (Xray)'), ('trojan', 'Trojan'), ('hysteria', 'Hysteria'),
  ('tuic', 'TUIC'), ('juicity', 'Juicity'), ('anytls', 'AnyTLS'), ('shadowtls', 'ShadowTLS'),
  ('socks', 'Socks'), ('http', 'HTTP'), ('wireguard', 'WireGuard'), ('masque', 'MASQUE'),
  ('ssh', 'SSH'), ('snell', 'Snell'), ('naive', 'Naive'), ('mieru', 'Mieru'),
  ('trusttunnel', 'TrustTunnel'), ('openconnect', 'OpenConnect'), ('openvpn', 'OpenVPN'),
  ('direct', 'Direct'),
];

class ProfilesPage extends StatefulWidget {
  const ProfilesPage({super.key, this.picker = false});
  final bool picker;
  @override State<ProfilesPage> createState() => _ProfilesPageState();
}
class _ProfilesPageState extends State<ProfilesPage> {
  final _updating = <int>{};
  bool _updatingAll = false;
  Future<void> _update(Json profile) async {
    final id = (profile['id'] as num).toInt();
    if (_updating.contains(id)) return;
    setState(() => _updating.add(id));
    try { await context.box.profileUpdate(id); }
    finally { if (mounted) setState(() => _updating.remove(id)); }
  }
  Future<void> _updateAll() async {
    if (_updatingAll || _updating.isNotEmpty) return;
    final box = context.box;
    final profiles = List<Json>.of(box.profiles).where((p) => p['remote'] == true);
    setState(() => _updatingAll = true);
    try {
      // Native profile writes share a mutex; keep updates serialized.
      for (final profile in profiles) {
        if (!mounted || box.remote) break;
        await _update(profile);
      }
    } finally { if (mounted) setState(() => _updatingAll = false); }
  }
  Future<void> _export(Json profile) async {
    final box = context.box;
    try {
      final content = await box.profileRead(profile['id']);
      await box.documentSave('${profile['name']}.json', content);
    } catch (error) { box.report(error); }
  }
  Future<void> _share(Json profile) async {
    final box = context.box;
    try {
      final content = profile['remote'] == true ? remoteProfileLink(profile) : await box.profileRead(profile['id']);
      await box.shareText(content);
    } catch (error) { box.report(error); }
  }
  List<PopupMenuItem> _menu(Json profile) => [
    PopupMenuItem(glyph: AppGlyphs.edit, label: context.tr('Edit'), onPressed: () => openForm(context, ProfileDetailsPage(profile: profile))),
    if (context.box.remote != true) PopupMenuItem(glyph: AppGlyphs.customize, label: context.tr('Group settings'),
      onPressed: () => openForm(context, GroupSettingsPage(id: (profile['id'] as num).toInt()))),
    if (profile['remote'] == true)
      PopupMenuItem(glyph: AppGlyphs.sync, label: context.tr('Update'), onPressed: () => _update(profile)),
    if (profile['remote'] == true) ...[
      PopupMenuItem(glyph: AppGlyphs.copy, label: context.tr('Copy link'), onPressed: () async {
        await Clipboard.setData(ClipboardData(text: profile['url'].toString()));
        if (mounted) showAppBanner(context, context.tr('Copied'));
      }),
      PopupMenuItem(glyph: AppGlyphs.qrCode, label: context.tr('QR code'), onPressed: () => openForm(context, BoxPage(title: 'QR code', children: [
        Center(child: QrCodeView(data: remoteProfileLink(profile))),
      ]))),
    ],
    PopupMenuItem(glyph: AppGlyphs.upload, label: context.tr('Share'), onPressed: () => _share(profile)),
    PopupMenuItem(glyph: AppGlyphs.export, label: context.tr('Export'), onPressed: () => _export(profile)),
    PopupMenuItem(glyph: AppGlyphs.bolt, label: context.tr('Clear test results'), onPressed: () async {
      final box = context.box;
      if (await confirm(context, context.tr('Clear test results'), action: context.tr('Clear'), message: context.tr('This cannot be undone.'))) {
        await box.profileClearTestResults(profile['id']);
      }
    }),
    PopupMenuItem(glyph: AppGlyphs.dataUsage, label: context.tr('Clear traffic statistics'), onPressed: () async {
      final box = context.box;
      if (await confirm(context, context.tr('Clear traffic statistics'), action: context.tr('Clear'), message: context.tr('This cannot be undone.'))) {
        await box.profileClearTraffic(profile['id']);
      }
    }),
    PopupMenuItem(danger: true, glyph: AppGlyphs.delete, label: context.tr('Delete'), onPressed: () async {
      final box = context.box;
      if (await confirm(context, 'Delete this profile?', message: 'This cannot be undone.')) await box.profileDelete(profile['id']);
    }),
  ];

  @override Widget build(BuildContext context) {
    final box = context.box;
    final profiles = box.profiles;
    return Scaffold(
      title: context.tr('Profiles'),
      actions: box.remote || profiles.isEmpty || widget.picker ? null : [AddProfileMenu(builder: (open) => IconButton(
        tooltip: context.tr('Add profile'), icon: const GlyphIcon(AppGlyphs.addCircle),
        onPressed: open,
      ))],
      iconActions: box.remote || widget.picker || profiles.isEmpty ? const [] : [
        // The television has no notification shade, so the profiles toolbar carries the
        // previous / next server pair (TvControls.addServerSwitch gated on isTv there).
        if (box.capabilities.of('tv') && profiles.length > 1) ...[
          IconButtonData(glyph: AppGlyphs.chevronBack, tooltip: context.tr('Previous server'),
            onPressed: () => box.profileSwitchRelative(-1)),
          IconButtonData(glyph: AppGlyphs.chevronForward, tooltip: context.tr('Next server'),
            onPressed: () => box.profileSwitchRelative(1)),
        ],
        IconButtonData(glyph: AppGlyphs.sync, tooltip: context.tr('Update all'), isLoading: _updatingAll || _updating.isNotEmpty,
          onPressed: _updatingAll || _updating.isNotEmpty || !profiles.any((p) => p['remote'] == true) ? null : _updateAll),
        IconButtonData(glyph: AppGlyphs.sort, tooltip: context.tr('Reorder'), onPressed: profiles.length < 2 ? null : () => openForm(context, const ProfileOrderPage())),
      ],
      body: box.remote ? NullStatus(label: context.tr('Disconnect remote session to edit local profiles'), illustration: NullStatusIllustration.profile) : NullStatusSwitcher(
        isEmpty: profiles.isEmpty,
        nullStatus: NullStatus(
          label: context.tr('No profiles yet'), illustration: NullStatusIllustration.profile,
          description: context.tr('Import a sing-box JSON configuration to get started.'),
          action: AddProfileMenu(builder: (open) => TonalButton(size: TonalButtonSize.bar, glyph: AppGlyphs.addCircle,
            label: context.tr('Add profile'), onPressed: open)),
        ),
        child: _ProfilesGrid(profiles: profiles, selectedId: box.selectedProfileId, picker: widget.picker,
          itemBuilder: (context, profile) => ProfileCard(
            key: ValueKey(profile['id']), profile: profile,
            selected: profile['id'] == box.selectedProfileId,
            updating: _updating.contains(profile['id']),
            menuItems: _menu(profile),
            onPressed: box.transitioning ? null : () async {
              if (box.transitioning || box.remote) return;
              if (await box.profileSelect(profile['id']) && widget.picker && context.mounted) context.safeNestedPop();
            },
          ),
        ),
      ),
    );
  }
}

class _ProfilesGrid extends StatefulWidget {
  const _ProfilesGrid({required this.profiles, required this.selectedId, required this.picker, required this.itemBuilder});
  final List<Json> profiles;
  final int selectedId;
  final bool picker;
  final Widget Function(BuildContext context, Json profile) itemBuilder;
  @override State<_ProfilesGrid> createState() => _ProfilesGridState();
}

class _ProfilesGridState extends State<_ProfilesGrid> {
  late final _scroll = sheetScrollController(context);
  bool _revealed = false;

  @override void dispose() { _scroll.dispose(); super.dispose(); }

  @override Widget build(BuildContext context) {
    final active = PageActivityScope.isActiveOf(context);
    final spacing = (context.isMobileView ? 8.0 : 12.0).mAp(context);
    final padding = EdgeInsets.fromLTRB(16, context.contentTopPadding, 16, 16 + context.bottomInset);
    final height = profileCardHeight(context);
    return LayoutBuilder(builder: (context, constraints) {
      final columns = ((constraints.maxWidth - 32 + spacing) / (300.ap(context) + spacing)).floor().clamp(1, 3);
      if (!_revealed && !widget.picker && active && widget.profiles.isNotEmpty) {
        _revealed = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scroll.hasClients) return;
          final index = widget.profiles.indexWhere((p) => p['id'] == widget.selectedId);
          if (index < 0) return;
          final position = _scroll.position;
          final top = (index ~/ columns) * (height + spacing);
          final bottom = top + padding.vertical + height - position.viewportDimension;
          if (position.pixels >= bottom && position.pixels <= top) return;
          _scroll.jumpTo(((top + bottom) / 2).clamp(position.minScrollExtent, position.maxScrollExtent));
        });
      }
      return GridView.builder(
        key: PageStorageKey(widget.picker ? 'profile-picker' : 'profiles'),
        controller: _scroll, padding: padding,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: columns,
          mainAxisSpacing: spacing, crossAxisSpacing: spacing, mainAxisExtent: height),
        itemCount: widget.profiles.length,
        itemBuilder: (context, index) => widget.itemBuilder(context, widget.profiles[index]),
      );
    });
  }
}

Future<void> _importProfile(BuildContext context, String source) async {
  final box = context.box;
  final emptyClipboard = context.tr('Empty clipboard');
  try {
    Json? data;
    switch (source) {
      case 'File':
        final result = await box.profileImportFile();
        if (result != null) data = json(result);
      case 'Clipboard':
        final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
        if (text == null || text.isEmpty) throw StateError(emptyClipboard);
        data = await decodeImport(box, text);
      case 'Scan QR code':
        data = await openPage<Json>(context, const ScanPage());
    }
    if (data != null && context.mounted) await openForm(context, ProfileForm(initial: data));
  } catch (error) { box.report(error); }
}

class AddProfileMenu extends StatefulWidget {
  const AddProfileMenu({super.key, required this.builder});
  final Widget Function(PopupOpen open) builder;
  @override State<AddProfileMenu> createState() => _AddProfileMenuState();
}

class _AddProfileMenuState extends State<AddProfileMenu> {
  bool _busy = false;
  Future<void> _import(String source) async {
    if (_busy) return;
    setState(() => _busy = true);
    try { await _importProfile(context, source); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  Future<void> _createSelector() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // The new selector tracks the group the user is looking at, not whichever group happens to be first.
      if (mounted) await openPage(context, const AutoSelectorPage(id: 0));
    } catch (error) { if (mounted) context.box.report(error); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  Future<void> _createNode(String type) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // A fresh node of the chosen protocol, opened straight into the typed form.
      final info = json(await context.box.profileCreateNode(context.box.selectedProfileId, type));
      if (mounted) await openForm(context, ProtocolFormPage(id: 0, draft: info));
    } catch (error) { if (mounted) context.box.report(error); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  @override Widget build(BuildContext context) => AbsorbPointer(absorbing: _busy, child: PopupAnchor(
    targetBuilder: widget.builder,
    popupBuilder: (_) => PopupMenu(items: [
      PopupMenuItem(glyph: AppGlyphs.qrCode, label: context.tr('Scan QR code'), onPressed: () => _import('Scan QR code')),
      PopupMenuItem(glyph: AppGlyphs.importFile, label: context.tr('File'), onPressed: () => _import('File')),
      PopupMenuItem(glyph: AppGlyphs.cloudDownload, label: context.tr('Import from URL'),
        onPressed: () => openForm(context, const ProfileForm(initial: {'url': '', 'remote': true}))),
      PopupMenuItem(glyph: AppGlyphs.copy, label: context.tr('Clipboard'), onPressed: () => _import('Clipboard')),
      PopupMenuItem(section: const PopupMenuSection(), glyph: AppGlyphs.add, label: context.tr('New node'), subItems: [
        for (final (type, label) in manualProtocols)
          PopupMenuItem(label: label, onPressed: () => _createNode(type)),
      ]),
      PopupMenuItem(glyph: AppGlyphs.customize,
        label: context.tr('New profile'), onPressed: () => openForm(context, const ProfileForm(initial: {'content': '{}'}))),
      PopupMenuItem(glyph: AppGlyphs.shuffle, label: context.tr('Auto selector'), onPressed: _createSelector),
    ]),
  ));
}

class AddProfilePage extends StatefulWidget {
  const AddProfilePage({super.key});
  @override State<AddProfilePage> createState() => _AddProfilePageState();
}
class _AddProfilePageState extends State<AddProfilePage> {
  bool _loading = false;
  Future<void> _import(String source) async {
    if (_loading) return;
    setState(() => _loading = true);
    try { await _importProfile(context, source); }
    finally { if (mounted) setState(() => _loading = false); }
  }
  Future<void> _createSelector() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      // The new selector tracks the group the user is looking at, not whichever group happens to be first.
      if (mounted) await openPage(context, const AutoSelectorPage(id: 0));
    } catch (error) { if (mounted) context.box.report(error); }
    finally { if (mounted) setState(() => _loading = false); }
  }
  Future<void> _createNode(String type) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final info = json(await context.box.profileCreateNode(context.box.selectedProfileId, type));
      if (mounted) await openForm(context, ProtocolFormPage(id: 0, draft: info));
    } catch (error) { if (mounted) context.box.report(error); }
    finally { if (mounted) setState(() => _loading = false); }
  }
  Future<void> _pickNode() async {
    if (_loading) return;
    final type = await showDialog<String>(context: context, builder: (context) => SimpleDialog(
      title: Text(context.tr('New node')),
      children: [
        for (final (type, label) in manualProtocols)
          SimpleDialogOption(onPressed: () => Navigator.pop(context, type), child: Text(label)),
      ],
    ));
    if (type == null || !mounted) return;
    await _createNode(type);
  }
  @override Widget build(BuildContext context) => BoxPage(
    title: 'Add profile', loading: _loading,
    children: [
      generateSection(items: [
        ListItem.open(leading: const GlyphIcon(AppGlyphs.link), title: Text(context.tr('Import from URL')),
          widget: const ProfileForm(initial: {'url': '', 'remote': true}), forceFull: false),
        for (final item in [('File', AppGlyphs.profiles), ('Clipboard', AppGlyphs.copy), ('Scan QR code', AppGlyphs.qrCode)])
          ListItem(leading: GlyphIcon(item.$2), title: Text(context.tr(item.$1)), onTap: _loading ? null : () => _import(item.$1)),
        ListItem(leading: const GlyphIcon(AppGlyphs.add), title: Text(context.tr('New node')),
          onTap: _loading ? null : _pickNode),
        ListItem.open(leading: const GlyphIcon(AppGlyphs.add), title: Text(context.tr('New profile')),
          widget: const ProfileForm(initial: {'content': '{}'}), forceFull: false),
        ListItem(leading: const GlyphIcon(AppGlyphs.shuffle), title: Text(context.tr('Auto selector')),
          onTap: _loading ? null : _createSelector),
      ], footer: context.tr('This URL must serve a sing-box JSON configuration.')),
    ],
  );
}

Future<Json> decodeImport(BoxController box, String text) async {
  // The host runs Throne's own importer: share links, base64 subscriptions and JSON/YAML documents
  // all come back as the same editor draft, and invalid text reports the importer's own reason.
  return json(await box.profileDecodeIntent(text.trim()));
}

class ProfileForm extends StatefulWidget {
  const ProfileForm({super.key, required this.initial});
  final Json initial;
  @override State<ProfileForm> createState() => _ProfileFormState();
}
class _ProfileFormState extends State<ProfileForm> {
  late final _name = TextEditingController(text: widget.initial['name'] as String? ?? '');
  late final _url = TextEditingController(text: widget.initial['url'] as String? ?? '');
  late final _interval = TextEditingController(text: (widget.initial['interval'] ?? 60).toString());
  late bool _remote = widget.initial['remote'] == true || _url.text.isNotEmpty;
  late bool _auto = widget.initial['autoUpdate'] != false;
  bool _saving = false, _attempted = false;
  String? _errorMessage;
  int? _groupId;

  ({String field, String message})? get _issue {
    if (_name.text.trim().isEmpty) return (field: 'name', message: '${context.tr('Name')}: ${context.tr('Required')}');
    if (!_remote) return null;
    final uri = Uri.tryParse(_url.text.trim());
    if (uri == null || !['http', 'https'].contains(uri.scheme) || uri.host.isEmpty) {
      return (field: 'url', message: context.tr('sing-box JSON URL'));
    }
    if (_auto && (int.tryParse(_interval.text) ?? 0) < 15) {
      return (field: 'interval', message: context.tr('At least 15 minutes'));
    }
    return null;
  }
  void _changed(String _) { if (_attempted) setState(() { _errorMessage = null; }); }

  @override void dispose() { _name.dispose(); _url.dispose(); _interval.dispose(); super.dispose(); }
  Future<void> _save() async {
    if (_saving) return;
    final imported = (widget.initial['nodeCount'] as num?)?.toInt();
    final needsGroup = imported == 1 && context.box.profiles.length > 1;
    if (needsGroup && _groupId == null) {
      setState(() { _attempted = true; _errorMessage = context.tr('Target group'); });
      return;
    }
    if (_issue != null) { setState(() => _attempted = true); return; }
    final box = context.box;
    setState(() => _saving = true);
    try {
      final interval = int.tryParse(_interval.text);
      final previousInterval = (widget.initial['interval'] as num?)?.toInt() ?? 60;
      await box.profileSave({
        ...widget.initial, 'name': _name.text.trim(), 'url': _remote ? _url.text.trim() : '',
        if (needsGroup && _groupId != null) 'groupId': _groupId,
        'autoUpdate': _remote && _auto,
        'interval': interval != null && interval >= 15 ? interval : previousInterval >= 15 ? previousInterval : 60,
      });
      if (mounted) context.safeNestedPop();
    } catch (error) { box.report(error); }
    if (mounted) setState(() => _saving = false);
  }
  @override Widget build(BuildContext context) {
    final issue = _attempted ? _issue : null;
    final imported = (widget.initial['nodeCount'] as num?)?.toInt();
    final groups = context.box.profiles;
    final needsGroup = imported == 1 && groups.length > 1;
    return FormPage(
      title: widget.initial['id'] == null ? 'Add profile' : 'Edit',
      saving: _saving, onSave: _save, error: _errorMessage ?? issue?.message,
      children: [
        if (needsGroup) generateSection(title: context.tr('Target group'), items: [
          for (final group in groups)
            ListItem(title: Text(group['name'].toString()), trailing: _groupId == (group['id'] as num?)?.toInt()
              ? const GlyphIcon(AppGlyphs.checkCircle) : null,
              onTap: () => setState(() => _groupId = (group['id'] as num?)?.toInt())),
        ]),
        generateSection(items: [
          FormRow(title: context.tr('Name'), invalid: issue?.field == 'name',
            trailing: FormRowTextField(controller: _name, hintText: context.tr('Required'),
              textInputAction: TextInputAction.next, onChanged: _changed)),
          FormRow(title: context.tr('Remote'), onPressed: () => setState(() => _remote = !_remote),
            trailing: Switch(value: _remote, onChanged: (value) => setState(() => _remote = value))),
          if (_remote) FormRow(title: context.tr('URL'), invalid: issue?.field == 'url',
            trailing: FormRowTextField(controller: _url, hintText: context.tr('Required'),
              keyboardType: TextInputType.text, textInputAction: TextInputAction.next,
              autocorrect: false, onChanged: _changed)),
        ], footer: _remote
            ? context.tr('This URL must serve a sing-box JSON configuration.')
            : imported == null ? null : imported == 1 && groups.isEmpty
                ? context.tr('One node will be imported into the Default group.')
                : '$imported ${context.tr('nodes will be imported.')}'),
        if (_remote) generateSection(items: [
          FormRow(title: context.tr('Auto update'), onPressed: () => setState(() => _auto = !_auto),
            trailing: Switch(value: _auto, onChanged: (value) => setState(() => _auto = value))),
          if (_auto) FormRow(title: context.tr('Update interval'), invalid: issue?.field == 'interval',
            trailing: Row(mainAxisSize: MainAxisSize.min, spacing: 4, children: [
              Flexible(child: FormRowTextField(controller: _interval, hintText: context.tr('Required'),
                keyboardType: TextInputType.number, textInputAction: TextInputAction.done,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly], onChanged: _changed)),
              Text(context.tr('minutes'), style: AppTextStyle.subheadline.of(context)),
            ])),
        ], footer: _auto ? context.tr('At least 15 minutes') : null),
        if (widget.initial['id'] != null) generateSection(items: [
          ListItem.open(title: Text(context.tr('Open configuration')), leading: const GlyphIcon(AppGlyphs.code),
            widget: ProfileEditor(profile: widget.initial)),
          ListItem(title: Text(context.tr('Last updated')), subtitle: Text(
            (widget.initial['updatedAt'] as num? ?? 0) <= 0 ? context.tr('Unknown') : localDate(widget.initial['updatedAt']))),
        ]),
      ],
    );
  }
}

class ProfileOrderPage extends StatefulWidget {
  const ProfileOrderPage({super.key});
  @override State<ProfileOrderPage> createState() => _ProfileOrderPageState();
}
class _ProfileOrderPageState extends State<ProfileOrderPage> {
  List<Json>? _profiles;
  bool _saving = false;
  Widget _item(int index) => ReorderableDelayedDragStartListener(
    key: ValueKey(_profiles![index]['id']), index: index,
    child: ItemPositionProvider(position: ItemPosition.get(index, _profiles!.length),
      child: DecorationListItem(contentPadding: const EdgeInsets.only(left: 16),
        title: Text(_profiles![index]['name'].toString()), trailing: SortHandle(index: index))),
  );
  @override Widget build(BuildContext context) {
    _profiles ??= List.of(context.box.profiles);
    return Scaffold(title: context.tr('Reorder'),
      confirmationAction: IconButtonData(glyph: AppGlyphs.check, tooltip: context.tr('Save'), isLoading: _saving, onPressed: _saving ? null : () async {
        setState(() => _saving = true);
        final saved = await context.box.profileReorder(_profiles!.map((p) => p['id']).toList());
        if (!context.mounted) return;
        if (saved) {
          context.safeNestedPop();
        } else {
          setState(() => _saving = false);
        }
      }),
      body: AbsorbPointer(absorbing: _saving, child: ReorderableListView.builder(
        buildDefaultDragHandles: false,
        padding: EdgeInsets.fromLTRB(16, context.contentTopPadding, 16, 32 + context.bottomInset),
        itemCount: _profiles!.length,
        proxyDecorator: (child, index, animation) => commonProxyDecorator(_item(index), index, animation),
        onReorderItem: (old, next) => setState(() => _profiles!.insert(next, _profiles!.removeAt(old))),
        itemBuilder: (_, index) => _item(index),
      )),
    );
  }
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override State<ScanPage> createState() => _ScanPageState();
}
class _ScanPageState extends State<ScanPage> {
  BoxController? _box;
  bool _busy = false;
  String? _error;

  @override void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startScan());
  }

  @override void didChangeDependencies() { super.didChangeDependencies(); _box ??= context.box; }

  /// The camera now lives in the host's ZXing activity, not in a Flutter plugin:
  /// one channel call opens it and the decoded payload (multi-frame symbols are
  /// assembled on the host) comes back when it closes. A refused permission or a
  /// dismissed activity leaves a retry on screen instead of a black preview.
  Future<void> _startScan() async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      final granted = await _box!.ensureCameraPermission();
      if (!mounted) return;
      if (!granted) {
        setState(() => _error = 'The camera permission is denied. Grant it in the system settings, then try again.');
        return;
      }
      final text = await _box!.scanQrCode();
      if (!mounted) return;
      if (text == null || text.isEmpty) {
        setState(() => _error = 'Scanning was cancelled. Tap retry to open the camera again.');
        return;
      }
      final profile = await decodeImport(_box!, text);
      if (mounted) context.safeNestedPop(profile);
    } catch (error) {
      if (mounted) setState(() => _error = BoxController.describe(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
  @override Widget build(BuildContext context) => Scaffold(
    title: context.tr('Scan QR code'),
    body: Padding(padding: EdgeInsets.only(top: context.appBarInset), child: Center(child: Padding(
      padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, spacing: 16, children: [
        if (_error != null) ErrorState(context.tr(_error!), retry: _startScan)
        else ...[
          if (_busy) const CircularProgressIndicator(),
          Text(
            context.tr('The camera opens in the scanning screen. Point it at a configuration QR code.'),
            textAlign: TextAlign.center,
            style: AppTextStyle.subheadline.of(context),
          ),
          if (_busy) Text(context.tr('Waiting for a QR code…'),
              style: AppTextStyle.footnote.of(context).copyWith(color: context.colorScheme.onSurfaceVariant)),
        ],
      ]),
    ))),
  );
}
