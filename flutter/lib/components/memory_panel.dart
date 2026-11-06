import 'dart:math' as math;
import '../widgets.dart';
import 'data_subscription.dart';

/// FlClash's memory summary with same-process accounting from libbox.
class MemoryPanel extends StatelessWidget {
  const MemoryPanel({super.key});
  @override Widget build(BuildContext context) => BoxDataSubscription(data: BoxData.memory,
    child: BoxPanel(onTap: () => openForm(context, const MemoryDetails()), child: Column(
    crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const PanelTitle('Memory', AppGlyphs.memory, trailing: GlyphIcon(AppGlyphs.chevronForward, size: 18)),
      const SizedBox(height: 12), MemorySummary(snapshot: context.watchBox(BoxAspect.memory).memory),
    ])));
}

class MemorySummary extends StatelessWidget {
  const MemorySummary({super.key, required this.snapshot});
  final Json snapshot;
  @override Widget build(BuildContext context) {
    final color = context.colorScheme;
    final remote = snapshot['remote'] == true;
    final rss = snapshot['rss'] as num? ?? 0;
    final app = snapshot['app'] as num? ?? 0;
    final core = snapshot['core'] as num? ?? 0;
    // A running core whose API is off reports no figure of its own, and zero would claim it holds
    // nothing. The process total already includes it, so the bar shows one segment and the legend
    // says the share is unknown.
    final coreUnknown = !remote && snapshot['running'] == true && core == 0;
    // The headline is the process: that is what "memory" means to the reader, and it is what the
    // RSS row below says. `app` is that process minus the core, so the two parts still add up to
    // it; `total` is the ART heap ceiling, not device RAM, and would read as "256 MB" on a panel
    // whose parts add up to 68 MB.
    final total = bytes(remote ? (snapshot['total'] as num? ?? 0) : (rss > 0 ? rss : app + core)).split(' ');
    final parts = <(String, num, Color)>[
      if (!remote) ('App', app, color.primary),
      ('Core', core, Color.alphaBlend(color.primary.withValues(alpha: .45), SurfaceLevel.card.colorOf(color))),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text.rich(TextSpan(children: [
        TextSpan(text: snapshot.isEmpty ? '—' : total.first, style: AppTextStyle.title1.of(context, emphasized: true).toTabular),
        if (snapshot.isNotEmpty) TextSpan(text: ' ${total.last}', style: AppTextStyle.footnote.of(context).copyWith(color: color.onSurfaceVariant)),
      ]), maxLines: 1),
      const SizedBox(height: 14), MemoryBar(parts: parts), const SizedBox(height: 10),
      Wrap(spacing: 16, runSpacing: 4, children: [for (final (index, part) in parts.indexed) Row(mainAxisSize: MainAxisSize.min, spacing: 6, children: [
        DecoratedBox(decoration: ShapeDecoration(color: part.$3, shape: AppShape.circle), child: const SizedBox.square(dimension: 8)),
        Text(context.tr(part.$1), style: context.listCaptionStyle),
        Text(snapshot.isEmpty || (coreUnknown && index == parts.length - 1) ? '—' : bytes(part.$2), style: AppTextStyle.footnote.of(context, emphasized: true).toTabular),
      ])]),
    ]);
  }
}

class MemoryBar extends StatelessWidget {
  const MemoryBar({super.key, required this.parts});
  final List<(String, num, Color)> parts;
  @override Widget build(BuildContext context) {
    final total = parts.fold<num>(0, (sum, part) => sum + math.max(0, part.$2));
    final positive = parts.where((part) => part.$2 > 0).toList();
    return ClipRSuperellipse(borderRadius: AppRadius.full, child: SizedBox(height: 8, child: total == 0
      ? ColoredBox(color: SurfaceLevel.inset.colorOf(context.colorScheme))
      : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final (index, part) in positive.indexed) ...[
          if (index > 0) const SizedBox(width: 2),
          TweenAnimationBuilder<double>(tween: Tween(end: (part.$2 * 100 / total).roundToDouble()), duration: context.motionDuration(commonDuration), curve: Easing.standard,
            builder: (_, percent, child) => Expanded(flex: math.max(1, (percent * 100).round()), child: child!), child: ColoredBox(color: part.$3)),
        ]])));
  }
}

class MemoryDetails extends StatefulWidget {
  const MemoryDetails({super.key});
  @override State<MemoryDetails> createState() => _MemoryDetailsState();
}
class _MemoryDetailsState extends State<MemoryDetails> {
  bool _releasing = false;
  Future<void> _release() async {
    setState(() => _releasing = true);
    final box = context.box;
    if (await box.dashboardReleaseMemory() && mounted) showAppBanner(context, context.tr('Memory released'));
    if (mounted) setState(() => _releasing = false);
  }
  @override Widget build(BuildContext context) {
    final memory = context.watchBox(BoxAspect.memory).memory;
    final remote = memory['remote'] == true;
    final core = memory['core'] as num? ?? 0;
    final coreUnknown = !remote && memory['running'] == true && core == 0;
    return BoxDataSubscription(data: BoxData.memory, child: BoxPage(title: 'Memory', loading: _releasing, actions: [
      if (!remote && memory['running'] == true) IconButtonData(glyph: AppGlyphs.broom,
        tooltip: context.tr('Release memory'), onPressed: _releasing ? null : _release),
    ], children: [
      const SizedBox(height: 8), Text(context.tr('Total memory'), style: AppTextStyle.headline.of(context)), const SizedBox(height: 4),
      MemorySummary(snapshot: memory), const SizedBox(height: 12),
      Text(context.tr(remote ? 'Memory reported by the remote core. Detailed accounting is unavailable.'
        : coreUnknown ? "The core API is off, so the core's own share is not reported; it stays inside the process figure."
        : 'App and core share one process. Core runtime memory is separated from process RSS, not added twice.'), style: context.listCaptionStyle),
      if (!remote) generateSection(title: context.tr('App'), items: [
        ListItem(title: Text(context.tr('Process RSS')), trailing: Text(bytes(memory['rss'] as num? ?? 0))),
        ListItem(title: Text(context.tr('Heap in use')), trailing: Text(bytes(memory['heapInuse'] as num? ?? 0))),
        ListItem(title: Text(context.tr('Retained idle heap')), trailing: Text(bytes(memory['heapIdle'] as num? ?? 0))),
      ]),
      generateSection(title: context.tr('Core'), items: [
        if (!remote && memory['running'] != true) ListItem(title: Text(context.tr('Not running'))),
        ListItem(title: Text(context.tr('Core memory')), trailing: Text(coreUnknown ? '—' : bytes(core))),
      ]),
    ]));
  }
}
