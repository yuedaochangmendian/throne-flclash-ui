import 'package:flrone/common/log_payload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const cases = <String, (String, String)>{
    // sing-box leads with the level and its uptime, then the subsystem.
    'INFO[0001] inbound/tun[tun-in]: inbound connection from 10.0.0.2:51234':
        ('inbound/tun  ·  tun-in', 'inbound connection from 10.0.0.2:51234'),
    'INFO[0012] outbound/vless[proxy]: outbound connection to example.com:443':
        ('outbound/vless  ·  proxy', 'outbound connection to example.com:443'),
    'ERROR[0009] router: match[3] => direct': ('router', 'match[3] => direct'),
    // Xray brackets the level and stamps a counter before the subsystem.
    '[Info] [1234] transport/internet/tcp: dialing tcp 1.2.3.4:443':
        ('transport/internet/tcp', 'dialing tcp 1.2.3.4:443'),
    '[Warn] [5678] app/dns: lookup failed': ('app/dns', 'lookup failed'),
    // This app's own log tags its lines instead of naming a subsystem path.
    '[Info] core: sing-box 1.10.0, xray 1.8.0': ('core', 'sing-box 1.10.0, xray 1.8.0'),
  };

  for (final entry in cases.entries) {
    test('splits ${entry.key}', () {
      final payload = LogPayload.parse(entry.key);
      expect(payload.source, entry.value.$1);
      expect(payload.message, entry.value.$2);
    });
  }

  // A word that only looks like a tag must not be torn off the sentence.
  for (final line in [
    'error: context deadline exceeded',
    'dial tcp 1.2.3.4:443: connect: connection refused',
    'inbound connection from 10.0.0.2:51234',
    'plain message',
  ]) {
    test('leaves $line whole', () {
      final payload = LogPayload.parse(line);
      expect(payload.source, isEmpty);
      expect(payload.message, line);
    });
  }

  test('a blank line parses to an empty message', () {
    expect(LogPayload.parse('   ').message, isEmpty);
    expect(LogPayload.parse('').source, isEmpty);
  });
}
