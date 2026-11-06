import 'dart:async';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'capabilities.dart';
import 'common/config_guard.dart';
import 'common/ip_quality_cache.dart';
import 'common/refresh_gate.dart';
import 'common/throttle.dart';
import 'core/kernel_service.dart';
import 'core/platform_value.dart';
import 'core/throne_kernel.dart';

part 'box_api.dart';

typedef Json = Map<String, dynamic>;

/// StandardMessageCodec yields `_Map<Object?, Object?>` for native maps, and nested maps keep
/// that shape, so the two boundaries (`call` and the event stream) normalize the whole tree.
/// Everything downstream is already normalized, which is why [json] and [rows] only cast: doing
/// it again here copied the entire startup payload a second time.
Json json(Object? value) {
  if (value is Json) return value;
  // A map from somewhere that did not go through the boundary (a test, a raw channel reply):
  // normalize rather than drop it.
  if (value is Map) {
    final normalized = normalizePlatformValue(value);
    if (normalized is Json) return normalized;
  }
  return <String, dynamic>{};
}

/// The rows of a channel list, with the same one-copy rule as [json].
List<Json> rows(Object? value) {
  if (value is! List) return <Json>[];
  final out = <Json>[];
  for (final item in value) {
    if (item is Json) {
      out.add(item);
    } else if (item is Map) {
      final normalized = normalizePlatformValue(item);
      if (normalized is Json) out.add(normalized);
    }
  }
  return out;
}

enum BoxAspect { state, appearance, traffic, memory, connections, logs, logcat, testSession }
enum BoxData { memory, logs, logcat, testSession }

/// A single event flowing from the backend / core to the UI, mirroring Bettbox's
/// `ClashMessage` bus: one typed stream instead of several ad-hoc controllers. A listener
/// subscribes to the subset it cares about with `where((event) => event is X)`.
sealed class BoxEvent {
  const BoxEvent();
}

/// A banner / snackbar message: backend `error`/`openUrl`, the non-popup branch of a
/// subscription report, and UI-initiated notices.
class BoxMessageEvent extends BoxEvent {
  const BoxMessageEvent(this.text);
  final String text;
}

/// A subscription update's change window that should open the report dialog.
class SubscriptionReportEvent extends BoxEvent {
  const SubscriptionReportEvent(this.report);
  final Json report;
}

/// An external intent (share / import) is waiting to be drained.
class IntentAvailableEvent extends BoxEvent {
  const IntentAvailableEvent();
}

/// The embedded browser (OAuth and friends) completed a callback.
class BrowserCompleteEvent extends BoxEvent {
  const BrowserCompleteEvent(this.payload);
  final Json payload;
}

/// Pluggable event bus, one-way from backend to UI.
class BoxEventBus {
  final _controller = StreamController<BoxEvent>.broadcast();
  Stream<BoxEvent> get stream => _controller.stream;
  bool _closed = false;
  void emit(BoxEvent event) {
    if (_closed) return;
    _controller.add(event);
  }
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _controller.close();
  }
}

class BoxController extends ChangeNotifier {
  BoxController({MethodChannel? channel, Stream<dynamic>? events})
      : _channel = channel ?? const MethodChannel('io.flrone/box'),
        // EventChannel uses the same codec as MethodChannel, so its payloads
        // arrive as `_Map<Object?, Object?>` too.
        _events = (events ?? const EventChannel('io.flrone/events').receiveBroadcastStream())
            .map<dynamic>(normalizePlatformValue);

  final MethodChannel _channel;
  final Stream<dynamic> _events;
  /// Unified event bus (Bettbox `ClashMessage`-style): the single one-way stream between
  /// backend and UI. Consumers subscribe to the slice they need with `where((event) => event is X)`.
  /// The derived streams are cached so repeated access yields the same broadcast stream, the
  /// way `StreamController.stream` did.
  final eventBus = BoxEventBus();
  Stream<T> _eventsOf<T extends BoxEvent>() => eventBus.stream.where((event) => event is T).cast<T>();
  late final Stream<String> messages = _eventsOf<BoxMessageEvent>().map((event) => event.text);
  late final Stream<Json> subscriptionReports = _eventsOf<SubscriptionReportEvent>().map((event) => event.report);
  late final Stream<Json> browserEvents = _eventsOf<BrowserCompleteEvent>().map((event) => event.payload);
  late final Stream<IntentAvailableEvent> intents = _eventsOf<IntentAvailableEvent>();
  StreamSubscription<dynamic>? _subscription;
  StreamSubscription<Json>? _kernelSub;
  StreamSubscription<Map<String, dynamic>>? _kernelEvents;
  int _kernelLogId = 0;
  /// The FFI path's core lifecycle (active only when the rebuilt core is present).
  late final KernelService kernel = KernelService(this);
  final _revisions = List<int>.filled(BoxAspect.values.length, 0);
  final _stateChanges = ChangeNotifier();
  final _dataOwners = <BoxData, Set<Object>>{};
  Listenable get stateChanges => _stateChanges;
  Json dashboard = {}, settings = {}, preferences = {}, rates = {};

  /// Dashboard fields the FFI driver owns while it runs the core. In that mode the service
  /// side has no box of its own: its meter has no TrafficUpdater and its status is the
  /// service's, so both report zeros. Letting those land on the dashboard flipped every
  /// figure between the two sources once a second.
  static const driverOwnedDashboard = {
    'status', 'startedAt', 'uploadTotal', 'downloadTotal', 'connections', 'memory', 'goroutines',
  };

  /// [incoming] with the driver's own fields kept from [current] when [channelIsStale]:
  /// the service side has no box in FFI mode, so its copy of these is a row of zeros.
  /// Everything else — the mode, the selected profile, the system proxy — still comes from
  /// the channel, which is the side that persists it. The driver's own events are never
  /// merged: they are the values the merge is protecting.
  static Json mergeDashboard(Json current, Json incoming, {required bool channelIsStale}) {
    if (!channelIsStale) return incoming;
    final merged = Map<String, dynamic>.of(incoming);
    for (final key in driverOwnedDashboard) {
      if (current.containsKey(key)) merged[key] = current[key];
    }
    return merged;
  }

  /// Test hook: pretend the FFI driver owns the core, so the arbitration between the two
  /// sources can be exercised without the library. Null asks the driver.
  @visibleForTesting
  bool? debugDriverActive;
  bool get _driverActive => debugDriverActive ?? kernel.active;

  BoxCapabilities capabilities = BoxCapabilities.empty;
  Json toolState = {}, stun = {}, quality = {}, inbox = {}, ping = {};
  Json terminal = {};
  Json memory = {}, lan = {};
  List<Json> transfers = [], usbDevices = [];
  List<Json> outbounds = [];
  List<Json> profiles = [], groups = [], connections = [], logs = [], logcat = [];
  Json testSession = {};
  String? defaultLogLevel;
  final uploadHistory = <double>[];
  final downloadHistory = <double>[];
  /// Bettbox keeps a 30 point window sampled once a second, so the chart spans half a minute.
  static const trafficWindow = 30;
  static const trafficSampleGap = Duration(milliseconds: 700);
  DateTime? _lastSample;

  /// Appends the current rates to the two sparkline windows, dropping the oldest point.
  void _sampleTraffic() {
    uploadHistory.add((rates['upload'] as num? ?? 0).toDouble());
    downloadHistory.add((rates['download'] as num? ?? 0).toDouble());
    if (uploadHistory.length > trafficWindow) uploadHistory.removeAt(0);
    if (downloadHistory.length > trafficWindow) downloadHistory.removeAt(0);
  }
  String version = '', coreVersion = '';
  int systemAccentColor = 0xff007aff;
  int sampleRevision = 0;
  int profilesRevision = 0;
  bool _disposed = false;
  bool ready = false;
  bool lanChanging = false;
  bool serviceSettingsChanging = false;
  String? startupError;
  final pendingIntents = <String>[];
  String? applyRequired;
  final appIcons = <String, Future<Uint8List?>>{};
  final _profileStats = <int, Future<Json>>{};
  late final ipQualities = IpQualityCache(
    read: (ip) => call('dashboard.qualityCache.get', {'ip': ip}),
    write: (ip, record) async { await call('dashboard.qualityCache.put', {'ip': ip, 'value': record}); },
    onCacheError: (error) => debugPrint('IP quality cache: ${describe(error)}'),
  );

  /// Bettbox's `maxLogLength`: the log tail keeps a fixed window, so a long-running
  /// service cannot grow the list without bound however long the screen stays open.
  static const maxLogLength = 512;

  /// The high-frequency list events whose notifications are worth merging: a burst of
  /// these arriving inside one [batchWindow] rebuilds the UI once instead of once each.
  static const _batchedTypes = {'logs', 'logcat', 'connections'};
  static const batchWindow = Duration(milliseconds: 300);
  final _pendingAspects = <BoxAspect>{};
  Timer? _batchTimer;

  /// Coalesces repeated bridge round-trips (visibility toggles, refreshes) and
  /// gates high-frequency rebuilds while the app is backgrounded. Both are the
  /// pure-Dart parts of Bettbox's refresh/performance work; neither changes the
  /// data the Kotlin side pushes, only when the UI reacts to it.
  final Debouncer debouncer = Debouncer();
  final Throttler throttler = Throttler();
  final RefreshGate refreshGate = RefreshGate();
  static const _deferrableAspects = <BoxAspect>{
    BoxAspect.traffic, BoxAspect.connections, BoxAspect.logs,
    BoxAspect.logcat, BoxAspect.memory, BoxAspect.testSession,
  };
  final _deferredAspects = <BoxAspect>{};

  /// Replays aspects that arrived while the app was hidden. Called on resume so
  /// the first frame back shows current data instead of a stale dashboard.
  void resumeRefreshes() {
    refreshGate.setForeground(true);
    if (_deferredAspects.isEmpty) return;
    final aspects = _deferredAspects.toList();
    _deferredAspects.clear();
    _notify(aspects);
  }

  /// Stops tick-driven rebuilds while hidden. Data still lands in the fields.
  void suspendRefreshes() => refreshGate.setForeground(false);

  /// Routes an event's aspects through the visibility gate.
  void _dispatch(Iterable<BoxAspect> aspects, bool batched) {
    if (!refreshGate.shouldRebuild && aspects.every(_deferrableAspects.contains)) {
      _deferredAspects.addAll(aspects);
      return;
    }
    if (batched) {
      _notifyBatched(aspects);
    } else {
      _notify(aspects);
    }
  }

  void _notify(Iterable<BoxAspect> aspects) {
    if (_disposed) return;
    for (final aspect in aspects) { _revisions[aspect.index]++; }
    if (aspects.contains(BoxAspect.state)) _stateChanges.notifyListeners();
    super.notifyListeners();
  }

  /// Applies the state now so reads are never stale, but holds the rebuild until the
  /// window closes — the Bettbox pending-buffer pattern, taken at the notify step.
  void _notifyBatched(Iterable<BoxAspect> aspects) {
    if (_disposed) return;
    _pendingAspects.addAll(aspects);
    _batchTimer ??= Timer(batchWindow, _flushBatch);
  }

  void _flushBatch() {
    _batchTimer = null;
    if (_disposed || _pendingAspects.isEmpty) return;
    final aspects = _pendingAspects.toList();
    _pendingAspects.clear();
    _notify(aspects);
  }

  // Preserve explicit notifications for callers that mutate several fields.
  @override void notifyListeners() => _notify(BoxAspect.values);

  void setDataVisible(BoxData data, Object owner, bool visible) {
    if (_disposed) return;
    final owners = _dataOwners.putIfAbsent(data, () => <Object>{});
    final wasVisible = owners.isNotEmpty;
    if (visible) { owners.add(owner); } else { owners.remove(owner); }
    if (ready && wasVisible != owners.isNotEmpty) _syncData(data);
  }

  void _syncData(BoxData data) {
    // Must stay synchronous: BoxDataSubscription's demand contract expects one
    // bridge call per visibility change, and its tests assert the exact order.
    // The debouncer is for user-driven bursts (see BoxController.debouncer),
    // not for this negotiated subscription state.
    unawaited(act(switch (data) {
      BoxData.memory => 'dashboard.memory.visible',
      BoxData.logcat => 'logs.logcat.visible',
      BoxData.testSession => 'groups.testSession.visible',
      _ => 'logs.visible',
    }, {'visible': _dataOwners[data]?.isNotEmpty == true}));
  }

  Future<Json> profileStats(int id) => _profileStats.putIfAbsent(id, () async => json(await call('profiles.stats', {'id': id})));

  Future<Uint8List?> appIcon(String package) => appIcons.putIfAbsent(package, () async {
    try { return await call('apps.icon', {'package': package}) as Uint8List?; }
    catch (_) { return null; }
  });

  bool get remote => dashboard['remote'] != null;
  bool get running => remote
      ? dashboard['remoteConnected'] == true
      : dashboard['status'] == 'Started';
  bool get transitioning => ['Starting', 'Stopping'].contains(dashboard['status']);
  int get selectedProfileId => (dashboard['selectedProfileId'] as num?)?.toInt() ?? -1;
  Json? get selectedProfile {
    for (final profile in profiles) {
      if (profile['id'] == selectedProfileId) return profile;
    }
    return null;
  }

  List<String> get lanAddresses => (lan['addresses'] as List? ?? []).whereType<String>().toList();
  bool get canSetLanProxy => !remote && !transitioning && !lanChanging &&
      lan['canToggle'] == true && lan['profileId'] == selectedProfileId;
  List<String> get lanProxyEndpoints => remote || !running || lan['running'] != true ? [] :
      rows(lan['activeBindings']).expand((binding) =>
          (binding['endpoints'] as List? ?? []).whereType<String>()).toSet().toList();

  String? get lanCopyText {
    final addresses = lanAddresses, endpoints = lanProxyEndpoints;
    for (final address in addresses) {
      for (final endpoint in endpoints) {
        if (endpoint.startsWith('$address:') || endpoint.startsWith('[$address]:')) return endpoint;
      }
    }
    return endpoints.isNotEmpty ? endpoints.first : addresses.isNotEmpty ? addresses.first : null;
  }

  Future<void> refreshLan() async {
    try {
      final value = await call('dashboard.lan.refresh');
      if (!_disposed && value is Map) { lan = json(value); _notify([BoxAspect.state]); }
    } catch (error) { report(error); }
  }

  Future<bool> setLanProxy(bool enabled, {int? port, int? profileId, String? revision}) async {
    if (!canSetLanProxy) return false;
    final target = profileId ?? selectedProfileId;
    if (target != selectedProfileId) {
      report(StateError('Selected profile changed; reload it before saving'));
      return false;
    }
    lanChanging = true;
    _notify([BoxAspect.state]);
    try {
      final value = json(await call('dashboard.lan.set', {
        'profileId': target, 'revision': revision ?? lan['revision'], 'enabled': enabled,
        'port': ?port,
      }));
      if (!_disposed && !remote && selectedProfileId == target) lan = value;
      return true;
    } catch (error) {
      report(error);
      if (!_disposed) await refreshLan();
      return false;
    } finally {
      lanChanging = false;
      if (!_disposed) _notify([BoxAspect.state]);
    }
  }

  Future<void> initialize() async {
    startupError = null;
    notifyListeners();
    await _subscription?.cancel();
    _subscription = _events.listen(_onEvent, onError: report);
    // Dual path: when the rebuilt core is present, kernel logs stream in through
    // the FFI message port (throne_kernel) instead of the channel's 'logs' pushes.
    // In bridge mode the channel keeps both streams, and libthrone.so is not
    // opened from Dart at all.
    await _kernelSub?.cancel();
    _kernelSub = null;
    // The FFI path drives the core lifecycle itself; its status/events feed _onEvent
    // in the same wire shapes the channel uses.
    try {
      await kernel.initialize();
      await _kernelEvents?.cancel();
      _kernelEvents = null;
      if (kernel.ffiMode) {
        _kernelSub = ThroneKernel.ensure()?.logs.listen(_onKernelLog, onError: report);
        _kernelEvents = kernel.events.listen((event) => _onEvent(event, fromDriver: true), onError: report);
      }
    } catch (error) {
      // The FFI worker failed to start. KernelService has already handed core
      // control back to the channel, so the UI stays usable and shows why the
      // accelerated path is unavailable instead of hanging on the loading view.
      startupError = describe(error);
      // If the rollback itself did not finish, the service would sit Connected
      // under ffiMode with no core and nothing left to rebuild it.
      if (kernel.handoverPending) unawaited(kernel.abandonHandover());
      notifyListeners();
    }
    try {
      final result = json(await call('ready'));
      version = result['version'] as String? ?? '';
      coreVersion = result['coreVersion'] as String? ?? '';
      systemAccentColor = (result['systemAccentColor'] as num?)?.toInt() ?? 0xff007aff;
      dashboard = json(result['dashboard']);
      profiles = rows(result['profiles']);
      settings = json(result['settings']);
      capabilities = BoxCapabilities.parse(result['capabilities']);
      preferences = json(result['preferences']);
      if (result['lan'] is Map) lan = json(result['lan']);
      toolState = json(result['tools']);
      final diagnostics = json(result['diagnostics']);
      stun = json(diagnostics['stun']);
      quality = json(diagnostics['quality']);
      final intent = result['intent'] as String?;
      if (intent != null) pendingIntents.add(intent);
      // A low-RAM device gets a smaller decoded-image budget than the desktop-sized default.
      imageCache.maximumSizeBytes = (result['lowRam'] == true ? 24 : 50) << 20;
      // An AppRestart-level write or reset from before this attach; a reload does not clear it.
      applyRequired = result['applyRequired'] as String?;
      ready = true;
      for (final data in _dataOwners.keys) { _syncData(data); }
    } catch (error) {
      startupError = describe(error);
      // `ready` never completed, so config.build cannot be trusted and the
      // hand-over must not be left pending: give the core back to the bridge,
      // which rebuilds its own box on service.reload.
      if (!ready && kernel.handoverPending) {
        unawaited(kernel.abandonHandover());
      }
    }
    // The service may have started its own box before Dart attached (START_STICKY,
    // always-on VPN); the bridge stopped it to avoid two boxes on one tun. Rebuild it
    // here, now that the channel can answer config.build, instead of leaving the
    // tunnel down until the user taps connect again.
    if (ready && kernel.handoverPending) unawaited(kernel.adoptService());
    notifyListeners();
  }

  /// Every method-channel reply is normalized here. Without this, callers that
  /// cast a reply to `Json` fail with
  /// `type '_Map<Object?, Object?>' is not a subtype of type 'Map<String, dynamic>'`.
  Future<dynamic> call(String method, [Json? args]) async =>
      normalizePlatformValue(await _channel.invokeMethod<dynamic>(method, args));

  void clearApplyRequired() { applyRequired = null; _notify([BoxAspect.state]); }

  Future<bool> act(String method, [Json? args]) async {
    try {
      await call(method, args);
      return true;
    } catch (error) {
      report(error);
      return false;
    }
  }

  Future<bool> setPreference(String key, dynamic value) => setPreferences({key: value});

  Future<bool> setPreferences(Json values) async {
    try {
      preferences = json(await call('preferences.set', {'value': values}));
      _notify([BoxAspect.state, BoxAspect.appearance]);
      return true;
    } catch (error) {
      report(error);
      return false;
    }
  }

  Future<void> setSetting(String key, dynamic value, {bool restart = true, bool autoRestart = false}) async {
    if (serviceSettingsChanging || autoRestart && transitioning && !remote) return;
    final restartService = autoRestart && running && !remote;
    if (autoRestart) {
      serviceSettingsChanging = true;
      _notify([BoxAspect.state]);
    }
    try {
      final saved = json(await call('settings.set', {'key': key, 'value': value,
        if (restartService) 'restart': true}));
      if (!_disposed) {
        settings = saved;
        if (restartService) {
          applyRequired = null;
        } else if (restart && !autoRestart && running && !remote) { applyRequired = 'Restart'; }
        _notify([BoxAspect.state]);
      }
    } catch (error) {
      report(error);
    } finally {
      if (autoRestart) {
        serviceSettingsChanging = false;
        if (!_disposed) _notify([BoxAspect.state]);
      }
    }
  }

  Future<bool> setSettings(Json values, {bool restart = true}) async {
    try {
      settings = json(await call('settings.patch', {'value': values}));
      if (restart && running && !remote) applyRequired = 'Restart';
      _notify([BoxAspect.state]);
      return true;
    } catch (error) { report(error); return false; }
  }

  /// Returns the listed settings (every Throne setting when [keys] is empty) to their Throne defaults.
  /// Restarting stays on demand: the bridge reloads or raises the restart badge only when a key that
  /// actually changed needs it, and a reset that changed nothing leaves the running core alone.
  Future<bool> resetSettings(List<String> keys) async {
    try {
      settings = json(await call('settings.reset', {'keys': keys}));
      _notify([BoxAspect.state]);
      return true;
    } catch (error) { report(error); return false; }
  }

  void report(Object error) { if (!_disposed) eventBus.emit(BoxMessageEvent(describe(error))); }

  /// UI-initiated banner message (previously written directly into `messages`).
  void showMessage(String text) { if (!_disposed) eventBus.emit(BoxMessageEvent(text)); }
  static String describe(Object error) => error is PlatformException
      ? error.message ?? error.code : error.toString();

  /// [event] from the driver's own status feed, as opposed to the channel.
  @visibleForTesting
  void handleEvent(dynamic event, {bool fromDriver = false}) => _onEvent(event, fromDriver: fromDriver);

  void _onEvent(dynamic event, {bool fromDriver = false}) {
    if (_disposed) return;
    final item = json(event);
    final value = item['value'];
    // The driver's feed is the truth while it runs the core; the channel's dashboard and
    // rates then carry the service meter's zeros and must not overwrite it.
    final channelIsStale = _driverActive && !fromDriver;
    var aspects = const [BoxAspect.state];
    switch (item['type']) {
      case 'tools': toolState = json(value);
      case 'outbounds': outbounds = rows(value);
      case 'stun': stun = json(value);
      case 'quality': quality = json(value);
      case 'inbox': inbox = json(value);
      case 'ping': ping = json(value);
      case 'transfers': transfers = rows(value);
      case 'usbDevices': usbDevices = rows(value);
      case 'terminal': terminal = json(value);
      case 'memory':
        final nextMemory = json(value);
        if (const DeepCollectionEquality().equals(memory, nextMemory)) return;
        memory = nextMemory;
        aspects = const [BoxAspect.memory];
      case 'lan': lan = json(value);
      // The system is short of memory: ART's gc/trimHeap cannot touch the Dart heap, so the
      // decoded images (the largest thing the UI keeps) are dropped here instead.
      case 'memoryTrim':
        imageCache.clear();
        imageCache.clearLiveImages();
        return;
      case 'browserComplete': eventBus.emit(BrowserCompleteEvent(json(value))); return;
      case 'dashboard':
        final nextDashboard = mergeDashboard(dashboard, json(value), channelIsStale: channelIsStale);
        if (const DeepCollectionEquality().equals(dashboard, nextDashboard)) return;
        const counters = {'memory', 'goroutines', 'uploadTotal', 'downloadTotal', 'connections'};
        Json state(Json data) => Map.fromEntries(data.entries.where((entry) => !counters.contains(entry.key)));
        aspects = const DeepCollectionEquality().equals(state(dashboard), state(nextDashboard))
          ? const [BoxAspect.traffic] : const [BoxAspect.state, BoxAspect.traffic];
        final wasRunning = running;
        dashboard = nextDashboard;
        // Bettbox clears its traffic window and totals when the session ends, so the next start
        // draws a curve of its own instead of continuing the one the previous session left.
        if (wasRunning && !running) {
          uploadHistory.clear();
          downloadHistory.clear();
          rates = {};
          sampleRevision++;
          _lastSample = null;
        }
      case 'profiles': profilesRevision++; _profileStats.clear(); profiles = rows(value);
      case 'groups': groups = rows(value);
      case 'connections':
        connections = rows(value);
        aspects = const [BoxAspect.connections];
      case 'logs':
        final logState = json(value);
        final entries = rows(logState['entries']);
        if (logState['reset'] == false) {
          final firstId = (logState['firstId'] as num?)?.toInt();
          final retained = firstId == null ? <Json>[] : logs.where((entry) => ((entry['id'] as num?)?.toInt() ?? -1) >= firstId);
          final lastId = logs.isEmpty ? -1 : ((logs.last['id'] as num?)?.toInt() ?? -1);
          logs = [...retained, ...entries.where((entry) => ((entry['id'] as num?)?.toInt() ?? -1) > lastId)];
        } else {
          logs = entries;
        }
        if (logs.length > maxLogLength) logs = logs.sublist(logs.length - maxLogLength);
        defaultLogLevel = logState['defaultLogLevel'] as String?;
        aspects = const [BoxAspect.logs];
      case 'logcat':
        final logState = json(value);
        final entries = rows(logState['entries']);
        if (logState['reset'] == false) {
          final firstId = (logState['firstId'] as num?)?.toInt();
          final retained = firstId == null ? <Json>[] : logcat.where((entry) => ((entry['id'] as num?)?.toInt() ?? -1) >= firstId);
          final lastId = logcat.isEmpty ? -1 : ((logcat.last['id'] as num?)?.toInt() ?? -1);
          logcat = [...retained, ...entries.where((entry) => ((entry['id'] as num?)?.toInt() ?? -1) > lastId)];
        } else {
          logcat = entries;
        }
        if (logcat.length > maxLogLength) logcat = logcat.sublist(logcat.length - maxLogLength);
        aspects = const [BoxAspect.logcat];
      case 'testSession': testSession = json(value); aspects = const [BoxAspect.testSession];
      case 'settings': settings = json(value);
      case 'preferences':
        final nextPreferences = json(value);
        if (const DeepCollectionEquality().equals(preferences, nextPreferences)) return;
        preferences = nextPreferences;
        aspects = const [BoxAspect.state, BoxAspect.appearance];
      case 'systemAccent':
        final accent = (value as num?)?.toInt();
        if (accent == null || systemAccentColor == accent) return;
        systemAccentColor = accent;
        aspects = const [BoxAspect.appearance];
      case 'rates':
        // The driver's own status feed carries these numbers while it runs the core; the
        // channel's copy is the service meter's, which has no TrafficUpdater in FFI mode and
        // would alternate with the real rates once a second.
        if (channelIsStale) return;
        rates = json(value);
        // One point per second, whoever pushes it: the channel's tick and the FFI status feed can
        // both report the same second, and a doubled sample would halve the window's span. The
        // revision tracks the append, so the chart's own delta stays one value per increment.
        final now = DateTime.now();
        if (_lastSample == null || now.difference(_lastSample!) >= trafficSampleGap) {
          _lastSample = now;
          _sampleTraffic();
          sampleRevision++;
        }
        aspects = const [BoxAspect.traffic];
      case 'error': eventBus.emit(BoxMessageEvent(value.toString())); return;
      case 'applyRequired': applyRequired = value.toString();
      case 'serviceReload':
        // A widget/tile/notification reload reached the FFI driver (BboxKernel.onReloadWanted).
        unawaited(kernel.reloadService(reason: 'widget/tile/notification reload'));
        return;
      case 'wifi.state':
        // The Android monitor saw the SSID/BSSID change (BboxKernel.onWifiChanged); the core
        // that owns the routing rules is Dart's, so the re-read happens here.
        unawaited(kernel.updateWifiState());
        return;
      case 'subscriptionReport':
        // Errors and untitled status lines are snackbars; a popup report opens the change window
        // (SubscriptionReportDialog equivalence) — the app shell listens on the stream.
        final report = json(value);
        if (report['kind'] == 'popup') {
          eventBus.emit(SubscriptionReportEvent(report));
        } else {
          final group = report['groupName']?.toString() ?? '';
          eventBus.emit(BoxMessageEvent(group.isEmpty ? report['text'].toString() : '$group: ${report['text']}'));
        }
        return;
      case 'intentAvailable':
        call('intent.take').then((uri) { if (uri is String) { pendingIntents.add(uri); eventBus.emit(const IntentAvailableEvent()); } }).catchError(report);
        return;
      case 'openUrl':
        // A backend request remains a visible user action in the Flutter UI.
        eventBus.emit(BoxMessageEvent(value.toString()));
        return;
      default: return;
    }
    // A burst of list events shares one rebuild; everything else notifies as it
    // lands. While hidden, high-frequency aspects are held for the resume flush.
    _dispatch(aspects, _batchedTypes.contains(item['type']));
  }

  /// Kernel logs arriving through the FFI message port (dual path: only when
  /// the rebuilt core is present). Same entry shape the channel pushes.
  /// The id uses a high offset to stay clear of the channel's id space;
  /// receivedAt is milliseconds since epoch to match the channel wire format.
  static const _kernelLogIdBase = 0x10000000;
  void _onKernelLog(Json data) {
    if (_disposed) return;
    logs = [...logs, {
      'id': _kernelLogIdBase + _kernelLogId++,
      'level': data['level'],
      'message': data['message'],
      'receivedAt': DateTime.now().millisecondsSinceEpoch,
    }];
    if (logs.length > maxLogLength) logs = logs.sublist(logs.length - maxLogLength);
    _notifyBatched(const [BoxAspect.logs]);
  }

  @override
  void dispose() {
    _disposed = true;
    _batchTimer?.cancel();
    debouncer.cancelAll();
    throttler.clear();
    refreshGate.dispose();
    _subscription?.cancel();
    _kernelSub?.cancel();
    _kernelEvents?.cancel();
    kernel.dispose();
    eventBus.close();
    _stateChanges.dispose();
    super.dispose();
  }
}

class BoxScope extends StatelessWidget {
  const BoxScope({super.key, required this.controller, required this.child});
  final BoxController controller;
  final Widget child;
  @override Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    child: child,
    builder: (_, child) => _BoxState(controller: controller,
      revisions: List<int>.of(controller._revisions), child: child!),
  );
  static BoxController of(BuildContext context, {BoxAspect aspect = BoxAspect.state}) =>
    InheritedModel.inheritFrom<_BoxState>(context, aspect: aspect)!.controller;
}

class _BoxState extends InheritedModel<BoxAspect> {
  const _BoxState({required this.controller, required this.revisions, required super.child});
  final BoxController controller;
  final List<int> revisions;
  @override bool updateShouldNotify(_BoxState oldWidget) =>
    controller != oldWidget.controller || !listEquals(revisions, oldWidget.revisions);
  @override bool updateShouldNotifyDependent(_BoxState oldWidget, Set<BoxAspect> dependencies) =>
    controller != oldWidget.controller || dependencies.any((aspect) => revisions[aspect.index] != oldWidget.revisions[aspect.index]);
}

extension BoxContext on BuildContext {
  BoxController get box => BoxScope.of(this);
  BoxController watchBox(BoxAspect aspect) {
    BoxScope.of(this);
    return BoxScope.of(this, aspect: aspect);
  }
}

String bytes(num value) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = value.toDouble();
  var unit = 0;
  while (size.abs() >= 1024 && unit < units.length - 1) { size /= 1024; unit++; }
  return '${size.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}
