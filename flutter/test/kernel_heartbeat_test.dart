import 'package:flrone/core/kernel_heartbeat.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const grace = Duration(seconds: 12);
  const giveUp = Duration(seconds: 8);

  bool observe(KernelHeartbeatPolicy policy, int now,
      {bool snapshot = false, bool alive = false}) =>
      policy.observe(
        nowMs: now,
        snapshotReadable: snapshot,
        instanceAlive: alive,
        grace: grace,
        giveUpAfter: giveUp,
      );

  test('an enabled heartbeat ignores misses during startup grace', () {
    final policy = KernelHeartbeatPolicy()..setEnabled(true, 0)..start(0);
    expect(observe(policy, 11999), isFalse);
  });

  test('a readable snapshot or a live instance refreshes the beat', () {
    final policy = KernelHeartbeatPolicy()..setEnabled(true, 0)..start(0);
    expect(observe(policy, 12000, snapshot: true), isFalse);
    expect(observe(policy, 15000, alive: true), isFalse);
    expect(observe(policy, 22000), isFalse, reason: 'give-up window starts at the last good beat');
  });

  test('loss is reported once after grace and the give-up window', () {
    final policy = KernelHeartbeatPolicy()..setEnabled(true, 0)..start(0);
    expect(observe(policy, 11999), isFalse);
    expect(observe(policy, 12000), isTrue, reason: 'grace elapsed and no beat has arrived');
    expect(observe(policy, 13000), isFalse, reason: 'a lost verdict is emitted once');
    expect(observe(policy, 21000), isFalse);
  });

  test('a fresh beat clears a previous loss verdict', () {
    final policy = KernelHeartbeatPolicy()..setEnabled(true, 0)..start(0);
    expect(observe(policy, 20000), isTrue);
    expect(observe(policy, 21000, snapshot: true), isFalse);
    expect(observe(policy, 22000), isFalse);
    expect(observe(policy, 30000), isTrue);
  });

  test('stop and prepare clear timers and enablement', () {
    final policy = KernelHeartbeatPolicy()..setEnabled(true, 0)..start(0);
    policy.stop();
    expect(policy.enabled, isFalse);
    expect(observe(policy, 30000), isFalse);
    policy
      ..setEnabled(true, 30000)
      ..prepare();
    expect(policy.enabled, isTrue);
    expect(policy.startedAtMs, isNull);
    expect(observe(policy, 50000), isFalse);
  });
}
