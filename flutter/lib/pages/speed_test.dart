import 'dart:math' as math;

import '../widgets.dart';
import '../components/data_subscription.dart';
import '../components/form.dart';
import 'test_panel.dart';

/// Bettbox's speed-test screen rebuilt with Flrone's surfaces. It owns one
/// Throne speed session, keeps its download/upload curves on screen after the
/// run, and leaves every unrelated batch/IP control in [TestPanelPage].
class SpeedTestPage extends StatefulWidget {
  const SpeedTestPage({
    super.key,
    this.profileIds = const [],
    this.initialSpeedMode,
  });
  final List<int> profileIds;
  final int? initialSpeedMode;
  @override
  State<SpeedTestPage> createState() => _SpeedTestPageState();
}

/// Log scale for the gauge: 1 kbps at the start of the sweep, 1 Gbps at the
/// end. The kernel reports raw bytes-per-second, so a linear dial would spend
/// almost all of its travel in the sub-Mbps range.
double _gaugeFraction(double bps) {
  if (bps <= 1e3) return 0;
  return (math.log(bps.clamp(1e3, 1e9)) / math.ln10 - 3) / 6;
}

/// The kernel's wire `stage` values (SpeedTestSnapshot.STAGE_*) mapped onto the
/// five Bettbox phase steps. `null` means "no test has started".
int? _phaseStep(String stage, bool running, bool empty) {
  if (empty && !running) return null;
  switch (stage) {
    case 'latency':
      return 1;
    case 'download':
      return 2;
    case 'upload':
      return 3;
    case 'complete':
    case 'cancelled':
    case 'error':
      return 4;
    case 'discovery':
    case '':
      return 0;
    default:
      return running ? 0 : 4;
  }
}

class _SpeedTestPageState extends State<SpeedTestPage> {
  late int _mode;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialSpeedMode ?? -1;
  }

  int get _effectiveMode {
    if (_mode >= 0) return _mode;
    final stored = context.box.settings['speedTestMode'];
    return stored is num ? stored.toInt() : 0;
  }

  int get _groupId {
    final selected = context.box.selectedProfileId;
    if (selected > 0) return selected;
    final profiles = context.box.profiles;
    return profiles.isEmpty
        ? 0
        : ((profiles.first['id'] as num?)?.toInt() ?? 0);
  }

  bool get _canStart => widget.profileIds.isNotEmpty || _groupId > 0;

  Future<void> _start() async {
    if (_starting || !_canStart) return;
    setState(() => _starting = true);
    try {
      final arguments = <String, dynamic>{
        'kind': 2,
        'speedMode': _effectiveMode,
      };
      if (widget.profileIds.isNotEmpty) {
        arguments['profileIds'] = widget.profileIds;
      } else {
        arguments['groupId'] = _groupId;
      }
      await context.box.groupTestSessionStartChecked(arguments);
    } catch (error) {
      if (mounted) context.box.report(error);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final box = context.watchBox(BoxAspect.testSession);
    final session = box.testSession;
    final speed = json(session['speed']);
    final running = session['running'] == true;
    final samples = (speed['samples'] as List? ?? const [])
        .whereType<List>()
        .toList();
    final download = <double>[
      0,
      for (final sample in samples)
        sample[2] == true ? 0 : (sample[1] as num).toDouble(),
    ];
    final upload = <double>[
      0,
      for (final sample in samples)
        sample[2] == true ? (sample[1] as num).toDouble() : 0,
    ];
    final peak = math.max(
      1.0,
      samples.fold<double>(
        1,
        (value, sample) => math.max(value, (sample[1] as num).toDouble()),
      ),
    );
    final colors = context.colorScheme;
    final server = speed['server']?.toString().trim() ?? '';
    final serverCountry = speed['serverCountry']?.toString().trim() ?? '';
    final serverLabel = server.isEmpty
        ? context.tr('Automatic')
        : serverCountry.isEmpty
        ? server
        : '$server ($serverCountry)';
    final pingMs = (speed['pingMs'] as num?)?.toInt() ?? 0;
    final stage = speed['stage']?.toString() ?? '';
    final phase = _phaseStep(stage, running, speed.isEmpty);
    final gaugeValue =
        ((speed['dlBps'] as num? ?? 0) + (speed['ulBps'] as num? ?? 0))
            .toDouble();
    String value(num bps) {
      final rate = bps.toDouble();
      if (rate >= 1e9) return '${(rate / 1e9).toStringAsFixed(2)} Gbps';
      if (rate >= 1e6) return '${(rate / 1e6).toStringAsFixed(2)} Mbps';
      if (rate >= 1e3) return '${(rate / 1e3).toStringAsFixed(2)} kbps';
      return '${rate.toStringAsFixed(0)} bps';
    }

    return BoxDataSubscription(
      data: BoxData.testSession,
      child: Scaffold(
        title: context.tr('Speed test'),
        iconActions: [
          IconButtonData(
            glyph: AppGlyphs.clock,
            tooltip: context.tr('History'),
            onPressed: () => openForm(
              context,
              const TestPanelPage(speedOnly: true, initialSpeedMode: 0),
            ),
          ),
        ],
        body: ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            context.sectionsTopPadding,
            16,
            32 + context.bottomInset,
          ),
          children: [
            BoxPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PanelTitle('Outbound node', AppGlyphs.proxies),
                  const SizedBox(height: 12),
                  Text(
                    speed['name']?.toString() ?? context.tr('Automatic'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyle.title3.of(context, emphasized: true),
                  ),
                  const SizedBox(height: 8),
                  Text(serverLabel, style: context.listCaptionStyle),
                ],
              ),
            ),
            const SizedBox(height: 16),
            BoxPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PanelTitle('Speed test', AppGlyphs.speed),
                  const SizedBox(height: 16),
                  AspectRatio(
                    aspectRatio: 1,
                    child: CustomPaint(
                      painter: _GaugePainter(
                        color: colors.onSurfaceVariant.withValues(alpha: .18),
                        activeColor: colors.primary,
                        fraction: _gaugeFraction(gaugeValue),
                      ),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              context.tr(
                                running
                                    ? 'Testing now'
                                    : speed.isEmpty
                                    ? 'Ready'
                                    : 'Done',
                              ),
                              style: AppTextStyle.title3.of(
                                context,
                                emphasized: true,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              value(gaugeValue),
                              style: AppTextStyle.title1
                                  .of(context, emphasized: true)
                                  .toTabular,
                            ),
                            Text(
                              context.tr('Total'),
                              style: context.listCaptionStyle,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    spacing: 12,
                    children: [
                      _Legend(context.tr('Download'), colors.primary),
                      _Legend(context.tr('Upload'), colors.tertiary),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _PhaseSteps(phase: phase, color: colors.primary),
                  const SizedBox(height: 16),
                  TonalButton(
                    size: TonalButtonSize.bar,
                    glyph: running ? AppGlyphs.close : AppGlyphs.bolt,
                    label: context.tr(running ? 'Stop' : 'Start speed test'),
                    onPressed: _starting
                        ? null
                        : running
                        ? () => box.groupTestSessionStop()
                        : _canStart
                        ? _start
                        : null,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 180,
              child: BoxPanel(
                padding: const EdgeInsets.all(12),
                child: Stack(
                  children: [
                    LineChart(
                      key: const ValueKey('speed-download-curve'),
                      values: [for (final value in download) value / peak],
                      revision: samples.length,
                      capacity: 600,
                      minScale: 1,
                      baselineRatio: 1,
                      color: colors.primary,
                    ),
                    LineChart(
                      key: const ValueKey('speed-upload-curve'),
                      values: [for (final value in upload) value / peak],
                      revision: samples.length,
                      capacity: 600,
                      minScale: 1,
                      baselineRatio: 1,
                      color: colors.tertiary,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              spacing: 10,
              children: [
                Expanded(
                  child: _SpeedMetric(
                    title: context.tr('Download'),
                    value: value(speed['dlBps'] as num? ?? 0),
                    color: colors.primary,
                  ),
                ),
                Expanded(
                  child: _SpeedMetric(
                    title: context.tr('Upload'),
                    value: value(speed['ulBps'] as num? ?? 0),
                    color: colors.tertiary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              spacing: 10,
              children: [
                Expanded(
                  child: _SpeedMetric(
                    title: context.tr('Delay'),
                    value: pingMs > 0 ? '$pingMs ms' : '—',
                    color: colors.primary,
                  ),
                ),
                Expanded(
                  child: _SpeedMetric(
                    title: context.tr('Jitter'),
                    value: '—',
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ListItem(
              title: Text(context.tr('Speed test mode')),
              trailing: Text(
                context.tr(speedTestModeName(_effectiveMode)),
                style: context.listValueStyle,
              ),
              onTap: () async {
                final picked = await showDialog<int>(
                  context: context,
                  builder: (context) => SimpleDialog(
                    title: Text(context.tr('Speed test mode')),
                    children: [
                      for (final value in speedTestModes)
                        SimpleDialogOption(
                          onPressed: () => Navigator.pop(context, value),
                          child: Text(context.tr(speedTestModeName(value))),
                        ),
                    ],
                  ),
                );
                if (picked != null && mounted) setState(() => _mode = picked);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend(this.label, this.color);
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: 4,
    children: [
      DecoratedBox(
        decoration: ShapeDecoration(color: color, shape: AppShape.circle),
        child: const SizedBox.square(dimension: 8),
      ),
      Text(label, style: context.listCaptionStyle),
    ],
  );
}

class _SpeedMetric extends StatelessWidget {
  const _SpeedMetric({
    required this.title,
    required this.value,
    required this.color,
  });
  final String title, value;
  final Color color;
  @override
  Widget build(BuildContext context) => BoxPanel(
    padding: const EdgeInsets.all(14),
    child: Row(
      children: [
        GlyphIcon(
          title == context.tr('Upload')
              ? AppGlyphs.arrowUp
              : AppGlyphs.arrowDown,
          color: color,
          size: 18,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.listCaptionStyle,
              ),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyle.subheadline
                    .of(context, emphasized: true)
                    .toTabular,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Bettbox's dynamic dial: a 270-degree log-scale track with ticks, a filled
/// progress arc and a needle that follows the live throughput. The scale ticks
/// are 1 kbps / 10 kbps / 100 kbps / 1 / 10 / 100 / 1000 Mbps.
class _GaugePainter extends CustomPainter {
  const _GaugePainter({
    required this.color,
    required this.activeColor,
    required this.fraction,
  });
  final Color color;
  final Color activeColor;
  final double fraction;

  static const _sweep = math.pi * 1.5;
  static const _start = math.pi * .75;
  static const _ticks = <String>['1k', '10k', '100k', '1M', '10M', '100M', '1G'];

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final track = rect.deflate(26);
    final center = track.center;
    final radius = track.shortestSide / 2;
    final base = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(track, _start, _sweep, false, base);
    if (fraction > 0) {
      final active = Paint()
        ..color = activeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(track, _start, _sweep * fraction.clamp(0.0, 1.0), false, active);
    }
    // Tick marks and labels around the dial.
    final tickPaint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    for (var i = 0; i < _ticks.length; i++) {
      final angle = _start + _sweep * (i / (_ticks.length - 1));
      final dir = Offset(math.cos(angle), math.sin(angle));
      final outer = center + dir * radius;
      final inner = center + dir * (radius - 10);
      canvas.drawLine(inner, outer, tickPaint);
    }
    // Needle rides the same scale as the progress arc.
    final needleAngle = _start + _sweep * fraction.clamp(0.0, 1.0);
    final needleDir = Offset(math.cos(needleAngle), math.sin(needleAngle));
    final needle = Paint()
      ..color = activeColor
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(center, center + needleDir * (radius - 18), needle);
    canvas.drawCircle(center, 6, Paint()..color = activeColor);
  }

  @override
  bool shouldRepaint(covariant _GaugePainter old) =>
      old.color != color ||
      old.activeColor != activeColor ||
      old.fraction != fraction;
}

/// Five-step phase indicator (connecting → latency → download → upload → done)
/// driven by the kernel's `speed['stage']`. Steps before the current one are
/// filled, the current one is highlighted, and the rest stay muted.
class _PhaseSteps extends StatelessWidget {
  const _PhaseSteps({required this.phase, required this.color});
  final int? phase;
  final Color color;

  static const _labels = <String>[
    'Connecting',
    'Latency',
    'Download',
    'Upload',
    'Complete',
  ];

  @override
  Widget build(BuildContext context) {
    final muted = context.colorScheme.onSurfaceVariant.withValues(alpha: .35);
    final current = phase == null
        ? ''
        : context.tr(_labels[phase!.clamp(0, _labels.length - 1)]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            for (var i = 0; i < _labels.length; i++) ...[
              if (i > 0)
                Expanded(
                  child: Container(
                    height: 2,
                    color: phase != null && i <= phase! ? color : muted,
                  ),
                ),
              _PhaseDot(
                color: phase == null || i > phase!
                    ? muted
                    : color,
                active: phase != null && i == phase,
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Text(
          current.isEmpty ? context.tr('Ready') : current,
          textAlign: TextAlign.center,
          style: context.listCaptionStyle,
        ),
      ],
    );
  }
}

class _PhaseDot extends StatelessWidget {
  const _PhaseDot({required this.color, required this.active});
  final Color color;
  final bool active;

  @override
  Widget build(BuildContext context) => Container(
    width: active ? 12 : 8,
    height: active ? 12 : 8,
    decoration: ShapeDecoration(color: color, shape: AppShape.circle),
  );
}
