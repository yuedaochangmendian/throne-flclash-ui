import '../widgets.dart';
import '../common/routed_ip_probe.dart';

/// FlClash's service-status grid, adapted to Throne's routed HTTP probe. Four
/// lightweight endpoints stand in for its Core service checks; no second
/// service-check API or Riverpod provider is needed.
class ServiceStatusPanel extends StatefulWidget {
  const ServiceStatusPanel({super.key});
  @override
  State<ServiceStatusPanel> createState() => _ServiceStatusPanelState();
}

class _ServiceStatusPanelState extends State<ServiceStatusPanel> {
  static const _services = <(String, String, String)>[
    ('Google', 'https://www.google.com/generate_204', 'Google'),
    ('Cloudflare', 'https://www.cloudflare.com/cdn-cgi/trace', 'Cloudflare'),
    ('Apple', 'https://www.apple.com/library/test/success.html', 'Apple'),
    ('GitHub', 'https://api.github.com/', 'GitHub'),
  ];
  final _states = <String, _ServiceState?>{};
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

  Future<void> _check() async {
    if (_checking || context.box.remote) return;
    final generation = ++_generation;
    setState(() => _checking = true);
    final probe = RoutedIpProbe(context.box);
    _probe = probe;
    try {
      for (final (name, url, _) in _services) {
        if (!mounted || generation != _generation) break;
        final started = DateTime.now().millisecondsSinceEpoch;
        try {
          final response = await probe.get(url, const Duration(seconds: 5));
          final ok = response.status >= 200 && response.status < 300;
          if (mounted && generation == _generation) {
            setState(
              () => _states[name] = _ServiceState(
                ok,
                DateTime.now().millisecondsSinceEpoch - started,
              ),
            );
          }
        } catch (_) {
          if (mounted && generation == _generation) {
            setState(() => _states[name] = null);
          }
        }
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
  Widget build(BuildContext context) => BoxPanel(
    onTap: _checking ? null : _check,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PanelTitle(
          'Service status',
          AppGlyphs.verified,
          trailing: _checking
              ? const ActivityIndicator(size: 16)
              : const GlyphIcon(AppGlyphs.refresh, size: 16),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (name, _, _) in _services)
              _ServiceTile(
                name: name,
                state: _states[name],
                checking: _checking,
              ),
          ],
        ),
      ],
    ),
  );
}

class _ServiceState {
  const _ServiceState(this.available, this.delay);
  final bool available;
  final int delay;
}

class _ServiceTile extends StatelessWidget {
  const _ServiceTile({
    required this.name,
    required this.state,
    required this.checking,
  });
  final String name;
  final _ServiceState? state;
  final bool checking;
  @override
  Widget build(BuildContext context) {
    final color = state == null
        ? context.colorScheme.onSurfaceVariant
        : state!.available
        ? context.colorScheme.success
        : context.colorScheme.error;
    final label = state == null
        ? context.tr(checking ? 'Loading' : 'Check failed')
        : state!.available
        ? '${state!.delay} ms'
        : context.tr('Unreachable');
    return Container(
      width: 128,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: ShapeDecoration(
        color: SurfaceLevel.block.colorOf(context.colorScheme),
        shape: AppShape.all(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.listCaptionStyle,
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyle.footnote
                .of(context, emphasized: true)
                .copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
