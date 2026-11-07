// Bettbox-aligned IP detail & risk enrichment (GPL-3.0 lineage, reimplemented).
//
// The dashboard's automatic quality lookup (ip_quality.dart) keeps its FlClash
// six-source hedged "first source that states a type wins" contract: that path
// is covered by tests that assert exact request counts, URLs and wave timing,
// and it must stay fast. This module is the complementary, *on-demand* layer:
// it mirrors Bettbox's `queryIpDetail` + `queryIpRisk` — query several sources
// at once and merge them by filling in whichever fields each source can answer,
// then add a scamalytics Fraud Score. It is invoked only when the user opens
// the outbound-IP details page and asks for it, exactly like Bettbox's IP card
// only queries the risk score when the shield button is tapped.
//
// Scope notes:
//  * Bettbox's `IpInfo.normalizeCountryCode` / `_isTaiwan` mapping is NOT
//    ported. A source's country code/name are passed through verbatim; this
//    layer never rewrites a region label into a separate "country". Hong Kong,
//    Macao and Taiwan, China are referred to as 中国香港 / 中国澳门 / 中国台湾
//    wherever a human label is produced.
//  * ip-api.com's free endpoint only serves cleartext HTTP (HTTPS answers 403
//    "SSL unavailable for this endpoint", the same trade pre.14 documented).
//    The reply carries no secret; a forged answer only mislabels an info card.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'ip_probe.dart';

/// Bettbox's `IpRiskLevel`, kept as a compact score bucket for the card.
enum IpRiskLevel {
  low('Low'), medium('Medium'), high('High'), veryHigh('Very high');
  const IpRiskLevel(this.label);
  final String label;
}

/// One merged view of an IP: Bettbox `IpInfo` geography/ASN fields plus a
/// scamalytics-style fraud score. Every field is optional because each source
/// answers a different subset; [merge] is what combines them.
class IpEnrichment {
  const IpEnrichment({
    required this.ip,
    this.countryCode,
    this.country,
    this.region,
    this.city,
    this.isp,
    this.asn,
    this.asName,
    this.asDomain,
    this.continent,
    this.riskScore,
    this.riskLevel,
    this.sources = const <String>[],
  });

  final String ip;
  final String? countryCode, country, region, city, isp, asn, asName,
      asDomain, continent;
  final int? riskScore;
  final IpRiskLevel? riskLevel;
  final List<String> sources;

  bool get isEmpty => countryCode == null && country == null && region == null &&
      city == null && isp == null && asn == null && asName == null &&
      asDomain == null && continent == null && riskScore == null &&
      riskLevel == null && sources.isEmpty;

  /// Bettbox `IpInfo.merge`: keep the first non-empty value for every field,
  /// so a source that answers "country" and another that answers "asn" produce
  /// one enriched record instead of a winner-takes-all one.
  IpEnrichment merge(IpEnrichment other) => IpEnrichment(
    ip: ip,
    countryCode: _first(countryCode, other.countryCode),
    country: _first(country, other.country),
    region: _first(region, other.region),
    city: _first(city, other.city),
    isp: _first(isp, other.isp),
    asn: _first(asn, other.asn),
    asName: _first(asName, other.asName),
    asDomain: _first(asDomain, other.asDomain),
    continent: _first(continent, other.continent),
    riskScore: riskScore ?? other.riskScore,
    riskLevel: riskLevel ?? other.riskLevel,
    sources: <String>{...sources, ...other.sources}.toList(),
  );

  Map<String, Object?> toJson() => {
    'ip': ip,
    'countryCode': countryCode, 'country': country, 'region': region,
    'city': city, 'isp': isp, 'asn': asn, 'asName': asName,
    'asDomain': asDomain, 'continent': continent,
    'riskScore': riskScore, 'riskLevel': riskLevel?.name,
    'sources': sources,
  };

  factory IpEnrichment.fromJson(Map<String, dynamic> json) {
    IpRiskLevel? level;
    final levelName = json['riskLevel'];
    if (levelName is String) {
      for (final candidate in IpRiskLevel.values) {
        if (candidate.name == levelName) { level = candidate; break; }
      }
    }
    return IpEnrichment(
      ip: json['ip'] as String? ?? '',
      countryCode: json['countryCode'] as String?,
      country: json['country'] as String?,
      region: json['region'] as String?,
      city: json['city'] as String?,
      isp: json['isp'] as String?,
      asn: json['asn'] as String?,
      asName: json['asName'] as String?,
      asDomain: json['asDomain'] as String?,
      continent: json['continent'] as String?,
      riskScore: (json['riskScore'] as num?)?.toInt(),
      riskLevel: level,
      sources: (json['sources'] as List? ?? const []).map((e) => '$e').toList(),
    );
  }

  /// Keys consumed by EgressDetails. Only non-null values are emitted so the
  /// row set stays unchanged when enrichment is unavailable.
  Map<String, Object?> toDashboard() => {
    if (countryCode != null) 'enrichCountryCode': countryCode,
    if (country != null) 'enrichCountry': country,
    if (region != null) 'enrichRegion': region,
    if (city != null) 'enrichCity': city,
    if (isp != null) 'enrichIsp': isp,
    if (asn != null) 'enrichAsn': asn,
    if (asName != null) 'enrichAsName': asName,
    if (asDomain != null) 'enrichAsDomain': asDomain,
    if (continent != null) 'enrichContinent': continent,
    if (riskScore != null) 'enrichRiskScore': riskScore,
    if (riskLevel != null) 'enrichRiskLevel': riskLevel!.label,
    if (sources.isNotEmpty) 'enrichSources': sources.join(', '),
  };
}

String? _first(String? a, String? b) => _blank(a) ? ( _blank(b) ? null : b) : a;
bool _blank(String? v) => v == null || v.trim().isEmpty;
String? _text(Object? v) {
  if (v is String) return v.trim().isEmpty ? null : v.trim();
  if (v is num) return v.toString();
  return null;
}

/// Bettbox's IP sources (request.dart), grouped by what they can answer.
/// The `myip`/trace endpoints only report the caller's own egress IP, so they
/// are listed for parity but are not used to look up a *specified* IP here.
const bettboxIpSources = <String, List<String>>{
  'detail': [
    'http://ip-api.com/json/{ip}?fields=status,message,country,countryCode,region,regionName,city,isp,org,as,asname,continent,query',
    'https://get.geojs.io/v1/ip/geo/{ip}.json',
    'https://api.ip.sb/geoip/{ip}',
  ],
  'risk': ['https://scamalytics.com/ip/{ip}'],
  'own-egress': [
    'https://myip.ipip.net/json',
    'https://uapis.cn/api/v1/network/myip',
    'https://ip.sb/cdn-cgi/trace',
    'https://api.ip.sb/cdn-cgi/trace',
  ],
};

List<String> enrichmentUrls(String ip) => [
  for (final template in bettboxIpSources['detail']!)
    template.replaceAll('{ip}', Uri.encodeComponent(ip)),
  for (final template in bettboxIpSources['risk']!)
    template.replaceAll('{ip}', Uri.encodeComponent(ip)),
];

/// Parse a scamalytics IP page (Bettbox `common/ip_risk.dart`): the Fraud Score
/// is either rendered as "Fraud Score: 42" or embedded as `"score":"42"`.
/// Returns null when the page has no score, so an HTML redesign degrades to
/// "no risk data" instead of a bogus zero.
IpEnrichment? parseScamalytics(String ip, String html) {
  final body = html.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
  final raw = RegExp(r'Fraud Score:\s*(\d+)').firstMatch(body)?.group(1) ??
      RegExp(r'"score"\s*:\s*"(\d+)"').firstMatch(body)?.group(1);
  final score = int.tryParse(raw ?? '');
  if (score == null) return null;
  final clamped = score.clamp(0, 100).toInt();
  final riskText = (RegExp(r'"risk"\s*:\s*"([^"]+)"').firstMatch(body)?.group(1) ??
      RegExp(r'class="panel_title[^"]*"[^>]*>([^<]+)<').firstMatch(body)?.group(1) ??
      '').toLowerCase();
  final level = riskText.contains('very high') ? IpRiskLevel.veryHigh
      : riskText.contains('high') ? IpRiskLevel.high
      : riskText.contains('medium') ? IpRiskLevel.medium
      : riskText.contains('low') ? IpRiskLevel.low
      : clamped >= 90 ? IpRiskLevel.veryHigh
      : clamped >= 60 ? IpRiskLevel.high
      : clamped >= 30 ? IpRiskLevel.medium
      : IpRiskLevel.low;
  return IpEnrichment(ip: ip, riskScore: clamped, riskLevel: level,
    sources: const ['scamalytics.com']);
}

/// Parse one detail source's JSON into a partial IpEnrichment. Returns null on
/// a failed/irrelevant response; never throws on malformed payloads.
IpEnrichment? parseDetailSource(String ip, String host, Object? decoded) {
  if (decoded is! Map) return null;
  final map = Map<String, dynamic>.from(decoded);
  String? cc, country, region, city, isp, asn, asName, asDomain, continent;
  if (host == 'ip-api.com') {
    if (map['status'] != 'success') return null;
    cc = _text(map['countryCode']);
    country = _text(map['country']);
    region = _text(map['regionName']);
    city = _text(map['city']);
    isp = _text(map['isp']);
    final asLine = _text(map['as']) ?? ''; // e.g. "AS15169 Google LLC"
    asn = RegExp(r'AS\d+').firstMatch(asLine)?.group(0);
    asName = asLine.isEmpty ? null
        : asLine.replaceFirst(RegExp(r'^AS\d+\s*'), '').trim();
    asDomain = _text(map['org']) ?? _text(map['asname']);
    continent = _text(map['continent']);
  } else if (host == 'get.geojs.io') {
    cc = _text(map['country_code']) ?? _text(map['country_code3']);
    country = _text(map['country']);
    region = _text(map['region']);
    city = _text(map['city']);
    isp = _text(map['organization_name']) ?? _text(map['organization']);
    asn = _text(map['asn']);
    asName = _text(map['organization']);
    continent = _text(map['continent']);
  } else if (host == 'api.ip.sb') {
    final rawAsn = _text(map['asn']);
    cc = _text(map['country_code']);
    country = _text(map['country']);
    region = _text(map['region']);
    city = _text(map['city']);
    isp = _text(map['isp']);
    asn = rawAsn == null ? null : (rawAsn.startsWith('AS') ? rawAsn : 'AS$rawAsn');
    asName = _text(map['asn_organization']) ?? _text(map['organization']);
    asDomain = _text(map['organization']);
  } else {
    return null;
  }
  final partial = IpEnrichment(ip: ip, countryCode: cc, country: country,
    region: region, city: city, isp: isp, asn: asn, asName: _blank(asName) ? null : asName,
    asDomain: asDomain, continent: continent, sources: [host]);
  return partial.isEmpty ? null : partial;
}

class _EnrichmentFailure implements Exception {
  const _EnrichmentFailure();
}

/// Query every Bettbox detail + risk source in parallel and merge by field.
/// A failing source is skipped (the card still shows whatever the others
/// answered); cancellation and timeouts are honoured through [transport].
Future<IpEnrichment?> lookupIpEnrichment(
  IpProbeTransport transport,
  String ip, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  if (transport.cancelled || ip.isEmpty) return null;
  final futures = <Future<IpEnrichment?>>[
    for (final url in enrichmentUrls(ip)) _queryOne(transport, url, ip, timeout),
  ];
  final results = await Future.wait(futures);
  if (transport.cancelled) return null;
  IpEnrichment? merged;
  for (final partial in results) {
    if (partial == null) continue;
    merged = merged == null ? partial : merged.merge(partial);
  }
  return merged;
}

Future<IpEnrichment?> _queryOne(
  IpProbeTransport transport, String url, String ip, Duration timeout,
) async {
  try {
    final response = await transport.get(url, timeout).timeout(timeout);
    if (response.status != HttpStatus.ok) throw const _EnrichmentFailure();
    final host = Uri.parse(url).host;
    if (host == 'scamalytics.com') {
      return parseScamalytics(ip, response.body);
    }
    final decoded = jsonDecode(response.body);
    return parseDetailSource(ip, host, decoded);
  } on Object {
    return null; // A single dead source never fails the enrichment.
  }
}
