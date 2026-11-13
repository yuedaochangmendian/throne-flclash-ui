// The Bettbox-style JSON action protocol (ADR 0002, phase 1).
//
// Dart talks to the kernel through one C entry point (`throne_invoke_action`),
// sending an Action and receiving an ActionResult whose id echoes the request.
// The typed `throne_*` exports remain as the Go handlers' implementation.
//
// There is deliberately no freezed/build_runner here: the wire shapes are tiny,
// and one hand-written codec is easier for action_contract.py to audit than a
// generated enum map. That script checks this enum against the Go Method
// constants and the dispatcher registry by wire string.

import 'dart:convert';

/// One request method. The member's name IS the wire string; do not add a
/// separate map. `tools/diagnostics/action_contract.py` enforces that each
/// member has a Go Method constant and a registered handler.
enum ActionMethod {
  actionVersion,

  // Phase 3a: the speed test. There is no `query` member on purpose — progress
  // arrives as a `speedTest` push on the kernel's message port.
  startSpeedTest,
  cancelSpeedTest,
  speedTestServers,
  speedTestOutbounds,

  // Phase 3c: routing. Go owns the route documents; Kotlin keeps a read-only view.
  //
  // The routing UI now offers only "add a rule" against the shared pool, so the
  // profile CRUD, batch-add, reset and per-profile opt-out methods are gone with
  // it. What remains is the pool's read/write/delete and the per-profile rule
  // list the DNS import still appends to.
  getRouteProfiles,
  getRouteRules,
  saveRouteRules,
  getGlobalRules,
  saveGlobalRules,
  deleteGlobalRule,

  // Phase 3d PR-3: profile reads. Go answers these from Room — the same
  // database GroupRepo and ProfileManager write (see room_db.go) — because the
  // JSON-document store this phase started with answered stale rows. Methods
  // that need the Kotlin outbound model (share links, full config) stay on the
  // channel.
  profileStats,
  profileNodeInfo,
  profileNodeConfig,
  profileNodeTuningInfo,

  // Phase 3d PR-4: simple profile mutations. Complex writes (save, createNode,
  // commitNode, updateNode, groupSettings) need the Kotlin outbound model and
  // stay on the channel.
  profileReorder,
  profileNodeDelete,
  profileClearTestResults,
  profileClearTraffic,

  // Phase 3d PR-5: the auto-selector editor's save. The one write in the
  // profiles surface with no outbound model in the way: the selector is a flat
  // JSON document in `profiles.outbound_json`, and Go merges the form's values
  // into it. The runtime fields (`pool`, `last_built`, `history`) survive
  // because the merge never names them — rebuilding from the form would drop
  // them. The selector's read path, pin and recheck need AutoSelectorRuntime
  // and stay on the channel.
  autoSelectorSave,
}

/// `message` is the tag of an unsolicited Go->Dart push. It never appears in
/// [ActionMethod] because it has no handler and cannot be invoked.
const actionPushMethod = 'message';

class Action {
  const Action({required this.id, required this.method, this.data});

  final String id;
  final ActionMethod method;
  final Object? data;

  String encode() => jsonEncode({
    'id': id,
    'method': method.name,
    if (data != null) 'data': data,
  });
}

class ActionResult {
  const ActionResult({
    required this.id,
    required this.method,
    required this.code,
    this.data,
  });

  /// Empty for a push, or for a malformed action the kernel could not parse.
  final String id;
  final String method;
  final int code;
  final Object? data;

  bool get isError => code != 0;

  static ActionResult? decode(Object? raw) {
    if (raw is! String) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      // A push event uses {"method","data"} with no id and no code. An action
      // result uses {"id","method","data","code"}. A message carrying an id but
      // no code is a truncated result: treat it as an error rather than
      // dropping it, so its pending Completer is never left hanging.
      final id = '${decoded['id'] ?? ''}';
      if (!decoded.containsKey('code') && id.isEmpty) return null;
      return ActionResult(
        id: id,
        method: '${decoded['method'] ?? ''}',
        code: (decoded['code'] as num?)?.toInt() ?? -1,
        data: decoded['data'],
      );
    } catch (_) {
      return null;
    }
  }
}

/// Thrown when the kernel answers an action with a non-zero code.
class ActionException implements Exception {
  const ActionException(this.method, this.message);

  final String method;
  final String message;

  @override
  String toString() => 'ActionException($method): $message';
}
