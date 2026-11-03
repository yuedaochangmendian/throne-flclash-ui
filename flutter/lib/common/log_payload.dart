/// FlClash parses mihomo's routing lines (`[tag] <endpoint> --> <dst> … using <proxy>`) into
/// rich text. This fork's core is sing-box / Xray, which never writes that shape, so the same
/// idea is applied to what they do write: the bridge has already split the level out of the
/// record, but the line still leads with it, its uptime counter and the subsystem tag —
/// `INFO[0001] inbound/tun[tun-in]: …` for sing-box, `[Info] [1234] transport/internet/tcp: …`
/// for Xray, `[Info] core: …` for this app's own log.
class LogPayload {
  /// The subsystem the line came from, as `component  ·  tag`; empty when the line has none.
  final String source;

  /// The line with its level, counter and subsystem prefixes removed.
  final String message;

  const LogPayload({this.source = '', required this.message});

  factory LogPayload.parse(String payload) {
    final original = payload.trim();
    final text = original
        .replaceFirst(_level, '')
        .replaceFirst(_counter, '')
        .trim();
    if (text.isEmpty) return LogPayload(message: original);
    final component = _component.firstMatch(text);
    if (component == null) return LogPayload(message: text);
    final name = component.group(1)!;
    // A word that is neither a known subsystem nor a path is part of the sentence, so a line
    // such as `error: context deadline exceeded` keeps reading as one message.
    if (!name.contains('/') && !_subsystems.contains(name.toLowerCase())) {
      return LogPayload(message: text);
    }
    final tag = component.group(2) ?? '';
    return LogPayload(
      source: [name, tag].where((part) => part.isNotEmpty).join('  ·  '),
      message: component.group(3)!.trim(),
    );
  }

  /// The level in any of the shapes the two cores and this app write it.
  static final _level = RegExp(
    '^(?:\\[\\s*(?:$_names)\\s*\\]|(?:$_names)\\s*\\[\\s*\\d+\\s*\\]|(?:$_names)(?=\\s))\\s*',
    caseSensitive: false,
  );

  /// sing-box and Xray both stamp a per-process counter before the subsystem.
  static final _counter = RegExp(r'^\[\s*\d+\s*\]\s*');

  static final _component = RegExp(
    r'^([A-Za-z][A-Za-z0-9_./+-]*)(?:\[([^\]]*)\])?:\s+(\S.*)$',
    dotAll: true,
  );

  static const _names = 'trace|debug|info|warn|warning|error|fatal|panic';

  /// Subsystems the cores log under, so a bare `word: …` is only split when it really is one.
  static const _subsystems = {
    'core', 'box', 'service', 'dns', 'router', 'inbound', 'outbound', 'connection',
    'conn', 'tun', 'rule', 'ruleset', 'cache', 'sniff', 'api', 'clash', 'experimental',
    'transport', 'proxy', 'dispatcher', 'stats', 'policy', 'resolver', 'urltest',
    'geosite', 'geoip', 'http', 'socks', 'mixed', 'redirect', 'tproxy',
  };
}
