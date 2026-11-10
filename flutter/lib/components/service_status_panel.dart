import '../widgets.dart';
import '../common/routed_ip_probe.dart';
import 'dashboard_chip.dart';
import 'status_panel.dart' show EgressDetails;

/// Bettbox-style exit-IP detection card built on Throne's routed egress probe.
/// It shows the current outbound address, its region and IP quality, with a
/// refresh menu. The data comes from the same `RoutedIpProbe.egress()` and
/// `box.ipQualities` that the always-visible Status panel uses, so no second
/// data source or capability is needed.
class ServiceStatusPanel extends StatefulWidget {
  const ServiceStatusPanel({super.key});
  @override
  State<ServiceStatusPanel> createState() => _ServiceStatusPanelState();
}

class _ServiceStatusPanelState extends State<ServiceStatusPanel> {
  Json? _egress;
  String? _error;
  bool _checking = false;
  int _generation = 0;
  RoutedIpProbe? _probe;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _check();
    });
  }

  @override
  void dispose() {
    _generation++;
    _probe?.cancel();
    super.dispose();
  }

  Future<void> _check({bool force = false}) async {
    if (_checking || context.box.remote) return;
    final generation = ++_generation;
    setState(() {
      _checking = true;
      _error = null;
    });
    final probe = RoutedIpProbe(context.box);
    _probe?.cancel();
    _probe = probe;
    try {
      final result = await probe.egress(force: force);
      if (!mounted || generation != _generation) return;
      setState(() => _egress = result.isEmpty ? null : result);
      final ip = result['ip'] as String?;
      final direct = result['direct'] == true;
      if (ip == null || direct) return;
      try {
        final record = await context.box.ipQualities.lookup(
          probe,
          ip,
          refresh: force,
          onAnswer: (quality) {
            if (!mounted || generation != _generation) return;
            setState(() => result.addAll(quality.toDashboard(DateTime.now())));
          },
        );
        if (!mounted || generation != _generation) return;
        setState(() => result.addAll(record.quality.toDashboard(record.checkedAt)));
      } catch (error) {
        if (mounted && generation == _generation) {
          setState(() => result['qualityError'] = BoxController.describe(error));
        }
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _egress = null;
          _error = BoxController.describe(error);
        });
      }
    } finally {
      if (identical(_probe, probe)) _probe = null;
      await probe.close();
      if (mounted && generation == _generation) {
        setState(() => _checking = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _egress;
    final quality = info?['quality'] as String?;
    final tone = switch (quality) {
      'Good' => DashboardChipTone.ok,
      'Risky' => DashboardChipTone.warn,
      _ => DashboardChipTone.idle,
    };
    return BoxPanel(
      onTap: info == null ? (_checking ? null : () => _check(force: true)) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelTitle(
            'Exit detection',
            AppGlyphs.verified,
            trailing: _checking
                ? const ActivityIndicator(size: 16)
                : GestureDetector(
                    onTap: () => _check(force: true),
                    child: const GlyphIcon(AppGlyphs.refresh, size: 16),
                  ),
          ),
          const SizedBox(height: 12),
          if (info == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                context.tr(
                  _checking
                      ? 'Loading'
                      : _error != null
                      ? 'Check failed'
                      : 'Unreachable',
                ),
                style: context.listCaptionStyle,
              ),
            )
          else
            _EgressBody(info: info, qualityTone: tone),
        ],
      ),
    );
  }
}

class _EgressBody extends StatelessWidget {
  const _EgressBody({required this.info, required this.qualityTone});
  final Json info;
  final DashboardChipTone qualityTone;

  @override
  Widget build(BuildContext context) {
    final ip = info['ip']?.toString() ?? '';
    final country = info['country']?.toString() ?? '';
    final flag = _countryFlag(country);
    final location = [
      info['city'] as String?,
      info['countryName'] as String?,
      info['country'] as String?,
    ].whereType<String>().where((item) => item.isNotEmpty).join(' · ');
    final type = info['type'] as String?;
    final quality = info['quality'] as String?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => openForm(context, EgressDetails(info: info)),
          child: Row(
            children: [
              if (flag.isNotEmpty)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: Text(flag, style: AppTextStyle.title2.of(context)),
                ),
              Expanded(
                child: Text(
                  ip,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.title3
                      .of(context, emphasized: true)
                      .toTabular,
                ),
              ),
              const GlyphIcon(AppGlyphs.info, size: 16),
            ],
          ),
        ),
        if (location.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(location, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: context.listCaptionStyle),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (type != null)
              DashboardChip(label: context.tr(type)),
            if (quality != null)
              DashboardChip(
                label: '${context.tr('Quality')} ${context.tr(quality)}',
                tone: qualityTone,
                dot: true,
              ),
          ],
        ),
      ],
    );
  }
}

String _countryFlag(String code) {
  if (code.length != 2) return code;
  final first = code.codeUnitAt(0) - 0x41 + 0x1F1E6;
  final second = code.codeUnitAt(1) - 0x41 + 0x1F1E6;
  return String.fromCharCodes([first, second]);
}
