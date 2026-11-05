import 'dart:async';

import 'package:flutter/foundation.dart';

/// Visibility gate for high-frequency refresh work.
///
/// Bettbox's `DashboardRefreshManager` stops ticking when the window is hidden
/// or the dashboard is not on screen. This is the mobile equivalent: when the
/// app is backgrounded the data keeps arriving from the Kotlin side, but the
/// UI is not rebuilt for every push. The pending aspects are replayed once on
/// resume, so nothing is stale when the user comes back.
class RefreshGate extends ChangeNotifier {
  RefreshGate({bool Function()? pageIsDashboard})
      : pageIsDashboard = pageIsDashboard ?? _alwaysDashboard;

  static bool _alwaysDashboard() => true;

  /// The host page reports whether a dashboard-grade refresh is meaningful.
  final bool Function() pageIsDashboard;

  final ValueNotifier<int> tick1s = ValueNotifier<int>(0);
  final ValueNotifier<int> tick2s = ValueNotifier<int>(0);
  final ValueNotifier<int> tick5s = ValueNotifier<int>(0);

  Timer? _timer;
  int _counter = 0;
  int _generation = 0;
  bool _foreground = true;

  bool get foreground => _foreground;

  /// Whether a high-frequency event should rebuild widgets right now.
  bool get shouldRebuild => _foreground && pageIsDashboard();

  /// Called by the app's `WidgetsBindingObserver` on lifecycle changes.
  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    if (value) {
      start();
    } else {
      stop();
    }
    notifyListeners();
  }

  void start() {
    if (_timer != null) return;
    final generation = ++_generation;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!shouldRebuild || generation != _generation) return;
      _counter++;
      tick1s.value++;
      if (_counter % 2 == 0) tick2s.value++;
      if (_counter % 5 == 0) tick5s.value++;
    });
  }

  void stop() {
    _generation++;
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    stop();
    tick1s.dispose();
    tick2s.dispose();
    tick5s.dispose();
    super.dispose();
  }
}
