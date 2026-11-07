// Route profiles: the list of named rule sets and which one builds every
// configuration without a group override.

import '../widgets.dart';

/// Route profiles: the named rule sets a configuration is built with, one of them the global choice.
///
/// The list shows every profile and which one is current; the editor holds the name, the default
/// outbound, the remote subscription and the simple address rules as `prefix:value -> outbound`
/// lines — the same shape the native importer accepts.
class RouteProfilesPage extends StatefulWidget {
  const RouteProfilesPage({super.key});
  @override
  State<RouteProfilesPage> createState() => _RouteProfilesPageState();
}

class _RouteProfilesPageState extends State<RouteProfilesPage> {
  List<Json> _profiles = const [];
  int _currentId = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      // The source reads Room's file over dart:ffi and falls back to
      // `routes.list` over the channel on any failure; the page does not care
      // which one answered.
      final data = json(await context.box.routeProfiles.list());
      if (!mounted) return;
      setState(() {
        _profiles = (data['profiles'] as List? ?? const []).map((item) => json(item)).toList();
        _currentId = (data['currentId'] as num?)?.toInt() ?? 0;
        _loading = false;
      });
    } catch (error) {
      if (mounted) setState(() => _loading = false);
      if (mounted) context.box.report(error);
    }
  }

  Future<void> _open(Json profile) async {
    await openPage(context, RouteEditorPage(id: (profile['id'] as num?)?.toInt() ?? 0));
    if (mounted) await _load();
  }

  /// The official routeprofiles bundles: pick a country and its remote profiles are added,
  /// prefilled from the snapshot and fetched online — the native "Download profiles" flow.
  Future<void> _addPresets() async {
    final box = context.box;
    List<Json> bundles;
    try {
      final data = json(await box.routePresets());
      bundles = (data['bundles'] as List? ?? const []).map((e) => json(e)).toList();
    } catch (error) {
      box.report(error);
      return;
    }
    if (!mounted) return;
    if (bundles.isEmpty) {
      box.report(StateError(context.tr('No official profiles are bundled in this build')));
      return;
    }
    final picked = await showDialog<Json>(context: context, builder: (context) => SimpleDialog(
      title: Text(context.tr('Throne official profiles')),
      children: [
        for (final bundle in bundles)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, bundle),
            child: Text('${bundle['country']} (${((bundle['entries'] as List?) ?? const []).length})'),
          ),
      ],
    ));
    if (picked == null || !mounted) return;
    try {
      final result = json(await box.routeAddPreset(picked['country']));
      final added = (result['added'] as num?)?.toInt() ?? 0;
      if (mounted) {
        showAppBanner(context, '$added ${context.tr('route profiles added')}');
        await _load();
      }
    } catch (error) {
      box.report(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return BoxPage(title: 'Route profiles', children: [
      if (_loading)
        generateSection(items: [ListItem(title: Text(context.tr('Loading')))])
      else ...[
        generateSection(items: [
          for (final profile in _profiles)
            ListItem(
              title: Text(profile['name'].toString().isEmpty ? context.tr('Untitled') : profile['name'].toString()),
              subtitle: Text(_summary(profile)),
              trailing: (profile['id'] as num?)?.toInt() == _currentId
                  ? const GlyphIcon(AppGlyphs.checkCircle)
                  : null,
              onTap: () => _open(profile),
            ),
        ], footer: context.tr('The current profile builds every configuration that has no group override.')),
        generateSection(items: [
          ListItem(
            leading: const GlyphIcon(AppGlyphs.add),
            title: Text(context.tr('Add route profile')),
            onTap: () => _open(const {'id': 0}),
          ),
          ListItem(
            leading: const GlyphIcon(AppGlyphs.cloudDownload),
            title: Text(context.tr('Throne official profiles')),
            onTap: _addPresets,
          ),
        ], footer: context.tr('The official profiles are remote route profiles of the routeprofiles repository.')),
      ],
    ]);
  }

  /// Throne's profile_summary line: "Default: proxy · 3 rules", with the two
  /// markers that mean something here appended (a raw profile is read-only, a
  /// remote one is fetched).
  String _summary(Json profile) {
    final rules = (profile['ruleCount'] as num?)?.toInt() ?? 0;
    final marks = <String>[
      '${context.tr('Default')}: ${profile['defaultOutbound']?.toString() ?? 'direct'}',
      '$rules ${context.tr('rules')}',
      if (profile['isRemote'] == true) context.tr('Remote'),
      if (profile['isRaw'] == true) context.tr('Read-only'),
    ];
    return marks.join(' · ');
  }
}
