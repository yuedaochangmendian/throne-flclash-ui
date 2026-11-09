import 'dart:math' as math;
import 'package:material_ui/material_ui.dart' as material;
import 'package:flutter/services.dart';
import '../widgets.dart';
import '../pages/protocol_form.dart';
import '../pages/node_json_page.dart';
import '../pages/test_panel.dart';

// Metrics and card presentation from FlClash proxies/common.dart and card.dart.

/// FlClash's delay-test phases: a queued node waits its turn with a clock, a
/// running one animates the spinner, and an idle one shows its last delay.
enum ProxyTestPhase { idle, queued, running }

class ProxyCardMetrics {
  ProxyCardMetrics.of(BuildContext context, Json preferences)
      : compact = preferences['proxyCardSize'] == 'Compact' ||
            preferences['proxyCardSize'] == null && preferences['proxyLayout'] == 'Compact',
        loose = preferences['proxyCardSize'] == 'Loose',
        measure = MeasureScope.of(context);

  final bool compact, loose;
  final Measure measure;
  double get nameHeight => measure.textHeight(AppTextStyle.subheadline) * (compact ? 1 : 2);
  double get detailHeight => math.max(measure.textHeight(AppTextStyle.footnote), 20);
  double get delayHeight => math.max(measure.textHeight(AppTextStyle.caption2), 18);
  double get extent => 28 + nameHeight + detailHeight + (loose ? delayHeight + 6 : 0);
  double get rowExtent => extent + 8;
}

int proxyColumns(double width, Json preferences) {
  final standard = (width / 250).ceil().clamp(2, 8);
  final density = preferences['proxyDensity'] ?? 'Standard';
  return (standard + (density == 'Tight' ? 1 : density == 'Loose' ? -1 : 0)).clamp(1, 8);
}

class ProxyNodeCard extends StatelessWidget {
  const ProxyNodeCard({super.key, required this.group, required this.node,
    required this.phase, required this.onSelect, required this.onTest});
  final Json group, node;
  final ProxyTestPhase phase;
  final VoidCallback onSelect, onTest;

  /// FlClash keeps a square glyph area while a test is underway or before any
  /// delay has been sampled; a finished test reads as a tappable figure. FadeBox
  /// cross-fades between them, so a whole screen of tests moves as one motion.
  Widget _delayArea(BuildContext context, ProxyCardMetrics metrics, String delayText, Color delayColor, bool tested) {
    final h = metrics.delayHeight;
    final label = context.tr('Test latency');
    if (phase != ProxyTestPhase.idle || !tested) {
      return SizedBox(
        key: ValueKey('glyph:$phase'),
        height: h, width: math.max(h, 20),
        child: Semantics(button: true, label: label, child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: phase == ProxyTestPhase.idle ? onTest : null,
          child: switch (phase) {
            ProxyTestPhase.running => ActivityIndicator(key: const ValueKey('proxy-test-running'), size: h),
            ProxyTestPhase.queued => GlyphIcon(AppGlyphs.clock, size: h,
              color: context.colorScheme.onSurfaceVariant.withValues(alpha: .38)),
            ProxyTestPhase.idle => GlyphIcon(AppGlyphs.bolt, size: h),
          },
        )),
      );
    }
    return Semantics(
      key: const ValueKey('delay'),
      button: true, label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque, onTap: onTest,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: 48, minHeight: h),
          child: Align(alignment: Alignment.centerRight, widthFactor: 1, heightFactor: 1,
            child: Text(delayText, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: AppTextStyle.caption2.of(context, emphasized: true).copyWith(color: delayColor))),
        ),
      ),
    );
  }

  Future<String> _link(BuildContext context, {bool json = false}) async =>
      (await context.box.profileNodeLink(group['tag'], node['tag'], json)).toString();

  /// A speed session over this node alone (download, upload or both); the panel that opens shows
  /// its live curve and the finished ranking, since a card only carries latency.
  Future<void> _speedTest(BuildContext context, int speedMode) async {
    final box = context.box;
    try {
      final started = await box.groupTestSessionStart({
        'kind': 2, 'profileIds': [node['id']], 'speedMode': speedMode,
      });
      if (!context.mounted) return;
      if (started == false) {
        showAppBanner(context, context.tr('A test is already running'));
        return;
      }
      await openPage(context, TestPanelPage(speedOnly: true,
        profileIds: [(node['id'] as num?)?.toInt() ?? 0], initialSpeedMode: speedMode));
    } catch (error) { box.report(error); }
  }

  @override Widget build(BuildContext context) {
    final metrics = ProxyCardMetrics.of(context, context.box.preferences);
    final selected = group['selected'] == node['tag'];
    final delay = (node['delay'] as num?)?.toInt() ?? 0;
    final tested = (node['testedAt'] as num? ?? 0) > 0;
    final delayText = delay > 0 ? '$delay ms' : tested ? context.tr('Unreachable') : '—';
    final delayColor = !tested ? context.colorScheme.onSurfaceVariant : delay <= 0
        ? context.colorScheme.error : delay < 300 ? context.colorScheme.success : context.colorScheme.warning;
    return ContextMenuRegion(
      key: ValueKey((group['tag'], node['tag'])),
      menuItems: [
        if (group['selectable'] == true)
          PopupMenuItem(glyph: AppGlyphs.checkCircle, label: context.tr('Select'), checked: selected,
            onPressed: onSelect),
        PopupMenuItem(glyph: AppGlyphs.bolt, label: context.tr('Test latency'),
          onPressed: phase == ProxyTestPhase.idle ? onTest : null),
        // The download/upload speed test lives here, as a submenu of its modes; a session tests
        // one node at a time and the panel reports the result.
        PopupMenuItem(glyph: AppGlyphs.speed, label: context.tr('Speed test'), subItems: [
          PopupMenuItem(glyph: AppGlyphs.dataUsage, label: context.tr('Download and upload'),
            onPressed: () => _speedTest(context, 0)),
          PopupMenuItem(glyph: AppGlyphs.arrowDown, label: context.tr('Download'),
            onPressed: () => _speedTest(context, 1)),
          PopupMenuItem(glyph: AppGlyphs.arrowUp, label: context.tr('Upload'),
            onPressed: () => _speedTest(context, 2)),
        ]),
        PopupMenuItem(glyph: AppGlyphs.copy, label: context.tr('Copy link'), onPressed: () async {
          final box = context.box;
          try {
            final link = await _link(context);
            await Clipboard.setData(ClipboardData(text: link));
            if (context.mounted) showAppBanner(context, context.tr('Copied'));
          } catch (error) { box.report(error); }
        }),
        PopupMenuItem(glyph: AppGlyphs.qrCode, label: context.tr('QR code'), onPressed: () async {
          final box = context.box;
          try {
            final link = await _link(context);
            if (context.mounted) {
              openForm(context, BoxPage(title: 'QR code', children: [
              Center(child: QrCodeView(data: link)),
            ]));
            }
          } catch (error) { box.report(error); }
        }),
        PopupMenuItem(glyph: AppGlyphs.upload, label: context.tr('Share'), onPressed: () async {
          final box = context.box;
          try { await box.shareText(await _link(context)); }
          catch (error) { box.report(error); }
        }),
        PopupMenuItem(glyph: AppGlyphs.edit, label: context.tr('Edit'), onPressed: () async {
          if (node['isSelector'] == true) {
            await openPage(context, AutoSelectorPage(id: (node['id'] as num?)?.toInt() ?? 0));
            return;
          }
          // Throne's node Edit opens the typed editor; the JSON document is the secondary entry.
          await openForm(context, ProtocolFormPage(id: (node['id'] as num?)?.toInt() ?? 0));
        }),
        PopupMenuItem(glyph: AppGlyphs.sliders, label: context.tr('Node tuning'), onPressed: () async {
          await openPage(context, NodeTuningPage(id: (node['id'] as num?)?.toInt() ?? 0));
        }),
        PopupMenuItem(glyph: AppGlyphs.code, label: context.tr('Edit as JSON'),
          onPressed: () => openForm(context, NodeJsonPage(id: (node['id'] as num?)?.toInt() ?? 0))),
        PopupMenuItem(glyph: AppGlyphs.delete, label: context.tr('Delete'), danger: true, onPressed: () async {
          final box = context.box;
          try {
            final confirmed = await showDialog<bool>(context: context, builder: (context) => material.AlertDialog(
              title: Text(context.tr('Delete node?')),
              content: Text(node['tag'].toString()),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.tr('Cancel'))),
                TextButton(onPressed: () => Navigator.pop(context, true), child: Text(context.tr('Delete'))),
              ],
            ));
            if (confirmed == true) await box.profileNodeDelete(node['id']);
          } catch (error) { box.report(error); }
        }),
        PopupMenuItem(glyph: AppGlyphs.info, label: context.tr('Details'), onPressed: () => openForm(context, BoxPage(title: 'Details', children: [
          DetailRows({'Name': node['tag'], 'Protocol': node['type'], 'Latency': delayText, 'Proxy groups': group['tag']}),
        ]))),
      ],
      child: Card(
        radius: AppCorner.lg, enterActionsOnRight: true, isSelected: selected,
        // Both actions outlive the service: a selection is stored for the next start and a test runs
        // over its own instance of the profile, so a stopped VPN must not turn the card inert.
        onPressed: group['selectable'] == true ? onSelect : null,
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Column(
          mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: SizedBox(height: metrics.nameHeight, child: EmojiText(node['tag'].toString(),
                maxLines: metrics.compact ? 1 : 2, overflow: TextOverflow.ellipsis, style: AppTextStyle.subheadline.of(context)))),
              if (selected) const Padding(padding: EdgeInsetsDirectional.only(start: 4), child: SelectionBadge()),
            ]),
            const SizedBox(height: 8),
            if (metrics.loose) SizedBox(height: metrics.detailHeight, child: Text(node['type'].toString(), maxLines: 1,
              overflow: TextOverflow.ellipsis, style: AppTextStyle.footnote.of(context).copyWith(color: context.colorScheme.onSurface.opacity80))),
            if (metrics.loose) const SizedBox(height: 6),
            SizedBox(height: metrics.loose ? metrics.delayHeight : metrics.detailHeight, child: Row(children: [
              if (!metrics.loose) Expanded(child: TooltipText(text: Text(node['type'].toString(), maxLines: 1,
                overflow: TextOverflow.ellipsis, style: AppTextStyle.footnote.of(context).copyWith(color: context.colorScheme.onSurface.opacity80)))),
              if (!metrics.loose) const SizedBox(width: 4),
              Flexible(child: FadeBox(
                alignment: metrics.loose ? Alignment.centerLeft : Alignment.centerRight,
                child: _delayArea(context, metrics, delayText, delayColor, tested),
              )),
            ])),
          ],
        )),
      ),
    );
  }
}