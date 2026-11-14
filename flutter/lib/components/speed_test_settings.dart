// The speed test's settings and history, in Bettbox's shape.
//
// Bettbox puts the run's knobs behind one dialog (provider, server, duration,
// connection count, protocol) and the finished runs behind a history sheet. This
// file carries both, built from the widgets this project already uses so they
// match the rest of the app rather than importing Bettbox's chrome.

import 'dart:math' as math;

import '../widgets.dart';
import '../services/speed_test_history.dart';
import 'speed_gauge.dart';

/// The values the settings dialog edits. Mirrors the page's own knobs so the
/// dialog can be a pure function of its inputs.
class SpeedTestSettings {
  const SpeedTestSettings({
    this.provider = 'apple',
    this.protocol = 'h1',
    this.duration = 10,
    this.streams = 8,
    this.serverHost = '',
    this.serverName = '',
    this.serverCc = '',
    this.serverSponsor = '',
  });

  final String provider, protocol;
  final int duration, streams;

  /// The pinned speedtest.net server, empty when the provider picks one.
  final String serverHost, serverName, serverCc, serverSponsor;

  bool get hasServer => serverHost.isNotEmpty;

  SpeedTestSettings copyWith({
    String? provider,
    String? protocol,
    int? duration,
    int? streams,
    String? serverHost,
    String? serverName,
    String? serverCc,
    String? serverSponsor,
  }) => SpeedTestSettings(
    provider: provider ?? this.provider,
    protocol: protocol ?? this.protocol,
    duration: duration ?? this.duration,
    streams: streams ?? this.streams,
    serverHost: serverHost ?? this.serverHost,
    serverName: serverName ?? this.serverName,
    serverCc: serverCc ?? this.serverCc,
    serverSponsor: serverSponsor ?? this.serverSponsor,
  );

  Map<String, Object?> toJson() => {
    'provider': provider,
    'protocol': protocol,
    'duration': duration,
    'streams': streams,
    'serverHost': serverHost,
    'serverName': serverName,
    'serverCc': serverCc,
    'serverSponsor': serverSponsor,
  };

  factory SpeedTestSettings.fromJson(Map<String, Object?> json) =>
      SpeedTestSettings(
        provider: '${json['speedTestProvider'] ?? json['provider'] ?? 'apple'}',
        protocol: '${json['speedTestProtocol'] ?? json['protocol'] ?? 'h1'}',
        duration:
            (json['speedTestDuration'] as num? ?? json['duration'] as num?)
                ?.toInt() ??
            10,
        streams:
            (json['speedTestStreams'] as num? ?? json['streams'] as num?)
                ?.toInt() ??
            8,
        serverHost: '${json['serverHost'] ?? ''}',
        serverName: '${json['serverName'] ?? ''}',
        serverCc: '${json['serverCc'] ?? ''}',
        serverSponsor: '${json['serverSponsor'] ?? ''}',
      );

  /// The preference map this settings object writes.
  Map<String, Object?> toPreferences() => {
    'speedTestProvider': provider,
    'speedTestProtocol': protocol,
    'speedTestDuration': duration,
    'speedTestStreams': streams,
  };
}

/// The durations and connection counts Bettbox offers.
const speedTestDurations = [5, 10, 15, 20];
const speedTestStreams = [1, 2, 4, 6, 8, 12, 16];

/// Opens the settings dialog; null when the user backs out.
Future<SpeedTestSettings?> showSpeedTestSettings(
  BuildContext context,
  SpeedTestSettings initial,
) {
  return showAppDialog<SpeedTestSettings>(
    context,
    child: _SpeedTestSettingsDialog(initial: initial),
  );
}

class _SpeedTestSettingsDialog extends StatefulWidget {
  const _SpeedTestSettingsDialog({required this.initial});
  final SpeedTestSettings initial;
  @override
  State<_SpeedTestSettingsDialog> createState() =>
      _SpeedTestSettingsDialogState();
}

class _SpeedTestSettingsDialogState extends State<_SpeedTestSettingsDialog> {
  late SpeedTestSettings _settings = widget.initial;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: context.tr('Speed test settings'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.tr('Cancel')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _settings),
          child: Text(context.tr('Save')),
        ),
      ],
      child: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Label(context.tr('Provider')),
              _Choice(
                values: const ['apple', 'cloudflare', 'speedtest'],
                value: _settings.provider,
                labelOf: (value) => value == 'apple'
                    ? 'Apple'
                    : value == 'cloudflare'
                    ? 'Cloudflare'
                    : 'Speedtest',
                onChanged: (value) {
                  setState(() => _settings = _settings.copyWith(provider: value));
                },
              ),
              const SizedBox(height: 14),
              _Label(context.tr('Protocol')),
              _Choice(
                values: const ['h1', 'h2', 'h3'],
                value: _settings.protocol,
                labelOf: (value) => value == 'h3'
                    ? '${value.toUpperCase()} (QUIC)'
                    : value.toUpperCase(),
                onChanged: (value) {
                  setState(() => _settings = _settings.copyWith(protocol: value));
                },
              ),
              const SizedBox(height: 14),
              _Label(context.tr('Duration')),
              _Choice(
                values: speedTestDurations,
                value: _settings.duration,
                labelOf: (value) => '${value}s',
                onChanged: (value) {
                  setState(() => _settings = _settings.copyWith(duration: value));
                },
              ),
              const SizedBox(height: 14),
              _Label(context.tr('Connections')),
              _Choice(
                values: speedTestStreams,
                value: _settings.streams,
                labelOf: (value) => value == 1
                    ? '1 (${context.tr('single')})'
                    : '$value',
                onChanged: (value) {
                  setState(() => _settings = _settings.copyWith(streams: value));
                },
              ),
              if (_settings.hasServer) ...[
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Label(context.tr('Server')),
                          Text(
                            [
                              _settings.serverName,
                              _settings.serverCc,
                              _settings.serverSponsor,
                            ].where((part) => part.isNotEmpty).join(' · '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: context.listSubtitleStyle,
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(
                        () => _settings = _settings.copyWith(
                          serverHost: '',
                          serverName: '',
                          serverCc: '',
                          serverSponsor: '',
                        ),
                      ),
                      child: Text(context.tr('Clear')),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: context.listCaptionStyle),
  );
}

/// A row of Prism chips, one per value, the chosen one filled.
///
/// `Chip` owns the selection fill (primary + onPrimary), the pill shape and the
/// semantic label style, so this segment group no longer paints a call-site
/// radius or a generic container fill of its own.
class _Choice<T> extends StatelessWidget {
  const _Choice({
    required this.values,
    required this.value,
    required this.labelOf,
    required this.onChanged,
  });

  final List<T> values;
  final T value;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final option in values)
          Chip(
            label: labelOf(option),
            selected: option == value,
            onPressed: () => onChanged(option),
          ),
      ],
    );
  }
}

/// The finished runs, newest first, with a detail view per record.
Future<void> showSpeedTestHistory(
  BuildContext context, {
  required BoxController box,
}) async {
  final records = await readSpeedTestHistory(box);
  if (!context.mounted) return;
  // Prism's own sheet (bottom sheet on a phone, side sheet elsewhere) keeps
  // the drag handle, the surface and dismissal in one place. Its content is a
  // shrink-wrapping list, so a long history is reachable without a separate
  // isScrollControlled flag.
  await showSheet<void>(
    context: context,
    builder: (sheetContext) => _HistorySheet(records: records, box: box),
  );
}

class _HistorySheet extends StatefulWidget {
  const _HistorySheet({required this.records, required this.box});
  final List<SpeedTestRecord> records;
  final BoxController box;
  @override
  State<_HistorySheet> createState() => _HistorySheetState();
}

class _HistorySheetState extends State<_HistorySheet> {
  late List<SpeedTestRecord> _records = widget.records;

  Future<void> _clear() async {
    final ok = await confirm(
      context,
      'Clear the speed test history?',
      action: 'Clear',
    );
    if (ok != true || !mounted) return;
    await writeSpeedTestHistory(widget.box, const []);
    if (mounted) setState(() => _records = const []);
  }

  @override
  Widget build(BuildContext context) {
    // A sheet's own header and a shrink-wrapping list, like every other sheet
    // in the app: scrolling comes from Prism's sheet, not a Material
    // isScrollControlled flag. The foot clears bottomInset.
    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.fromLTRB(
        16,
        context.sectionsTopPadding,
        16,
        24 + context.bottomInset,
      ),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                context.tr('Speed test history'),
                style: AppTextStyle.title3.of(context, emphasized: true),
              ),
            ),
            if (_records.isNotEmpty)
              TextButton(
                onPressed: _clear,
                child: Text(context.tr('Clear')),
              ),
            IconButton(
              tooltip: context.tr('Close'),
              onPressed: () => Navigator.pop(context),
              icon: const GlyphIcon(AppGlyphs.close),
            ),
          ],
        ),
        if (_records.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: Text(
              context.tr('No speed tests yet'),
              style: context.listSubtitleStyle,
              textAlign: TextAlign.center,
            ),
          )
        else
          for (final (index, record) in _records.indexed) ...[
            if (index > 0) const SizedBox(height: 8),
            _HistoryItem(record: record),
          ],
      ],
    );
  }
}

class _HistoryItem extends StatelessWidget {
  const _HistoryItem({required this.record});
  final SpeedTestRecord record;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final when = DateTime.fromMillisecondsSinceEpoch(record.time);
    final stamp =
        '${when.year}-${_pad(when.month)}-${_pad(when.day)} '
        '${_pad(when.hour)}:${_pad(when.minute)}';
    final server = record.server;
    final place = [
      '${server['country'] ?? ''}'.trim(),
      '${server['city'] ?? ''}'.trim(),
      '${server['sponsor'] ?? ''}'.trim(),
    ].where((part) => part.isNotEmpty).join(' · ');
    return BoxPanel(
      onTap: () => _showDetails(context),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  record.failed
                      ? context.tr('Failed')
                      : '↓ ${speedRateText(record.download)}   ↑ ${speedRateText(record.upload)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.subheadline.of(
                    context,
                    emphasized: true,
                  ).copyWith(
                    color: record.failed ? scheme.error : scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    stamp,
                    if (place.isNotEmpty) place,
                    '${record.latency.round()} ms',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.caption1.of(context).copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          GlyphIcon(
            AppGlyphs.chevronForward,
            size: 16,
            color: scheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }

  Future<void> _showDetails(BuildContext context) async {
    final record = this.record;
    final rows = <(String, String)>[
      ('Provider', record.provider),
      ('Protocol', record.protocol.toUpperCase()),
      ('Delay', '${record.latency.round()} ms'),
      ('Jitter', '${record.jitter.round()} ms'),
      ('Download', speedRateText(record.download)),
      ('Upload', speedRateText(record.upload)),
      (
        'Loaded latency',
        speedLoadedText(record.downloadLatency, record.uploadLatency),
      ),
      ('RPM', '${record.rpm}'),
      ('Transferred', bytes(record.bytes)),
      if (record.exitIp.isNotEmpty) ('Exit IP', record.exitIp),
      if (record.route.isNotEmpty)
        (
          'Route',
          [
            for (final item in (record.route['chains'] as List? ?? const []))
              '$item',
          ].join(' › '),
        ),
      if (record.error.isNotEmpty) ('Error', record.error),
    ];
    await showAppDialog<void>(
      context,
      child: Builder(
        builder: (dialogContext) => AlertDialog(
          title: dialogContext.tr('Speed test result'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(dialogContext.tr('Close')),
            ),
          ],
          child: SizedBox(
            width: 340,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (label, value) in rows)
                    if (value.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 120,
                              child: Text(
                                dialogContext.tr(label),
                                style: dialogContext.listCaptionStyle,
                              ),
                            ),
                            Expanded(
                              child: Text(
                                value,
                                style: dialogContext.listSubtitleStyle,
                              ),
                            ),
                          ],
                        ),
                      ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _pad(int value) => value.toString().padLeft(2, '0');
}

/// Bobs the gauge while a run is connecting, as Bettbox's intro sweep does.
double speedTestSweepOf(Animation<double> animation) => animation.value;

/// Kept for the page's own use: the maximum a gauge can show before it pegs.
double speedTestGaugeCeiling() => math.max(1, speedGaugeMarks.last);
