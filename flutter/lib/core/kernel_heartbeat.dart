/// Heartbeat state machine for the long-lived FFI kernel worker.
///
/// Kept pure so the grace and give-up rules can be tested without loading
/// `libthrone.so`. A readable status or a live instance is a beat; only an
/// unreadable status for a dead instance after both windows may report loss.
class KernelHeartbeatPolicy {
  int? _startedAtMs;
  int? _lastBeatAtMs;
  bool _enabled = false;
  bool _lostReported = false;

  bool get enabled => _enabled;
  int? get startedAtMs => _startedAtMs;

  void prepare() {
    _startedAtMs = null;
    _lastBeatAtMs = null;
    _lostReported = false;
  }

  void start(int nowMs) {
    _startedAtMs = nowMs;
    _lastBeatAtMs = null;
    _lostReported = false;
  }

  void setEnabled(bool value, int nowMs) {
    _enabled = value;
    if (value && _startedAtMs == null) _startedAtMs = nowMs;
    _lastBeatAtMs = null;
    _lostReported = false;
  }

  void stop() {
    _enabled = false;
    _startedAtMs = null;
    _lastBeatAtMs = null;
    _lostReported = false;
  }

  /// Returns true exactly once per lost transition while the state stays dead.
  bool observe({
    required int nowMs,
    required bool snapshotReadable,
    required bool instanceAlive,
    required Duration grace,
    required Duration giveUpAfter,
  }) {
    if (!_enabled || _startedAtMs == null) return false;
    if (snapshotReadable || instanceAlive) {
      _lastBeatAtMs = nowMs;
      _lostReported = false;
      return false;
    }
    final startedAt = _startedAtMs!;
    if (nowMs - startedAt < grace.inMilliseconds) return false;
    final since = _lastBeatAtMs ?? startedAt;
    if (nowMs - since < giveUpAfter.inMilliseconds || _lostReported) return false;
    _lostReported = true;
    return true;
  }
}
