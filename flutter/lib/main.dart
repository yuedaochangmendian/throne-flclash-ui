import 'dart:async';
import 'dart:ui' show PlatformDispatcher;
import 'package:flutter/foundation.dart' show FlutterError, LicenseRegistry, LicenseEntryWithLineBreaks, defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart' as material;
import 'widgets.dart';
import 'pages/dashboard.dart';
import 'pages/backup.dart';
import 'pages/proxies.dart';
import 'pages/profiles.dart';
import 'pages/tools.dart';
import 'pages/taildrop.dart';
import 'theme_settings.dart';
import 'components/page_switcher.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  LicenseRegistry.addLicense(() async* {
    for (final entry in const {'FlClash': 'LICENSE', 'cilium/ebpf': 'cilium-ebpf-LICENSE', 'ulikunitz/xz': 'xz-LICENSE', 'JetBrains Mono': 'JetBrainsMono-OFL.txt'}.entries) {
      yield LicenseEntryWithLineBreaks([entry.key], await rootBundle.loadString('assets/licenses/${entry.value}'));
    }
  });
  // Cap the decoded-image cache so a long session cannot grow it without bound.
  imageCache.maximumSizeBytes = 50 << 20;
  final controller = BoxController();
  // Framework and engine errors reach the same banner the bridge uses, instead
  // of only going to logcat where the user never sees them.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    controller.report(details.exception);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    controller.report(error);
    return true;
  };
  controller.refreshGate.start();
  runApp(BoxApp(controller: controller));
}

class BoxApp extends StatefulWidget {
  const BoxApp({super.key, required this.controller});
  final BoxController controller;
  @override State<BoxApp> createState() => _BoxAppState();
}

class _BoxAppState extends State<BoxApp> with WidgetsBindingObserver {
  final _banner = GlobalKey<BannerHostState>();
  StreamSubscription<String>? _messages;
  StreamSubscription<Json>? _reports;
  @override void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _messages = widget.controller.messages.listen((message) {
      _banner.currentState?.show(message);
    });    // A subscription update's change window (SubscriptionReportDialog): the report body selectable,
    // a copy action beside OK.
    _reports = widget.controller.subscriptionReports.listen((report) {
      final context = _banner.currentState?.context;
      if (context == null) return;
      final text = report['text']?.toString() ?? '';
      // The listener body is synchronous — no await separates the context capture from the
      // dialog — but the lint still fires on the builder's deferred execution.
      // ignore: use_build_context_synchronously
      showDialog<void>(context: context, builder: (dialogContext) => AlertDialog(
        title: report['title']?.toString() ?? dialogContext.tr('Change of configuration'),
        child: SizedBox(width: 480, child: SingleChildScrollView(child: SelectableText(
          text.trim().isEmpty ? dialogContext.tr('Nothing changed') : text))),
        actions: [
          TextButton(onPressed: () => Clipboard.setData(ClipboardData(text: text.trim())),
            child: Text(dialogContext.tr('Copy'))),
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: Text(context.tr('OK'))),
        ],
      ));
    });
    widget.controller.initialize();
  }
  @override void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messages?.cancel();
    _reports?.cancel();
    widget.controller.dispose();
    super.dispose();
  }

  final _themes = <String, ThemeData>{};

  @override void didChangeLocales(List<Locale>? locales) => setState(_themes.clear);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Backgrounded: keep ingesting bridge events but hold their rebuilds until
    // the user returns. This is the mobile form of Bettbox's active-window gate.
    if (state == AppLifecycleState.resumed) {
      widget.controller.resumeRefreshes();
    } else {
      widget.controller.suspendRefreshes();
    }
  }

  /// Prism's theme is the only one: every page, component and control in this
  /// app reads it, so there is no parallel Material scheme to keep in sync.
  ThemeData _theme(Brightness brightness) {
    final prefs = widget.controller.preferences;
    final scheme = appColorScheme(widget.controller, brightness);
    final family = prefs['fontFamily'] as String?;
    final key = "$brightness:${scheme.hashCode}:$family";
    final fallback = appFontFamilyFallback(platform: defaultTargetPlatform, locales: WidgetsBinding.instance.platformDispatcher.locales, fontFamily: family);
    return _themes.putIfAbsent(key, () => ThemeData(
      colorScheme: scheme,
      fontFamily: family,
      fontFamilyFallback: fallback,
      elevatedColorScheme: brightness == Brightness.dark ? scheme.elevated : null,
    ));
  }

  @override
  Widget build(BuildContext context) => BoxScope(
    controller: widget.controller,
    child: Builder(
      builder: (context) {
        final prefs = BoxScope.of(context, aspect: BoxAspect.appearance).preferences;
        final media = MediaQuery.of(context);
        final scale = appTextScale(prefs, media.textScaler.scale(1)).clamp(.8, 1.4);
        final glass = (prefs['liquidGlass'] ?? 'none');
        return PrismApp(
          title: 'Flrone',
          debugShowCheckedModeBanner: false,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          themeMode: ThemeMode.values.firstWhere((mode) => mode.name == prefs['theme'], orElse: () => ThemeMode.system),
          supportedLocales: const [Locale('en'), Locale('zh')],
          localizationsDelegates: const [
            BoxUiDelegate(), ...GlobalMaterialLocalizations.delegates,
          ],
          textScale: scale,
          minTextScale: .8,
          maxTextScale: 1.4,
          liquidGlass: glass == 'none' ? null : (glass == 'ultra' ? LiquidGlassQuality.ultra : LiquidGlassQuality.standard),
          stackedBanners: media.size.width >= 600,
          // Banners hang below the page bar so they never cover its buttons.
          bannerTopInset: media.padding.top + pageToolbarHeight,
          bannerKey: _banner,
          home: widget.controller.ready ? const HomePage() : Surface(
            color: context.colorScheme.surface,
            child: SafeArea(child: Center(child: widget.controller.startupError == null
                ? const ActivityIndicator()
                : ErrorState(widget.controller.startupError!, retry: widget.controller.initialize))),
          ),
        );
      },
    ),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;

  /// The desktop sidebar starts labelled — the app has no other textual
  /// navigation — and its toggle collapses it to icons.
  bool _sidebarExpanded = true;
  StreamSubscription<IntentAvailableEvent>? _intents;
  BoxController? _box;
  bool _handlingIntent = false;

  @override void didChangeDependencies() {
    super.didChangeDependencies();
    if (_box != null) return;
    _box = context.box;
    _intents = _box!.intents.listen((_) => _drainIntents());
    WidgetsBinding.instance.addPostFrameCallback((_) => _drainIntents());
  }

  Future<void> _drainIntents() async {
    if (_handlingIntent || !mounted) return;
    _handlingIntent = true;
    try {
      while (mounted && _box!.pendingIntents.isNotEmpty) {
        await _import(_box!.pendingIntents.removeAt(0));
      }
    } finally { _handlingIntent = false; }
  }

  Future<void> _import(String uri) async {
    try {
      if (uri.startsWith('bbox-share:')) {
        if (mounted) await openPage(context, SharePage(token: uri.substring('bbox-share:'.length)));
        return;
      }
      // A file the platform handed us: the host reads it and says which it is, because a .thrbackup is a
      // binary container the config importer cannot parse and a document is text it can.
      if (uri.startsWith('content://') || uri.startsWith('file://')) {
        final data = json(await _box!.filesOpen(uri));
        final backup = json(data['backup']);
        if (backup.isNotEmpty) {
          if (mounted) await restoreBackupFile(context, backup);
        } else if (mounted) {
          await openForm(context, ProfileForm(initial: data));
        }
        return;
      }
      final data = json(await _box!.profileDecodeIntent(uri));
      if (mounted) await openForm(context, ProfileForm(initial: data));
    } catch (error) { _box!.report(error); }
  }

  @override void dispose() { _intents?.cancel(); super.dispose(); }

  @override Widget build(BuildContext context) {
    final mobile = context.isMobileView;
    final floating = context.box.preferences['floatingNavigation'] != false;
    // A tab exists only when the host answers for it; the Proxies tab needs selector groups.
    final caps = context.box.capabilities;
    final items = <(String, Glyph)>[
      ('Dashboard', AppGlyphs.dashboard),
      if (caps.of('proxyGroups')) ('Proxies', AppGlyphs.proxies),
      ('Profiles', AppGlyphs.profiles),
      ('Tools', AppGlyphs.tools),
    ];
    final pages = <Widget>[
      const DashboardPage(),
      if (caps.of('proxyGroups')) const ProxiesPage(),
      const ProfilesPage(),
      const ToolsPage(),
    ];
    // Pruning a tab that the user was standing on must not leave the index past the end.
    final index = _index.clamp(0, pages.length - 1);
    final content = PageSwitcher(
      index: index,
      animation: tabAnimationOf(context.box.preferences),
      onSelected: (index) => setState(() => _index = index),
      children: [for (var i = 0; i < pages.length; i++)
        TickerMode(enabled: i == index, child: PageActivityScope(isActive: i == index, child: pages[i])),
      ],
    );
    // The shell is a bare surface: every page brings its own prism bar.
    return Surface(
      color: context.colorScheme.surface,
      child: Row(children: [
          if (!mobile) NavigationSidebar(
            selectedIndex: index,
            expanded: _sidebarExpanded,
            onSelected: (index) => setState(() => _index = index),
            onToggle: () => setState(() => _sidebarExpanded = !_sidebarExpanded),
            destinations: [for (final item in items) SidebarDestination(
              glyph: item.$2, label: context.tr(item.$1),
            )],
          ),
          Expanded(child: Column(children: [
            Expanded(child: Stack(children: [
              Positioned.fill(child: BottomInsetScope(
                inset: mobile && floating ? NavigationDock.insetOf(context) : 0,
                child: MediaQuery.removePadding(context: context, removeBottom: mobile, removeLeft: mobile, removeRight: mobile, child: content),
              )),
              if (mobile && floating) PositionedDirectional(
                start: 0, end: 0, bottom: 0,
                child: NavigationDock(
                  selectedIndex: index,
                  onSelected: (index) => setState(() => _index = index),
                  destinations: [for (final item in items) NavigationDockDestination(glyph: item.$2, label: context.tr(item.$1))],
                ),
              ),
            ])),
            if (mobile && !floating) NavigationBar(
              selectedIndex: index,
              onDestinationSelected: (index) => setState(() => _index = index),
              destinations: [for (final (i, item) in items.indexed)
                NavigationDestination(icon: AnimatedGlyph(glyph: item.$2, filled: i == index), label: context.tr(item.$1)),
              ],
            ),
          ])),
      ]),
    );
  }
}