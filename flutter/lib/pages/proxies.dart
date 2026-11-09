import '../widgets.dart';
import '../components/data_subscription.dart';
import '../components/group_tabs.dart';
import '../components/proxy_card.dart';
import '../components/proxy_list.dart';
import 'test_panel.dart';

class ProxiesPage extends StatefulWidget {
  const ProxiesPage({super.key});
  @override State<ProxiesPage> createState() => _ProxiesPageState();
}
class _ProxiesPageState extends State<ProxiesPage> {
  String _query = '';
  final _testing = <String>{};
  // FlClash runs a batch as a queue: groups waiting their turn show a clock,
  // the one under test a spinner, and finished groups their delays.
  final _queued = <String>{};
  Json _session = const {};
  int _sessionRequestedAt = 0;
  final _scrolls = <String, ScrollController>{};
  final _selectedOffsets = <String, double>{};
  String? _currentGroup;
  BoxController? _box;

  @override void didChangeDependencies() {
    super.didChangeDependencies();
    if (_box == null) {
      _box = context.box;
      // The node rows are the largest payload the bridge carries, so they only travel while this
      // screen is open; every other screen renders the group counts.
      _box!.groupsSetVisible(true);
    }
  }

  @override void dispose() {
    _box?.groupsSetVisible(false);
    for (final scroll in _scrolls.values) { scroll.dispose(); }
    super.dispose();
  }

  Future<void> _locate() async {
    final scroll = _scrolls[_currentGroup], offset = _selectedOffsets[_currentGroup];
    if (scroll == null || !scroll.hasClients || offset == null) return;
    await scroll.animateTo(offset.clamp(scroll.position.minScrollExtent, scroll.position.maxScrollExtent),
      duration: context.motionDuration(const Duration(milliseconds: 300)), curve: Curves.easeOutCubic);
  }

  PopupMenuItem _options(String label, Glyph glyph, String key, List<String> values, String fallback) => PopupMenuItem(
    glyph: glyph, label: context.tr(label), subItems: [for (final value in values)
      PopupMenuItem(label: context.tr(value), checked: (context.box.preferences[key] ?? fallback) == value,
        onPressed: () => context.box.setPreference(key, value)),
    ],
  );

  // Testing and selecting both work with the service stopped: a test runs over its own instance of the
  // profile, and a selection is a stored preference the next start reads, so neither waits for the VPN.
  Future<void> _test(String tag) async {
    if (_testing.contains(tag) || _queued.contains(tag)) return;
    setState(() {
      _sessionRequestedAt = DateTime.now().millisecondsSinceEpoch;
      _testing.add(tag);
    });
    try {
      await context.box.groupTest(tag).timeout(const Duration(seconds: 60));
    } finally {
      if (mounted) setState(() => _testing.remove(tag));
    }
  }

  Future<void> _select(Json group, Json node) async {
    final box = context.box;
    if (group['selectable'] != true || node['tag'] == group['selected']) return;
    if (await box.groupSelect(group['tag'], node['tag'])) {
      if (box.preferences['closeConnectionsOnSelect'] == true) await box.connectionsCloseAll();
    }
  }

  List<Json> _nodes(Json group) {
    final words = _query.toLowerCase().trim().split(RegExp(r'\s+'));
    final nodes = rows(group['items']).where((node) => words.every(node['tag'].toString().toLowerCase().contains) &&
      !(context.box.preferences['hideTimeoutProxies'] == true && (node['testedAt'] as num? ?? 0) > 0 && (node['delay'] as num? ?? 0) <= 0)).toList();
    final sort = context.box.preferences['proxySort'] ?? 'Default';
    if (sort == 'Name') nodes.sort((a, b) => a['tag'].toString().compareTo(b['tag'].toString()));
    if (sort == 'Latency') {
      int delay(Json node) => (node['delay'] as num? ?? 0) > 0 ? (node['delay'] as num).toInt() : 0x7fffffff;
      nodes.sort((a, b) => delay(a).compareTo(delay(b)));
    }
    return nodes;
  }

  Widget _card(BuildContext context, Json group, Json node) {
    final groupTag = group['tag'].toString(), nodeTag = node['tag'].toString();
    final id = (node['id'] as num?)?.toInt();
    final startedAt = (_session['startedAt'] as num?)?.toInt() ?? 0;
    final row = startedAt < _sessionRequestedAt
        ? null
        : rows(_session['rows'])
            .where((row) => (row['id'] as num?)?.toInt() == id)
            .firstOrNull;
    final phase = switch (row?['phase']) {
      'TESTING' => ProxyTestPhase.running,
      'QUEUED' => ProxyTestPhase.queued,
      'DONE' => ProxyTestPhase.idle,
      _ when _testing.contains(nodeTag) => ProxyTestPhase.running,
      // A group test starts as a queue, then the session's row phases take over
      // one card at a time, matching FlClash's per-node animation.
      _ when _testing.contains(groupTag) || _queued.contains(groupTag) => ProxyTestPhase.queued,
      _ => ProxyTestPhase.idle,
    };
    return ProxyNodeCard(
      group: group, node: node, phase: phase,
      onSelect: () => _select(group, node), onTest: () => _test(nodeTag),
    );
  }

  Widget _grid(Json group) {
    final nodes = _nodes(group);
    if (nodes.isEmpty) {
      _selectedOffsets.remove(group['tag']);
      return NullStatus(label: context.tr('No results'), illustration: NullStatusIllustration.proxies);
    }
    return LayoutBuilder(builder: (context, constraints) {
      final columns = proxyColumns(constraints.maxWidth - 32, context.box.preferences);
      final metrics = ProxyCardMetrics.of(context, context.box.preferences);
      final selected = nodes.indexWhere((node) => node['tag'] == group['selected']);
      if (selected < 0) {
        _selectedOffsets.remove(group['tag']);
      } else {
        _selectedOffsets[group['tag'].toString()] = (selected ~/ columns) * metrics.rowExtent;
      }
      return GridView.builder(
        key: PageStorageKey('proxy-grid:${group['tag']}'),
        controller: _scrolls.putIfAbsent(group['tag'].toString(), () => sheetScrollController(context)),
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + context.bottomInset),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: columns,
          mainAxisSpacing: 8, crossAxisSpacing: 8, mainAxisExtent: metrics.extent),
        itemCount: nodes.length, itemBuilder: (context, index) => _card(context, group, nodes[index]),
      );
    });
  }

  @override Widget build(BuildContext context) {
    final box = context.box;
    _session = context.watchBox(BoxAspect.testSession).testSession;
    // The screen follows the configuration selection: whichever profile is selected, its nodes are
    // what shows here. A selection that names nothing on the wire (or none yet) falls back to all.
    final selectedId = box.selectedProfileId;
    final allGroups = box.groups;
    final picked = selectedId > 0
        ? allGroups.where((group) => (group['id'] as num?)?.toInt() == selectedId).toList()
        : allGroups;
    final groups = picked.isEmpty ? allGroups : picked;
    final liveTags = groups.map((group) => group['tag'].toString()).toSet();
    _selectedOffsets.removeWhere((tag, _) => !liveTags.contains(tag));
    if (_scrolls.keys.any((tag) => !liveTags.contains(tag))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final current = context.box.groups.map((group) => group['tag'].toString()).toSet();
        for (final tag in _scrolls.keys.where((tag) => !current.contains(tag)).toList()) {
          _scrolls.remove(tag)?.dispose();
        }
      });
    }
    final list = box.preferences['proxyLayout'] == 'List';
    if (!groups.any((group) => group['tag'] == _currentGroup)) {
      // Land on a group that has nodes. Otherwise an unselected configuration's empty group comes
      // first and the page reads as if the import brought nothing. `nodeCount` carries this before
      // the node rows arrive, so the choice does not depend on them.
      final withNodes = groups.where((group) => ((group['nodeCount'] as num?)?.toInt() ?? 0) > 0);
      _currentGroup = (withNodes.isNotEmpty ? withNodes.first : groups.firstOrNull)?['tag'] as String?;
    }
    return BoxDataSubscription(data: BoxData.testSession, child: Scaffold(
      title: context.tr('Proxies'),
      searchState: AppBarSearchState(onSearch: (query) => setState(() => _query = query)),
      primaryAction: list ? null : IconButtonData(glyph: AppGlyphs.bolt, tooltip: context.tr('Test latency'),
        isLoading: _testing.contains(_currentGroup),
        onPressed: _currentGroup != null ? () => _test(_currentGroup!) : null),
      iconActions: [
        if (!list) IconButtonData(glyph: AppGlyphs.locate, tooltip: context.tr('Scroll to selected'), onPressed: groups.isEmpty ? null : _locate),
      ],
      menuItems: [
        _options('Style', AppGlyphs.appsList, 'proxyLayout', const ['Tabs', 'List'], 'Tabs'),
        _options('Sort', AppGlyphs.sort, 'proxySort', const ['Default', 'Latency', 'Name'], 'Default'),
        _options('Layout', AppGlyphs.dashboard, 'proxyDensity', const ['Tight', 'Standard', 'Loose'], 'Standard'),
        _options('Size', AppGlyphs.textSize, 'proxyCardSize', const ['Compact', 'Standard', 'Loose'], 'Standard'),
        if (list) _options('Icon style', AppGlyphs.iconTile, 'proxyIconStyle', const ['Filled', 'Plain', 'Hidden'], 'Filled'),
        PopupMenuItem(glyph: AppGlyphs.eyeOff, label: context.tr('Hide timeout proxies'), checked: box.preferences['hideTimeoutProxies'] == true,
          section: const PopupMenuSection(), onPressed: () => box.setPreference('hideTimeoutProxies', box.preferences['hideTimeoutProxies'] != true)),
        PopupMenuItem(glyph: AppGlyphs.bolt, label: context.tr('Test all'), onPressed: () async {
          if (_testing.isNotEmpty || _queued.isNotEmpty) return;
          final tags = groups.map((group) => group['tag'].toString()).toList(growable: false);
          setState(() => _queued.addAll(tags));
          try {
            for (final tag in tags) {
              if (!mounted) return;
              setState(() {
                _sessionRequestedAt = DateTime.now().millisecondsSinceEpoch;
                _queued.remove(tag);
                _testing.add(tag);
              });
              try {
                await context.box.groupTest(tag).timeout(const Duration(seconds: 60));
              } finally {
                if (mounted) setState(() => _testing.remove(tag));
              }
            }
          } finally {
            if (mounted) setState(() => _queued.clear());
          }
        }),
        PopupMenuItem(glyph: AppGlyphs.dashboard, label: context.tr('Test panel'), onPressed: () => openForm(context, const TestPanelPage())),
        PopupMenuItem(glyph: AppGlyphs.connections, label: context.tr('Close connections after switching'), checked: box.preferences['closeConnectionsOnSelect'] == true,
          onPressed: () => box.setPreference('closeConnectionsOnSelect', box.preferences['closeConnectionsOnSelect'] != true)),
      ],
      body: groups.isEmpty ? NullStatus(
        label: context.tr(box.running ? 'No proxy groups in this configuration' : 'Start the service to view proxy groups'),
        illustration: NullStatusIllustration.proxies,
      ) : list ? ProxyListView(
        key: ValueKey(box.remote ? 'remote:${box.dashboard['remote']}' : 'local:${box.selectedProfileId}'),
        profileKey: box.remote ? 'remote:${box.dashboard['remote']}' : 'local:${box.selectedProfileId}',
        groups: [for (final group in groups) ProxyListGroup(group, _nodes(group))],
        testing: Set.of(_testing), queued: Set.of(_queued), cardBuilder: _card, onTest: _test,
      ) : DefaultTabController(
        key: ValueKey(groups.map((group) => '${group['tag'].toString().length}:${group['tag']}').join()),
        initialIndex: groups.indexWhere((group) => group['tag'] == _currentGroup).clamp(0, groups.length - 1),
        length: groups.length,
        child: Padding(
          padding: EdgeInsets.only(top: context.contentTopPadding),
          child: Column(children: [
            Padding(padding: const EdgeInsets.only(bottom: 16), child: Builder(builder: (context) => GroupTabs(
              controller: DefaultTabController.of(context), groups: groups,
              onSelected: (index) { if (mounted) setState(() => _currentGroup = groups[index]['tag'] as String); },
            ))),
            Expanded(child: TabBarView(children: [for (final group in groups) Column(children: [
              if (group['selectable'] != true) Padding(padding: const EdgeInsets.only(top: 8), child: Text(context.tr('Automatic selection'), style: context.listCaptionStyle)),
              Expanded(child: _grid(group)),
            ])])),
          ]),
        ),
      ),
    ));
  }
}
