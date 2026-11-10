import 'dart:math' as math;

import '../widgets.dart';
import '../components/data_subscription.dart';
import '../components/form.dart';
import 'test_panel.dart';

/// Bettbox's speed-test screen rebuilt with Flrone's surfaces. It owns one
/// Throne speed session, keeps its download/upload curves on screen after the
/// run, and leaves every unrelated batch/IP control in [TestPanelPage].
class SpeedTestPage extends StatefulWidget {
  const SpeedTestPage({super.key, this.profileIds = const []});
  final List<int> profileIds;
  @override State<SpeedTestPage> createState() => _SpeedTestPageState();
}

class _SpeedTestPageState extends State<SpeedTestPage> {
  int _mode = 0;
  bool _starting = false;

  int get _effectiveMode {
    final stored = context.box.settings['speedTestMode'];
    return _mode >= 0 ? _mode : stored is num ? stored.toInt() : 0;
  }

  List<int> get _targets {
    final selected = context.box.selectedProfileId;
    final ids = widget.profileIds.isNotEmpty ? widget.profileIds : [
      for (final group in context.box.groups)
        for (final node in rows(group['items']))
          if ((node['id'] as num?)?.toInt() == selected) (node['id'] as num).toInt(),
    ];
    if (ids.isNotEmpty) return ids;
    for (final group in context.box.groups) {
      final nodes = rows(group['items']);
      if (nodes.isNotEmpty && nodes.first['id'] is num) return [(nodes.first['id'] as num).toInt()];
    }
    return const <int>[];
  }

  Future<void> _start() async {
    if (_starting || _targets.isEmpty) return;
    setState(() => _starting = true);
    try {
      await context.box.groupTestSessionStartChecked({
        'kind': 2, 'profileIds': _targets, 'speedMode': _effectiveMode,
      });
    } catch (error) {
      if (mounted) context.box.report(error);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override Widget build(BuildContext context) {
    final box = context.watchBox(BoxAspect.testSession);
    final session = box.testSession;
    final speed = json(session['speed']);
    final running = session['running'] == true;
    final samples = (speed['samples'] as List? ?? const []).whereType<List>().toList();
    final download = <double>[0, for (final sample in samples) sample[2] == true ? 0 : (sample[1] as num).toDouble()];
    final upload = <double>[0, for (final sample in samples) sample[2] == true ? (sample[1] as num).toDouble() : 0];
    final peak = math.max(1.0, samples.fold<double>(1, (value, sample) => math.max(value, (sample[1] as num).toDouble())));
    final colors = context.colorScheme;
    String value(num bps) => bps >= 1e6 ? ' Mbps' : ' kbps';
    return BoxDataSubscription(data: BoxData.testSession, child: Scaffold(
      title: context.tr('Speed test'),
      iconActions: [
        IconButtonData(glyph: AppGlyphs.clock, tooltip: context.tr('History'),
          onPressed: () => openForm(context, const TestPanelPage(speedOnly: true, initialSpeedMode: 0))),
      ],
      body: ListView(padding: EdgeInsets.fromLTRB(16, context.sectionsTopPadding, 16, 32 + context.bottomInset), children: [
        BoxPanel(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PanelTitle('Outbound node', AppGlyphs.proxies),
          const SizedBox(height: 12),
          Text(speed['name']?.toString() ?? context.tr('Automatic'), maxLines: 1, overflow: TextOverflow.ellipsis,
            style: AppTextStyle.title3.of(context, emphasized: true)),
          const SizedBox(height: 8),
          Text(': ',
            style: context.listCaptionStyle),
        ])),
        const SizedBox(height: 16),
        BoxPanel(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PanelTitle('Speed test', AppGlyphs.speed),
          const SizedBox(height: 16),
          AspectRatio(aspectRatio: 1, child: CustomPaint(painter: _GaugePainter(color: colors.onSurfaceVariant.withValues(alpha: .18)),
            child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(context.tr(running ? 'Testing now' : speed.isEmpty ? 'Ready' : 'Done'),
                style: AppTextStyle.title3.of(context, emphasized: true)),
              const SizedBox(height: 8),
              Text(value((speed['dlBps'] as num? ?? 0) + (speed['ulBps'] as num? ?? 0)),
                style: AppTextStyle.title1.of(context, emphasized: true).toTabular),
              Text('Mbps', style: context.listCaptionStyle),
            ])))),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.center, spacing: 12, children: [
            _Legend(context.tr('Download'), colors.primary),
            _Legend(context.tr('Upload'), colors.tertiary),
          ]),
          const SizedBox(height: 16),
          TonalButton(size: TonalButtonSize.bar, glyph: running ? AppGlyphs.close : AppGlyphs.bolt,
            label: context.tr(running ? 'Stop' : 'Start speed test'),
            onPressed: _starting ? null : running ? () => box.groupTestSessionStop() : _start),
        ])),
        const SizedBox(height: 16),
        SizedBox(height: 180, child: BoxPanel(padding: const EdgeInsets.all(12), child: Stack(children: [
          LineChart(key: const ValueKey('speed-download-curve'), values: [for (final value in download) value / peak],
            revision: samples.length, capacity: 600, minScale: 1, baselineRatio: 1, color: colors.primary),
          LineChart(key: const ValueKey('speed-upload-curve'), values: [for (final value in upload) value / peak],
            revision: samples.length, capacity: 600, minScale: 1, baselineRatio: 1, color: colors.tertiary),
        ]))),
        const SizedBox(height: 16),
        Row(spacing: 10, children: [
          Expanded(child: _SpeedMetric(title: context.tr('Download'), value: value(speed['dlBps'] as num? ?? 0), color: colors.primary)),
          Expanded(child: _SpeedMetric(title: context.tr('Upload'), value: value(speed['ulBps'] as num? ?? 0), color: colors.tertiary)),
        ]),
        const SizedBox(height: 10),
        Row(spacing: 10, children: [
          Expanded(child: _SpeedMetric(title: context.tr('Delay'), value: ' ms', color: colors.primary)),
          Expanded(child: _SpeedMetric(title: context.tr('Jitter'), value: '—', color: colors.onSurfaceVariant)),
        ]),
        const SizedBox(height: 16),
        ListItem(title: Text(context.tr('Speed test mode')), trailing: Text(context.tr(speedTestModeName(_effectiveMode)), style: context.listValueStyle),
          onTap: () async {
            final picked = await showDialog<int>(context: context, builder: (context) => SimpleDialog(
              title: Text(context.tr('Speed test mode')), children: [
                for (final value in speedTestModes) SimpleDialogOption(onPressed: () => Navigator.pop(context, value),
                  child: Text(context.tr(speedTestModeName(value)))),
              ]));
            if (picked != null && mounted) setState(() => _mode = picked);
          }),
      ]),
    ));
  }
}

class _Legend extends StatelessWidget {
  const _Legend(this.label, this.color);
  final String label;
  final Color color;
  @override Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, spacing: 4, children: [
    DecoratedBox(decoration: ShapeDecoration(color: color, shape: AppShape.circle), child: const SizedBox.square(dimension: 8)),
    Text(label, style: context.listCaptionStyle),
  ]);
}

class _SpeedMetric extends StatelessWidget {
  const _SpeedMetric({required this.title, required this.value, required this.color});
  final String title, value;
  final Color color;
  @override Widget build(BuildContext context) => BoxPanel(padding: const EdgeInsets.all(14), child: Row(children: [
    GlyphIcon(title == context.tr('Upload') ? AppGlyphs.arrowUp : AppGlyphs.arrowDown, color: color, size: 18),
    const SizedBox(width: 8),
    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.listCaptionStyle),
      Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTextStyle.subheadline.of(context, emphasized: true).toTabular),
    ])),
  ]));
}

class _GaugePainter extends CustomPainter {
  const _GaugePainter({required this.color});
  final Color color;
  @override void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 18..strokeCap = StrokeCap.round;
    canvas.drawArc(rect.deflate(24), math.pi * .75, math.pi * 1.5, false, paint);
  }
  @override bool shouldRepaint(covariant _GaugePainter old) => old.color != color;
}