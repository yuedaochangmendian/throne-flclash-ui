import 'dart:async';

/// Coalesces a burst of calls sharing a [tag] into one trailing call.
///
/// Ported from Bettbox's `lib/common/function.dart`: timers are created in
/// [Zone.root] so a caller's error zone cannot swallow the scheduled callback,
/// and each tag owns its own timer so unrelated work is never cancelled.
class Debouncer {
  Debouncer({this.defaultDuration = const Duration(milliseconds: 600)});

  final Duration defaultDuration;
  final Map<Object, Timer> _timers = <Object, Timer>{};

  /// Schedules [action] after [duration], replacing any pending call for [tag].
  void run(Object tag, void Function() action, {Duration? duration}) {
    _timers.remove(tag)?.cancel();
    _timers[tag] = Zone.root.run(() => Timer(duration ?? defaultDuration, () {
      _timers.remove(tag);
      Zone.root.run(action);
    }));
  }

  /// Drops the pending call for [tag], if any.
  void cancel(Object tag) => _timers.remove(tag)?.cancel();

  /// Drops every pending call. Call from `dispose`.
  void cancelAll() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }
}

/// Leading-edge throttle: runs immediately, then ignores calls for the same
/// [tag] until the window closes. Returns false when the call was suppressed.
class Throttler {
  Throttler({this.defaultDuration = const Duration(milliseconds: 600)});

  final Duration defaultDuration;
  final Set<Object> _active = <Object>{};

  /// Runs [action] unless [tag] is inside its window.
  bool run(Object tag, void Function() action, {Duration? duration}) {
    if (_active.contains(tag)) return false;
    _active.add(tag);
    Zone.root.run(() => Timer(duration ?? defaultDuration, () => _active.remove(tag)));
    Zone.root.run(action);
    return true;
  }

  /// Clears every active window. Call from `dispose`.
  void clear() => _active.clear();
}

/// Retries [task] with exponential backoff and a per-attempt timeout.
///
/// [retryIf] decides which errors are transient; a non-transient error is
/// rethrown immediately. Used for network-bound bridge calls (subscription
/// refresh, WebDAV backup) rather than for UI state changes.
Future<T> retryCall<T>({
  required Future<T> Function() task,
  bool Function(Object error) retryIf = _defaultRetryIf,
  int maxAttempts = 3,
  Duration initialDelay = const Duration(milliseconds: 300),
  Duration timeout = const Duration(seconds: 30),
}) async {
  var attempt = 0;
  var delay = initialDelay;
  while (true) {
    attempt++;
    try {
      return await task().timeout(timeout);
    } catch (error) {
      if (attempt >= maxAttempts || !retryIf(error)) rethrow;
      await Future<void>.delayed(delay);
      delay *= 2;
    }
  }
}

bool _defaultRetryIf(Object error) => true;
