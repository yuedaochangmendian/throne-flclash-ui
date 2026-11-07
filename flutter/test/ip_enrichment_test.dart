// Bettbox-aligned IP detail & risk enrichment (GPL-3.0 lineage, reimplemented).
import 'package:flrone/common/ip_enrichment.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/ip_probe.dart';

const _ip = '203.0.113.9';

typedef _Reply = ProbeReply;

_Reply _ok(Object body, [Duration delay = Duration.zero]) =>
    (status: 200, body: body, delay: delay);
_Reply _status(int status) => (status: status, body: null, delay: Duration.zero);

({FakeIpProbe adapter, Future<IpEnrichment?> result}) _lookup(
  Map<String, _Reply> replies, {
  Duration timeout = const Duration(seconds: 8),
}) {
  final adapter = FakeIpProbe(replies);
  addTearDown(adapter.close);
  return (adapter: adapter, result: lookupIpEnrichment(adapter, _ip, timeout: timeout));
}

const _ipApiReply = {
  'status': 'success',
  'country': 'United Kingdom', 'countryCode': 'GB',
  'regionName': 'England', 'city': 'London',
  'isp': 'Example Broadband', 'org': 'Example Ltd',
  'as': 'AS64500 Example Network', 'asname': 'example.net',
  'continent': 'Europe', 'query': _ip,
};
const _geojsReply = {
  'country': 'United Kingdom', 'country_code': 'GB',
  'region': 'England', 'city': 'London',
  'organization_name': 'Example Broadband', 'organization': 'AS64500 Example Network',
  'asn': 'AS64500', 'continent': 'Europe',
};
const _ipSbReply = {
  'country': 'United Kingdom', 'country_code': 'GB',
  'region': 'England', 'city': 'London', 'isp': 'Example ISP',
  'asn': 64500, 'asn_organization': 'Example Network', 'organization': 'example.net',
};

void main() {
  test('source list uses Bettbox endpoints and substitutes the IP', () {
    final urls = enrichmentUrls(_ip);
    expect(urls, hasLength(4)); // 3 detail + 1 risk
    expect(urls[0], startsWith('http://ip-api.com/json/$_ip?fields='));
    expect(urls[1], 'https://get.geojs.io/v1/ip/geo/$_ip.json');
    expect(urls[2], 'https://api.ip.sb/geoip/$_ip');
    expect(urls[3], 'https://scamalytics.com/ip/$_ip');
    // The cleartext trade is explicit, not accidental.
    expect(bettboxIpSources['detail']!.first, startsWith('http://ip-api.com'));
  });

  for (final (host, body, label) in <(String, Object, String)>[
    ('ip-api.com', _ipApiReply, 'ip-api.com'),
    ('get.geojs.io', _geojsReply, 'get.geojs.io'),
    ('api.ip.sb', _ipSbReply, 'api.ip.sb'),
  ]) {
    test('parses geography and ASN from $label', () {
      final partial = parseDetailSource(_ip, host, body);
      expect(partial, isNotNull);
      expect(partial!.countryCode, 'GB');
      expect(partial.country, 'United Kingdom');
      expect(partial.city, 'London');
      expect(partial.asn, anyOf('AS64500', '64500', contains('64500')));
      expect(partial.sources, [host]);
    });
  }

  test('a failed ip-api.com status is not treated as data', () {
    expect(parseDetailSource(_ip, 'ip-api.com', {'status': 'fail', 'message': 'private range'}), isNull);
  });

  test('unknown hosts and malformed payloads degrade to null, never throw', () {
    expect(parseDetailSource(_ip, 'example.com', {'country': 'X'}), isNull);
    expect(parseDetailSource(_ip, 'ip-api.com', 'not-a-map'), isNull);
    expect(parseDetailSource(_ip, 'ip-api.com', <String, dynamic>{}), isNull);
  });

  test('merge fills gaps from complementary sources (Bettbox IpInfo.merge)', () {
    final a = const IpEnrichment(ip: _ip, countryCode: 'GB', country: 'United Kingdom',
      sources: ['ip-api.com']);
    final b = const IpEnrichment(ip: _ip, isp: 'Example ISP', asn: 'AS64500',
      sources: ['api.ip.sb']);
    final merged = a.merge(b);
    expect(merged.country, 'United Kingdom'); // first non-empty wins
    expect(merged.isp, 'Example ISP');        // gap filled
    expect(merged.asn, 'AS64500');
    expect(merged.sources, unorderedEquals(['ip-api.com', 'api.ip.sb']));
    // Empty strings never override a real value.
    expect(a.merge(const IpEnrichment(ip: _ip, country: '  ')).country, 'United Kingdom');
  });

  test('scamalytics Fraud Score parses both HTML and JSON, with level buckets', () {
    final html = parseScamalytics(_ip, '<html><body>Fraud Score: 75</body></html>');
    expect(html!.riskScore, 75);
    expect(html.riskLevel, IpRiskLevel.high);
    final json = parseScamalytics(_ip, '{"score":"12","risk":"Low"}');
    expect(json!.riskScore, 12);
    expect(json.riskLevel, IpRiskLevel.low);
    final veryHigh = parseScamalytics(_ip, 'Fraud Score: 95');
    expect(veryHigh!.riskLevel, IpRiskLevel.veryHigh);
    expect(parseScamalytics(_ip, '<html>no score here</html>'), isNull,
      reason: 'an HTML redesign must degrade to no data, not a fake zero');
  });

  test('scamalytics score is clamped and comments are ignored', () {
    final r = parseScamalytics(_ip, '<!-- Fraud Score: 99 -->Fraud Score: 140');
    expect(r!.riskScore, 100);
    expect(r.riskLevel, IpRiskLevel.veryHigh);
  });

  test('lookup merges every live source and skips dead ones', () async {
    final lookup = _lookup({
      'ip-api.com': _ok(_ipApiReply),
      'get.geojs.io': _status(503),
      'api.ip.sb': _ok(_ipSbReply),
      'scamalytics.com': _ok('Fraud Score: 20'),
    });
    final result = await lookup.result;
    expect(result, isNotNull);
    expect(result!.country, 'United Kingdom');
    expect(result.isp, 'Example Broadband'); // ip-api.com answered it, wins
    expect(result.riskScore, 20);
    expect(result.sources, containsAll(<String>['ip-api.com', 'api.ip.sb', 'scamalytics.com']));
    expect(lookup.adapter.requested, hasLength(4));
  });

  test('all sources failing returns null without throwing', () async {
    final lookup = _lookup({});
    expect(await lookup.result, isNull);
    expect(lookup.adapter.requested, hasLength(4));
  });

  test('malformed JSON on one source does not sink the others', () async {
    final lookup = _lookup({
      'ip-api.com': (status: 200, body: '<html>captcha</html>', delay: Duration.zero),
      'api.ip.sb': _ok(_ipSbReply),
    });
    final result = await lookup.result;
    expect(result!.country, 'United Kingdom');
    expect(result.sources, contains('api.ip.sb'));
  });

  test('serialization round-trips every field and tolerates old cache shape', () {
    final value = const IpEnrichment(ip: _ip, countryCode: 'GB', country: 'United Kingdom',
      region: 'England', city: 'London', isp: 'Example', asn: 'AS64500',
      asName: 'Example Network', asDomain: 'example.net', continent: 'Europe',
      riskScore: 42, riskLevel: IpRiskLevel.medium, sources: ['ip-api.com']);
    final json = value.toJson();
    final restored = IpEnrichment.fromJson(Map<String, dynamic>.from(json));
    expect(restored.toJson(), json);
    // A record written by an older build has none of the enrichment keys.
    final legacy = IpEnrichment.fromJson(<String, dynamic>{'ip': _ip});
    expect(legacy.isEmpty, isTrue);
    expect(legacy.riskLevel, isNull);
    expect(legacy.sources, isEmpty);
  });

  test('toDashboard emits only present fields', () {
    final empty = const IpEnrichment(ip: _ip).toDashboard();
    expect(empty, isEmpty);
    final full = const IpEnrichment(ip: _ip, country: 'United Kingdom', riskScore: 5,
      riskLevel: IpRiskLevel.low, sources: ['ip-api.com']).toDashboard();
    expect(full['enrichCountry'], 'United Kingdom');
    expect(full['enrichRiskScore'], 5);
    expect(full['enrichRiskLevel'], 'Low');
    expect(full.containsKey('enrichCity'), isFalse);
  });

  test('country code is passed through verbatim; no region-to-country rewrite', () {
    // Bettbox's normalizeCountryCode / _isTaiwan is deliberately NOT ported.
    // Whatever a source labels a region is shown as-is, never split into a
    // separate country. This asserts the pass-through contract.
    final r = parseDetailSource(_ip, 'ip-api.com', {
      'status': 'success', 'country': 'China', 'countryCode': 'CN',
      'regionName': 'Hong Kong', 'city': 'Hong Kong',
    });
    expect(r!.country, 'China');
    expect(r.countryCode, 'CN');
    expect(r.region, 'Hong Kong');
    expect(r.city, 'Hong Kong');
  });

  test('cancellation is honoured', () async {
    final adapter = FakeIpProbe({
      'ip-api.com': _ok(_ipApiReply, const Duration(seconds: 2)),
    });
    addTearDown(adapter.close);
    final future = lookupIpEnrichment(adapter, _ip);
    adapter.cancel();
    expect(await future, isNull);
  });
}
