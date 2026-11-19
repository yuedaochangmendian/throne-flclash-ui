import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../box.dart';
import '../capabilities.dart';
import '../components/connectivity/connectivity_store.dart';

/// The single [BoxController] the app already owns (created in `main`).
///
/// It is injected with `overrideWithValue` at the root; reading it without
/// that override is a programming error, not a fallback. The pilot only ever
/// *reads* this provider — writes keep going through the controller's own API
/// (`context.box.*`), so Riverpod never becomes a second writer to reconcile.
final boxControllerProvider =
    Provider<BoxController>((ref) => throw UnimplementedError('overridden in main'));

/// Exposes the process-wide [ConnectivityStore] singleton.
///
/// The store is already a [ChangeNotifier] and the single source of truth for
/// probe state. A plain [Provider] is used deliberately over
/// `ChangeNotifierProvider`: Riverpod disposes a `ChangeNotifierProvider`'s
/// notifier when its scope goes away, which would kill this app-wide singleton.
/// Consumers `ref.watch` this provider for the instance, and subscribe to the
/// store's own notifications with a `ListenableBuilder`/`AnimatedBuilder` so
/// rebuilds come from the store itself — there is no second copy to keep in
/// sync and nothing is ever written back to Riverpod.
final connectivityStoreProvider = Provider<ConnectivityStore>((ref) {
  return ConnectivityStore.instance;
});

/// One-way notification bridge from the app-owned [BoxController] into Riverpod.
///
/// [BoxController] is a [ChangeNotifier], but a plain [Provider] does not
/// rebuild when its value notifies. We deliberately do **not** turn
/// `boxControllerProvider` into a `ChangeNotifierProvider`: Riverpod owns and
/// disposes that notifier, while the controller is owned (and disposed) by
/// `BoxApp`. Instead this tiny notifier only forwards `stateChanges` — the
/// aspect that covers settings and preferences — so derived providers can
/// re-read fresh values from the controller. It holds no data of its own: the
/// bridge is a notification, never a second source of truth, and nothing is
/// ever written back through it.
final boxStateChangesProvider = ChangeNotifierProvider<ChangeNotifier>((ref) {
  final box = ref.watch(boxControllerProvider);
  return _BoxStateChangesBridge(box.stateChanges);
});

class _BoxStateChangesBridge extends ChangeNotifier {
  _BoxStateChangesBridge(this._source) {
    _source.addListener(_onChanged);
  }

  final Listenable _source;

  void _onChanged() => notifyListeners();

  // ChangeNotifierProvider calls dispose() on its notifier; remove our source
  // subscription there. Never dispose the source — the controller owns itself.
  @override
  void dispose() {
    _source.removeListener(_onChanged);
    super.dispose();
  }
}

/// The merged settings map, read fresh from [BoxController] on every rebuild.
///
/// The controller recomputes `settings` as `mergeSettings(host, preferences)`
/// on each read (ADR 0005 phase 2), so a cached whole-map copy would mask a
/// fresh host snapshot. Watching [boxStateChangesProvider] invalidates this
/// provider whenever settings/preferences change; the value itself is always
/// re-read from the controller. Writes stay on `context.box.setSetting()`.
final settingsProvider = Provider<Json>((ref) {
  ref.watch(boxStateChangesProvider);
  return ref.watch(boxControllerProvider).settings;
});

/// The preferences overlay, read fresh from [BoxController] on every rebuild.
///
/// Same one-way bridge and no-cache rule as [settingsProvider]. Appearance
/// reads this instead of `context.box.preferences`; writes stay on
/// `context.box.setPreference(s)`.
final preferencesProvider = Provider<Json>((ref) {
  ref.watch(boxStateChangesProvider);
  return ref.watch(boxControllerProvider).preferences;
});

// ---------------------------------------------------------------------------
// P12: page-layer providers.
//
// Every provider below is a *read* of the app-owned [BoxController]. The
// controller stays the single source of truth and the only writer; writes
// remain on `context.box.*`. A plain `Provider` (never a
// `ChangeNotifierProvider`) is used for the controller itself so Riverpod can
// never dispose it — the app owns the controller's lifetime.
//
// `boxChangesProvider` is the one-way notification bridge for all aspects: it
// forwards the controller's own Listenable into Riverpod and holds no data.
// Each field provider re-reads fresh from the controller whenever the bridge
// fires; Riverpod's built-in value comparison then rebuilds only dependents
// whose field actually changed (collections are replaced wholesale by the
// controller, scalars/derived values compare by ==). This is the same shape as
// the settings/preferences bridge above — a notification, never a second
// source of truth, and nothing is written back through Riverpod.
// ---------------------------------------------------------------------------

/// One-way bridge for every [BoxAspect], not just settings/preferences.
///
/// Pages that used `context.box` (all aspects) or `context.watchBox(aspect)`
/// watch the derived providers below, all of which depend on this bridge.
/// Holding the bridge in a ChangeNotifierProvider is safe: Riverpod disposes
/// the *bridge*, whose disposal only detaches the listener. The controller is
/// never disposed by Riverpod.
final boxChangesProvider = ChangeNotifierProvider<ChangeNotifier>((ref) {
  final box = ref.watch(boxControllerProvider);
  return _BoxNotifierBridge(box);
});

class _BoxNotifierBridge extends ChangeNotifier {
  _BoxNotifierBridge(this._source) {
    _source.addListener(_onChanged);
  }

  final Listenable _source;

  void _onChanged() => notifyListeners();

  @override
  void dispose() {
    _source.removeListener(_onChanged);
    super.dispose();
  }
}

/// The controller, rebuilt on the same `state` aspect the old
/// `context.box` (`BoxScope.of(aspect: state)`) subscribed to.
///
/// Pages that used `context.box` for a mix of state fields watch this provider:
/// it re-reads the same injected controller but re-evaluates whenever the
/// controller's `stateChanges` fires, exactly like the InheritedModel did.
/// Writes still go through the controller, never through Riverpod.
final boxStateProvider = Provider<BoxController>((ref) {
  ref.watch(boxStateChangesProvider);
  return ref.watch(boxControllerProvider);
});

/// Watch the injected controller with the old `context.box` rebuild semantics.
///
/// Watching [boxStateChangesProvider] subscribes the consumer to the bridge's
/// notifications (a `ChangeNotifierProvider` rebuilds its watchers whenever
/// the notifier fires), so the consumer rebuilds on every `state` event. The
/// controller itself is read fresh from [boxControllerProvider] and is never
/// copied or written back. This is preferred over watching [boxStateProvider]
/// directly: a plain `Provider` returning the *same* controller instance
/// compares equal and therefore would not rebuild its dependents.
extension BoxStateWatch on WidgetRef {
  BoxController watchBoxState() {
    watch(boxStateChangesProvider);
    return read(boxControllerProvider);
  }
}

/// [Ref] form of [BoxStateWatchon WidgetRef] for `ConsumerState` subclasses.
extension BoxStateWatchRef on Ref {
  BoxController watchBoxState() {
    watch(boxStateChangesProvider);
    return read(boxControllerProvider);
  }
}

/// Re-evaluate [select] fresh from the injected controller whenever it notifies.
///
/// Collection fields compare by identity (the controller replaces them on
/// each event), scalars and derived getters by `==`; either way an unchanged
/// field does not rebuild its dependents.
T _readField<T>(Ref ref, T Function(BoxController box) select) {
  ref.watch(boxChangesProvider);
  return select(ref.watch(boxControllerProvider));
}

/// Shared state fields, each read fresh from the controller on notification.
final dashboardProvider = Provider<Json>((ref) => _readField(ref, (b) => b.dashboard));

/// The dashboard fields the status card and the network-takeover row render.
///
/// `dashboard` is replaced on every traffic tick (`box.dart` assigns the whole
/// map), so watching it directly rebuilt both widgets about once a second for
/// counters neither one shows. A record compares structurally, so only a real
/// change to one of these fields notifies.
typedef DashboardStatus = ({String status, int? startedAt, bool systemProxy});
final dashboardStatusProvider = Provider<DashboardStatus>((ref) {
  final dashboard = ref.watch(dashboardProvider);
  return (
    status: dashboard['status']?.toString() ?? '',
    startedAt: (dashboard['startedAt'] as num?)?.toInt(),
    systemProxy: dashboard['systemProxy'] == true,
  );
});
final profilesProvider = Provider<List<Json>>((ref) => _readField(ref, (b) => b.profiles));
final groupsProvider = Provider<List<Json>>((ref) => _readField(ref, (b) => b.groups));
final connectionsProvider = Provider<List<Json>>((ref) => _readField(ref, (b) => b.connections));
final logsProvider = Provider<List<Json>>((ref) => _readField(ref, (b) => b.logs));
final logcatProvider = Provider<List<Json>>((ref) => _readField(ref, (b) => b.logcat));
final testSessionProvider = Provider<Json>((ref) => _readField(ref, (b) => b.testSession));
final toolStateProvider = Provider<Json>((ref) => _readField(ref, (b) => b.toolState));
final terminalProvider = Provider<Json>((ref) => _readField(ref, (b) => b.terminal));
final inboxProvider = Provider<Json>((ref) => _readField(ref, (b) => b.inbox));
final pingProvider = Provider<Json>((ref) => _readField(ref, (b) => b.ping));
final transfersProvider = Provider<List<Json>>((ref) => _readField(ref, (b) => b.transfers));
final usbDevicesProvider = Provider<List<Json>>((ref) => _readField(ref, (b) => b.usbDevices));
final memoryProvider = Provider<Json>((ref) => _readField(ref, (b) => b.memory));
final lanProvider = Provider<Json>((ref) => _readField(ref, (b) => b.lan));
final ratesProvider = Provider<Json>((ref) => _readField(ref, (b) => b.rates));
final capabilitiesProvider = Provider<BoxCapabilities>((ref) => _readField(ref, (b) => b.capabilities));
final logcatLevelProvider = Provider<String?>((ref) => _readField(ref, (b) => b.logcatLevel));
final defaultLogLevelProvider = Provider<String?>((ref) => _readField(ref, (b) => b.defaultLogLevel));
final applyRequiredProvider = Provider<String?>((ref) => _readField(ref, (b) => b.applyRequired));

/// Derived connection state, computed from the fresh dashboard snapshot.
final runningProvider = Provider<bool>((ref) => _readField(ref, (b) => b.running));
final remoteProvider = Provider<bool>((ref) => _readField(ref, (b) => b.remote));
final transitioningProvider = Provider<bool>((ref) => _readField(ref, (b) => b.transitioning));
final serviceSettingsChangingProvider =
    Provider<bool>((ref) => _readField(ref, (b) => b.serviceSettingsChanging));

/// The selected profile id, derived from the dashboard.
final selectedProfileIdProvider = Provider<int>((ref) => _readField(ref, (b) => b.selectedProfileId));

/// The selected profile row, derived from the fresh profiles + dashboard.
final selectedProfileProvider = Provider<Json?>((ref) => _readField(ref, (b) => b.selectedProfile));

/// Version / core identity strings, populated on `ready`.
final versionProvider = Provider<String>((ref) => _readField(ref, (b) => b.version));
final coreVersionProvider = Provider<String>((ref) => _readField(ref, (b) => b.coreVersion));
final coreRefShortProvider = Provider<String>((ref) => _readField(ref, (b) => b.coreRefShort));
final systemAccentColorProvider = Provider<int>((ref) => _readField(ref, (b) => b.systemAccentColor));

/// Traffic snapshot: the histories are mutated in place, so the revision is
/// part of the value (a record, so it has structural equality) to make
/// Riverpod's comparison notice new samples.
typedef TrafficSnapshot = ({Json rates, Json dashboard, int revision});

final trafficProvider = Provider<TrafficSnapshot>((ref) => _readField(ref, (b) =>
    (rates: b.rates, dashboard: b.dashboard, revision: b.sampleRevision)));

/// The rate map alone, for tiles that only need the current throughput.
/// Compared by identity: the controller replaces [rates] on each tick.
final currentRatesProvider = Provider<Json>((ref) => _readField(ref, (b) => b.rates));

// ---------------------------------------------------------------------------
// P14-B: component-layer derived providers.
//
// Components used `context.box` (the `state` aspect) for a handful of derived
// getters that had no field provider of their own. Each provider below is a
// read of the app-owned [BoxController] through the same one-way bridge as the
// page-layer providers — no data is copied into Riverpod and nothing is ever
// written back. They exist so a component can `ref.watch` the exact value it
// renders instead of subscribing to every state change via `watchBoxState()`.
// ---------------------------------------------------------------------------

/// Derived LAN getters (all from the `state` aspect `lan` + dashboard fields).
final lanAddressesProvider = Provider<List<String>>((ref) => _readField(ref, (b) => b.lanAddresses));
final lanCopyTextProvider = Provider<String?>((ref) => _readField(ref, (b) => b.lanCopyText));
final lanProxyEndpointsProvider = Provider<List<String>>((ref) => _readField(ref, (b) => b.lanProxyEndpoints));
final canSetLanProxyProvider = Provider<bool>((ref) => _readField(ref, (b) => b.canSetLanProxy));
final lanChangingProvider = Provider<bool>((ref) => _readField(ref, (b) => b.lanChanging));
