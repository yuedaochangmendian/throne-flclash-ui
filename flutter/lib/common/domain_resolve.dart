/// The reply of `dns.resolve`, shaped by `BboxResolve` on the host side.
///
/// The host answers `running: false` when no box is up (nothing to resolve through) and, when it
/// is up, one row per requested domain in request order: `addresses` holds what the tunnel's
/// `dns-direct` transport answered, `error` the reason it answered nothing.
class DomainResolveRow {
  const DomainResolveRow({required this.domain, this.addresses = const [], this.error = ''});

  final String domain;
  final List<String> addresses;
  final String error;

  bool get ok => error.isEmpty;

  /// What the row shows under the name: the addresses, or the reason there are none.
  String get detail => ok ? (addresses.isEmpty ? '' : addresses.join('\n')) : error;
}

class DomainResolveReply {
  const DomainResolveReply({required this.running, this.rows = const []});

  /// False when the host had no running box to ask; [rows] is then empty.
  final bool running;
  final List<DomainResolveRow> rows;

  static const idle = DomainResolveReply(running: false);

  /// Tolerates a missing or malformed reply: the page shows "nothing to resolve" instead of throwing.
  static DomainResolveReply parse(Object? value) {
    if (value is! Map) return idle;
    final raw = value['results'];
    final rows = <DomainResolveRow>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final domain = '${item['domain'] ?? ''}'.trim();
        if (domain.isEmpty) continue;
        final addresses = item['addresses'];
        rows.add(DomainResolveRow(
          domain: domain,
          addresses: addresses is List ? [for (final address in addresses) '$address'] : const [],
          error: '${item['error'] ?? ''}',
        ));
      }
    }
    return DomainResolveReply(running: value['running'] == true, rows: rows);
  }
}
