import 'package:flrone/common/domain_resolve.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DomainResolveReply.parse', () {
    test('reads the host reply in request order', () {
      final reply = DomainResolveReply.parse(<String, Object?>{
        'running': true,
        'results': <Object?>[
          <String, Object?>{'domain': 'example.com', 'addresses': <Object?>['93.184.216.34', '2606:2800::1'], 'error': ''},
          <String, Object?>{'domain': 'missing.invalid', 'addresses': <Object?>[], 'error': 'no such host'},
        ],
      });

      expect(reply.running, isTrue);
      expect(reply.rows.map((row) => row.domain), ['example.com', 'missing.invalid']);
      expect(reply.rows.first.addresses, ['93.184.216.34', '2606:2800::1']);
      expect(reply.rows.first.ok, isTrue);
      expect(reply.rows.last.ok, isFalse);
      expect(reply.rows.last.detail, 'no such host');
    });

    test('a codec-shaped map with Object keys still parses', () {
      // StandardMessageCodec hands back Map<Object?, Object?> before BoxController normalizes it.
      final Map<Object?, Object?> raw = <Object?, Object?>{
        'running': true,
        'results': <Object?>[
          <Object?, Object?>{'domain': 'a.test', 'addresses': <Object?>['10.0.0.1'], 'error': ''},
        ],
      };

      final reply = DomainResolveReply.parse(raw);
      expect(reply.running, isTrue);
      expect(reply.rows.single.addresses, ['10.0.0.1']);
    });

    test('a reply with no running box has no rows', () {
      final reply = DomainResolveReply.parse(<String, Object?>{'running': false, 'results': <Object?>[]});
      expect(reply.running, isFalse);
      expect(reply.rows, isEmpty);
    });

    test('garbage degrades to idle instead of throwing', () {
      expect(DomainResolveReply.parse(null), same(DomainResolveReply.idle));
      expect(DomainResolveReply.parse('not a map'), same(DomainResolveReply.idle));
      expect(DomainResolveReply.parse(<String, Object?>{'results': 'nope'}).rows, isEmpty);
    });

    test('rows without a domain are dropped', () {
      final reply = DomainResolveReply.parse(<String, Object?>{
        'running': true,
        'results': <Object?>[
          <String, Object?>{'domain': '  ', 'addresses': <Object?>['10.0.0.1']},
          <String, Object?>{'domain': 'b.test'},
        ],
      });
      expect(reply.rows.map((row) => row.domain), ['b.test']);
      expect(reply.rows.single.detail, '', reason: 'no error and no address shows the empty-detail hint');
    });
  });
}
