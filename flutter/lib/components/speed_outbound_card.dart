// The speed test's outbound card, in Bettbox's shape.
//
// Bettbox prints three rows: the exit node the run dialled, the route that sent
// the test's connection there, and the provider's own server. The rows come from
// the kernel's `route` object (this project's sing-box kernel has no mihomo
// tracker, so the chain is the outbound-group path rather than a live
// connection's tracker info), and from the state's `server`/`exitIp` fields.
//
// Tapping the card opens the outbound picker; the disclosure chevron only
// appears while a core is running, because that is the only time a pin can be
// honoured.

import 'dart:math' as math;

import '../widgets.dart';

/// The three rows the card prints, in Bettbox's order.
class SpeedOutboundRows {
  const SpeedOutboundRows({
    required this.node,
    required this.route,
    required this.server,
    this.error = false,
  });

  final String node, route, server;

  /// True when the run failed before the provider resolved a server.
  final bool error;

  /// Derives the rows from one kernel snapshot.
  ///
  /// `running` is whether a core is up at all: with the core stopped there is no
  /// node to name and the rows say so rather than inventing "DIRECT".
  factory SpeedOutboundRows.of(
    Map<String, Object?> state, {
    required bool coreRunning,
    required String pinnedOutbound,
    String unavailable = '',
  }) {
    final route = state['route'];
    final routeMap = route is Map ? Map<String, Object?>.from(route) : const <String, Object?>{};
    final chains = [
      for (final item in (routeMap['chains'] as List? ?? const []))
        '$item'.trim(),
    ].where((item) => item.isNotEmpty).toList();
    final direct = routeMap['direct'] == true;

    String node;
    if (!coreRunning) {
      node = '—';
    } else if (direct) {
      node = 'DIRECT';
    } else if (pinnedOutbound.isNotEmpty) {
      node = pinnedOutbound;
    } else if (chains.isNotEmpty) {
      node = chains.last;
    } else {
      final label = '${state['outbound'] ?? ''}'.trim();
      node = label.isEmpty ? '—' : label;
    }

    String routeText;
    if (!coreRunning) {
      routeText = unavailable;
    } else if (direct) {
      routeText = 'DIRECT';
    } else if (chains.length > 1) {
      routeText = chains.join(' › ');
    } else if (chains.length == 1) {
      routeText = chains.first;
    } else {
      routeText = pinnedOutbound.isEmpty ? unavailable : pinnedOutbound;
    }

    final server = state['server'];
    final serverMap = server is Map ? Map<String, Object?>.from(server) : const <String, Object?>{};
    final parts = <String>[
      for (final key in ['country', 'city', 'colo', 'sponsor', 'host'])
        if ('${serverMap[key] ?? ''}'.trim().isNotEmpty) '${serverMap[key]}'.trim(),
    ];
    final exitIp = '${state['exitIp'] ?? ''}'.trim();
    final serverText = parts.isEmpty
        ? (exitIp.isEmpty ? '—' : exitIp)
        : (exitIp.isEmpty ? parts.join(' · ') : '${parts.join(' · ')} · $exitIp');
    final failed = '${state['error'] ?? ''}'.isNotEmpty;

    return SpeedOutboundRows(
      node: node,
      route: routeText,
      server: failed && serverText == '—' ? (unavailable) : serverText,
      error: failed,
    );
  }
}

/// The card itself: three label/value rows on a tappable surface.
class SpeedOutboundCard extends StatelessWidget {
  const SpeedOutboundCard({
    super.key,
    required this.rows,
    this.onTap,
    this.coreRunning = false,
  });

  final SpeedOutboundRows rows;
  final VoidCallback? onTap;
  final bool coreRunning;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final labelStyle = AppTextStyle.caption1.of(context).copyWith(
      color: scheme.onSurfaceVariant,
    );
    final valueStyle = AppTextStyle.subheadline.of(context);
    final entries = <(Glyph, String, String, bool)>[
      (AppGlyphs.proxies, context.tr('Exit node'), rows.node, true),
      (AppGlyphs.rules, context.tr('Route'), rows.route, false),
      (AppGlyphs.dns, context.tr('Server'), rows.server, false),
    ];
    return BoxPanel(
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, (glyph, label, value, primary))
                    in entries.indexed) ...[
                  if (index > 0) const SizedBox(height: 6),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      GlyphIcon(
                        glyph,
                        size: 14,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      SizedBox(
                        width: 64,
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: labelStyle,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: valueStyle.copyWith(
                            fontWeight: primary ? FontWeight.w600 : null,
                            color: primary
                                ? scheme.onSurface
                                : index == 2 && rows.error
                                ? scheme.error
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (coreRunning)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 6),
              child: GlyphIcon(
                AppGlyphs.chevronDown,
                size: 18,
                color: onTap == null
                    ? scheme.outlineVariant
                    : scheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

/// The outbound picker: the box's default first, then DIRECT, then every tag.
///
/// Bettbox's picker groups nodes under their groups; this one lists the box's
/// own outbound tags because that is what the kernel's pin accepts.
Future<String?> pickSpeedTestOutbound(
  BuildContext context, {
  required List<String> outbounds,
  required String current,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) {
      final scheme = context.colorScheme;
      final options = <(String, String)>[
        ('', context.tr('Follow the box default')),
        ('DIRECT', 'DIRECT'),
        for (final tag in outbounds) (tag, tag),
      ];
      return SimpleDialog(
        title: Text(context.tr('Outbound')),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (value, label) in options)
                    SimpleDialogOption(
                      onPressed: () => Navigator.pop(context, value),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (value == current)
                            GlyphIcon(
                              AppGlyphs.checkCircle,
                              size: 18,
                              color: scheme.primary,
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// The hero area's gauge frame, sized the way Bettbox scales it: the gauge fills
/// the narrow layout's width up to 300 and shrinks on short screens.
double speedTestHeroScale({
  required double width,
  double? availableHeight,
}) {
  final byWidth = (width / 300).clamp(0.62, 1.0);
  if (availableHeight == null) return byWidth;
  final byHeight = (availableHeight / 560).clamp(0.62, 1.0);
  return math.min(byWidth, byHeight);
}
