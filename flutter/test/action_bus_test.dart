// The action bus's wire shapes and correlation rules (ADR 0002, phase 1).
//
// ThroneKernel.invoke needs a real ReceivePort and a native library, neither of
// which a unit test has. So the pure protocol layer is pinned here: what goes
// onto the wire, what counts as a result versus a push, and what an error code
// looks like. The Completer correlation itself is exercised through
// ThroneKernel's reply-port listener in kernel_runtime_test's FFI fixtures.

import 'dart:convert';

import 'package:flrone/core/action.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Action', () {
    test('encodes id, method name and data', () {
      final raw = const Action(
        id: 'actionVersion#7',
        method: ActionMethod.actionVersion,
        data: {'probe': true},
      ).encode();

      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      expect(decoded['id'], 'actionVersion#7');
      expect(decoded['method'], 'actionVersion');
      expect(decoded['data'], {'probe': true});
    });

    test('omits data when it is null', () {
      final decoded = jsonDecode(
        const Action(id: 'x#1', method: ActionMethod.actionVersion).encode(),
      ) as Map<String, dynamic>;

      expect(decoded.containsKey('data'), isFalse);
    });
  });

  group('ActionResult.decode', () {
    test('parses a successful result', () {
      final result = ActionResult.decode(
        jsonEncode({
          'id': 'actionVersion#3',
          'method': 'actionVersion',
          'data': {'protocol': 1},
          'code': 0,
        }),
      );

      expect(result, isNotNull);
      expect(result!.id, 'actionVersion#3');
      expect(result.isError, isFalse);
      expect(result.data, {'protocol': 1});
    });

    test('parses an error result', () {
      final result = ActionResult.decode(
        jsonEncode({
          'id': 'actionVersion#4',
          'method': 'actionVersion',
          'data': 'unknown action method: nope',
          'code': -1,
        }),
      );

      expect(result!.isError, isTrue);
      expect(result.data, 'unknown action method: nope');
    });

    test('a push event is not a result', () {
      // Go pushes {"method","data"} with no id and no code. Treating one as a
      // result would complete the wrong Completer (or none at all).
      expect(
        ActionResult.decode(jsonEncode({'method': 'log', 'data': {'level': 1}})),
        isNull,
      );
    });

    test('a result with an empty id is not correlated', () {
      // A malformed action cannot echo its id; the kernel still posts a
      // result, but there is no pending request to complete.
      final result = ActionResult.decode(
        jsonEncode({'id': '', 'method': 'x', 'code': -1, 'data': 'bad json'}),
      );
      expect(result, isNotNull);
      expect(result!.id, isEmpty);
      expect(result.isError, isTrue);
    });

    test('garbage and non-string input do not throw', () {
      expect(ActionResult.decode('not json'), isNull);
      expect(ActionResult.decode(42), isNull);
      expect(ActionResult.decode(null), isNull);
      expect(ActionResult.decode('[]'), isNull);
    });

    test('a missing code defaults to an error, not a success', () {
      final result = ActionResult.decode(
        jsonEncode({'id': 'x#1', 'method': 'x', 'data': 'partial'}),
      );
      expect(result!.isError, isTrue);
    });
  });

  group('ActionException', () {
    test('names the method that failed', () {
      const error = ActionException('actionVersion', 'timed out after 30s');
      expect(error.toString(), contains('actionVersion'));
      expect(error.toString(), contains('timed out'));
    });
  });
}
