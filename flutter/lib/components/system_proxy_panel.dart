// Adapted from FlClash v0.9.2 network_takeover.dart (VpnCard) and card.dart (GPL-3.0).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_new_shapes/material_new_shapes.dart';
import '../providers/box_providers.dart';
import '../widgets.dart';
import 'shape_badge.dart';
import 'system_proxy_glyph.dart';

class SystemProxyPanel extends ConsumerWidget {
  const SystemProxyPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colorScheme;
    final enabled = ref.watch(dashboardStatusProvider).systemProxy;
    final title = context.tr('Network takeover');
    void change(bool value) => ref.read(boxControllerProvider).systemProxySet(value);
    return Semantics(
      container: true,
      label: title,
      child: BoxPanel(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        clipBehavior: Clip.none,
        onTap: () => change(!enabled),
        child: Row(spacing: 14, children: [
          ShapeBadge(
            shape: enabled ? MaterialShapes.cookie6Sided : MaterialShapes.circle,
            color: enabled ? colors.primary : SurfaceLevel.block.colorOf(colors),
            size: 48,
            child: GlyphIcon(systemProxyGlyph, size: 22,
              color: enabled ? colors.onPrimary : colors.onSurfaceVariant),
          ),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: AppTextStyle.callout.of(context, emphasized: true)),
            Text(context.tr(enabled ? 'Enabled' : 'Disabled'),
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: AppTextStyle.footnote.of(context).copyWith(color: colors.onSurfaceVariant)),
          ])),
          SizedBox(
            width: Switch.trackWidth,
            height: Switch.trackHeight,
            child: OverflowBox(
              maxWidth: double.infinity,
              maxHeight: double.infinity,
              child: Switch(value: enabled, semanticLabel: title, onChanged: change),
            ),
          ),
        ]),
      ),
    );
  }
}
