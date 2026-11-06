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
    final reported = snapshot['core'] as num? ?? 0;
    // The core reports the heap the Go runtime has mapped, not what the process has resident: the
    // two are different quantities, and the reported one can exceed RSS — 319 MB on a 286 MB
    // process. The process is the whole, so it is split into what can be accounted for: the app's
    // heap, the core's share capped at what is left, and the rest (native allocations, graphics,
    // shared pages). Every figure then adds up to the headline.
    final room = math.max<num>(0, rss - app);
    final core = reported > 0 ? math.min(reported, room) : 0;
    final other = math.max<num>(0, room - core);
    // A running core that reports nothing says so rather than claiming to hold nothing.
    final coreUnknown = !remote && snapshot['running'] == true && reported == 0;
    final total = bytes(remote ? (snapshot['total'] as num? ?? 0) : (rss > 0 ? rss : app + core + other)).split(' ');
    final parts = <(String, num, Color)>[
      if (!remote) ('App', app, color.primary),
      ('Core', core, Color.alphaBlend(color.primary.withValues(alpha: .45), SurfaceLevel.card.colorOf(color))),
      if (!remote && other > 0) ('Other', other, color.onSurfaceVariant.withValues(alpha: .35)),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text.rich(TextSpan(children: [
        TextSpan(text: snapshot.isEmpty ? '—' : total.first, style: AppTextStyle.title1.of(context, emphasized: true).toTabular),
        if (snapshot.isNotEmpty) TextSpan(text: ' ${total.last}', style: AppTextStyle.footnote.of(context).copyWith(color: color.onSurfaceVariant)),
      ]), maxLines: 1),
      const SizedBox(height: 14), MemoryBar(parts: parts), const SizedBox(height: 10),
      Wrap(spacing: 16, runSpacing: 4, children: [for (final part in parts) Row(mainAxisSize: MainAxisSize.min, spacing: 6, children: [
        DecoratedBox(decoration: ShapeDecoration(color: part.$3, shape: AppShape.circle), child: const SizedBox.square(dimension: 8)),
        Text(context.tr(part.$1), style: context.listCaptionStyle),
        Text(snapshot.isEmpty || (coreUnknown && part.$1 == 'Core') ? '—' : bytes(part.$2), style: AppTextStyle.footnote.of(context, emphasized: true).toTabular),
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
    final rss = memory['rss'] as num? ?? 0;
    final app = memory['app'] as num? ?? 0;
    final reported = memory['core'] as num? ?? 0;
    // Same accounting as the card: the core's figure is capped at what the process holds beyond the
    // app's heap, because the Go runtime reports mapped memory and that can exceed resident memory.
    final core = reported > 0 ? math.min(reported, math.max<num>(0, rss - app)) : 0;
    final coreUnknown = !remote && memory['running'] == true && reported == 0;
    return BoxDataSubscription(data: BoxData.memory, child: BoxPage(title: 'Memory', loading: _releasing, actions: [
      if (!remote && memory['running'] == true) IconButtonData(glyph: AppGlyphs.broom,
        tooltip: context.tr('Release memory'), onPressed: _releasing ? null : _release),
    ], children: [
      const SizedBox(height: 8), Text(context.tr('Total memory'), style: AppTextStyle.headline.of(context)), const SizedBox(height: 4),
      MemorySummary(snapshot: memory), const SizedBox(height: 12),
      Text(context.tr(remote ? 'Memory reported by the remote core. Detailed accounting is unavailable.'
        : coreUnknown ? "The core API is off, so the core's own share is not reported; it stays inside the process figure."
        : "The total is the process's resident memory: the app's heap, the core's share, and the rest — native allocations, graphics and shared pages."), style: context.listCaptionStyle),
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
