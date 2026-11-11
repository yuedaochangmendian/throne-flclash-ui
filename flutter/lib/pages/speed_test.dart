import 'dart:async';
import 'dart:math' as math;

import '../widgets.dart';
import '../components/speed_gauge.dart';
import '../components/speed_outbound_card.dart';
import '../components/speed_test_settings.dart';
import '../core/throne_kernel.dart';
import '../services/speed_test_history.dart';

/// The kernel's speed test, laid out the way Bettbox's screen lays it out: the
/// outbound card, then the gauge with the start button and the phase steps, the
/// throughput curves, the result tiles, and the credit line.
///
/// Everything measured comes from the kernel (`core/mobile/speedtest.go`):
/// `start` returns at once and this page polls `query` while the test runs, so
/// the numbers are the core's own samples rather than a UI reconstruction.
class SpeedTestPage extends StatefulWidget {
  const SpeedTestPage({
    super.key,
    this.outbound,
    this.download = true,
    this.upload = true,
  });

  /// The outbound the run measures through; null keeps the stored choice (and
  /// the box's default outbound when none was stored).
  final String? outbound;

  /// Which directions the run measures. The node card's submenu narrows one;
  /// the screen's own start button asks for both.
  final bool download;
  final bool upload;

  @override
  State<SpeedTestPage> createState() => _SpeedTestPageState();
}

/// The providers the kernel knows, in the order the picker lists them.
const _providers = <(String, String)>[
  ('apple', 'Apple'),
  ('cloudflare', 'Cloudflare'),
  ('speedtest', 'Speedtest'),
];

/// The transports, in the order the picker lists them.
const _protocols = <(String, String)>[
  ('h1', 'HTTP/1.1'),
  ('h2', 'HTTP/2'),
  ('h3', 'HTTP/3'),
];

class _SpeedTestPageState extends State<SpeedTestPage>
    with SingleTickerProviderStateMixin {
  SpeedTestSettings _settings = const SpeedTestSettings();
  String _outbound = '';
  List<String> _outbounds = const [];
  bool _coreRunning = false;
  bool _savedRecord = false;

  Json _state = const {};
  bool _running = false;
  bool _starting = false;
  String? _error;
  Timer? _poll;
  StreamSubscription<Map<String, dynamic>>? _pushSub;
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _pushSub?.cancel();
    _spin.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final box = context.box;
    final stored = box.preferences;
    setState(() {
      _settings = SpeedTestSettings.fromJson(stored);
      _outbound = widget.outbound ?? stored['speedTestOutbound']?.toString() ?? '';
      _coreRunning = box.running;
    });
    try {
      final outbounds = await box.speedTestOutbounds();
      if (mounted) setState(() => _outbounds = outbounds);
    } catch (error) {
      if (mounted) setState(() => _error = BoxController.describe(error));
    }
  }

  void _persist() {
    context.box.setPreferences({
      ..._settings.toPreferences(),
      'speedTestOutbound': _outbound,
    });
  }

  Map<String, dynamic> _params() => {
    ..._settings.toJson(),
    'outbound': _outbound,
    // Only sent when narrowed: the kernel treats an absent flag as "run it".
    if (!widget.download) 'testDownload': false,
    if (!widget.upload) 'testUpload': false,
  };

  Future<void> _start() async {
    if (_starting || _running) return;
    setState(() {
      _starting = true;
      _error = null;
      _savedRecord = false;
    });
    _spin.repeat();
    try {
      final started = await context.box.speedTestStart(_params());
      if (!mounted) return;
      if (!started) {
        setState(() {
          _starting = false;
          _error = context.tr('A speed test is already running');
        });
        _spin.stop();
        return;
      }
      setState(() {
        _starting = false;
        _running = true;
      });
      _pollSession();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = BoxController.describe(error);
      });
      _spin.stop();
    }
  }

  /// Follows the run. Under the FFI driver the kernel pushes a frame every
  /// 200 ms (ADR 0002 phase 3a), so this subscribes instead of polling; with the
  /// service-owned core there is no push channel and the 250 ms poll stays.
  void _pollSession() {
    _poll?.cancel();
    _poll = null;
    _pushSub?.cancel();
    _pushSub = null;
    final kernel = context.box.kernel.ffiMode ? ThroneKernel.ensure() : null;
    if (kernel != null) {
      _applyFrame(kernel.lastSpeedTestState, running: true);
      _pushSub = kernel.speedTestStates.listen(
        (frame) => _applyFrame(frame, running: false),
        onError: _failSession,
      );
      return;
    }
    _poll = Timer.periodic(const Duration(milliseconds: 250), (_) async {
      if (!mounted) return;
      try {
        final snapshot = await context.box.speedTestQuery();
        if (!mounted) return;
        final running = snapshot['running'] == true;
        setState(() {
          _state = json(snapshot['state']);
          _running = running;
        });
        if (!running) _finishSession();
      } catch (error) {
        _failSession(error);
      }
    });
  }

  /// Applies one pushed frame. The kernel's own `phase` says whether the run is
  /// still going, so `running` only seeds the first frame.
  void _applyFrame(Map<String, dynamic> frame, {required bool running}) {
    if (!mounted || frame.isEmpty) return;
    final phase = '${frame['phase'] ?? ''}';
    final done = phase == 'done' || '${frame['error'] ?? ''}'.isNotEmpty;
    setState(() {
      _state = frame;
      _running = done ? false : (_running || running || phase.isNotEmpty);
    });
    if (done) _finishSession();
  }

  /// Stops following and records the run once.
  void _finishSession() {
    _poll?.cancel();
    _poll = null;
    _pushSub?.cancel();
    _pushSub = null;
    _spin.stop();
    if (!mounted) return;
    setState(() => _running = false);
    // A finished run is a record. Cancelled ones are not: a stopped test
    // measured nothing worth keeping, and Bettbox's history has no entry for it.
    final verdict = '${_state['error'] ?? ''}';
    if (!_savedRecord && verdict != 'cancelled') {
      _savedRecord = true;
      _recordRun();
    }
  }

  void _failSession(Object error) {
    _poll?.cancel();
    _poll = null;
    _pushSub?.cancel();
    _pushSub = null;
    _spin.stop();
    if (!mounted) return;
    setState(() {
      _running = false;
      _error = BoxController.describe(error);
    });
  }

  /// Appends the finished run to the stored history.
  Future<void> _recordRun() async {
    final box = context.box;
    try {
      await appendSpeedTestRecord(
        SpeedTestRecord.fromState(
          _state,
          time: DateTime.now().millisecondsSinceEpoch,
          proxy: _outbound,
        ),
        read: () => readSpeedTestHistory(box),
        write: (records) => writeSpeedTestHistory(box, records),
      );
    } catch (error) {
      // A history write is not worth failing the screen over.
      box.report(error);
    }
  }

  Future<void> _cancel() async {
    await context.box.speedTestCancel();
    _poll?.cancel();
    _poll = null;
    _pushSub?.cancel();
    _pushSub = null;
    _spin.stop();
    if (mounted) setState(() => _running = false);
  }

  Future<void> _openSettings() async {
    final saved = await showSpeedTestSettings(context, _settings);
    if (saved == null || !mounted) return;
    setState(() => _settings = saved);
    _persist();
  }

  Future<void> _openHistory() async {
    await showSpeedTestHistory(context, box: context.box);
    if (mounted) setState(() {});
  }

  Future<void> _pickOutbound() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(context.tr('Outbound')),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, ''),
            child: Text(context.tr('The selected outbound')),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'DIRECT'),
            child: Text(context.tr('Direct')),
          ),
          for (final tag in _outbounds)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, tag),
              child: Text(tag),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _outbound = picked);
    _persist();
  }

  /// The phase the gauge and the step row read, from the kernel's `phase`.
  String? get _phase {
    final phase = _state['phase']?.toString() ?? '';
    if (phase.isEmpty) return null;
    return phase;
  }

  bool get _finished =>
      !_running &&
      _state.isNotEmpty &&
      (_phase == 'done' || (_state['error']?.toString() ?? '').isNotEmpty);

  double get _gaugeValue {
    final phase = _phase;
    if (phase == 'download' || phase == 'upload') {
      return (_state['speed'] as num? ?? 0).toDouble();
    }
    if (phase == 'done') return (_state['download'] as num? ?? 0).toDouble();
    return 0;
  }

  bool get _hasValue =>
      _phase == 'download' || _phase == 'upload' || _phase == 'done';

  /// One of the kernel's curve series (byte/s per sample), as the chart wants.
  List<double> _curve(String key) => [
    for (final value in _state[key] as List? ?? const [])
      (value as num).toDouble(),
  ];

  bool get _connecting => _starting || (_running && !_hasValue);

  /// A run needs the core up: the tester dials through the instance's own
  /// outbound, so with the VPN stopped there is nothing to measure through.
  bool get _serviceRunning => context.box.running;

  /// The stored value's label. A preference written by another build (or a
  /// restored backup) may name a provider this one does not run; the kernel
  /// coerces it to the default, so the row shows the raw value rather than
  /// throwing inside build.
  String get _providerLabel => _providers
      .firstWhere(
        (p) => p.$1 == _settings.provider,
        orElse: () => (_settings.provider, _settings.provider),
      )
      .$2;

  String get _protocolLabel => _protocols
      .firstWhere(
        (p) => p.$1 == _settings.protocol,
        orElse: () => (_settings.protocol, _settings.protocol),
      )
      .$2;

  /// The gauge's caption: what the run is doing, in one word.
  String get _readoutLabel {
    if (_connecting) return context.tr('Connecting');
    final phase = _phase;
    return switch (phase) {
      null => context.tr('Ready'),
      'done' => context.tr('Complete'),
      'upload' => context.tr('Upload'),
      'download' => context.tr('Download'),
      _ => context.tr('Ready'),
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final error = _state['error']?.toString() ?? _error ?? '';
    final isUpload = _phase == 'upload';
    final gaugeColor = isUpload ? scheme.tertiary : scheme.primary;
    final errorText = error.isEmpty
        ? null
        : switch (error) {
            'cancelled' => context.tr('Cancelled'),
            // `blocked` now means one thing only: the provider answered with a
            // status that refuses the request (a 4xx upload, a non-200
            // download, a trace without an exit IP). "The endpoint is blocked"
            // read as "your network is being censored" and sent users after a
            // firewall that did not exist whenever a provider simply timed out;
            // those runs report `timeout`/`unavailable` now.
            'blocked' => context.tr('The test endpoint refused the request'),
            'rejected' => context.tr('The selected outbound rejects traffic'),
            'timeout' => context.tr('The test timed out'),
            'unavailable' => context.tr('The test endpoint is unavailable'),
            _ => error,
          };
    return Scaffold(
      title: context.tr('Speed test'),
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.clock,
          tooltip: context.tr('Speed test history'),
          onPressed: _openHistory,
        ),
        IconButtonData(
          glyph: AppGlyphs.settings,
          tooltip: context.tr('Speed test settings'),
          onPressed: _running ? null : _openSettings,
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
          // The outbound card, in Bettbox's three-row shape: the node the run
          // dialled, the route that sent it there, and the provider's server.
          SpeedOutboundCard(
            rows: SpeedOutboundRows.of(
              _state,
              coreRunning: _coreRunning,
              pinnedOutbound: _outbound,
              unavailable: context.tr('Core stopped'),
            ),
            coreRunning: _coreRunning,
            onTap: _running ? null : _pickOutbound,
          ),
          if (_state['provider']?.toString() case final String actual
              when actual.isNotEmpty && actual != _settings.provider)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${context.tr('Provider')}: '
                '${_providers.firstWhere((p) => p.$1 == actual, orElse: () => (actual, actual)).$2}'
                '${_state['providerFallback'] == true ? ' · ${context.tr('Fell back')}' : ''}',
                style: context.listCaptionStyle,
              ),
            ),
          const SizedBox(height: 16),
          // The gauge and its neighbours, as Bettbox stacks them narrow.
          BoxPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PanelTitle('Speed test', AppGlyphs.speed),
                const SizedBox(height: 8),
                Center(
                  child: Column(
                    children: [
                      SpeedGauge(
                        size: math.min(
                          MediaQuery.sizeOf(context).width - 96,
                          300,
                        ),
                        fraction: _hasValue ? _gaugeValue : 0,
                        color: gaugeColor,
                        accentColor: isUpload ? scheme.primary : scheme.tertiary,
                        spin: _connecting ? _spin.value : null,
                        showNeedle: _hasValue || _connecting,
                      ),
                      const SizedBox(height: 4),
                      _GaugeReadout(
                        label: _readoutLabel,
                        value: _hasValue
                            ? speedValueText(_gaugeValue)
                            : '—',
                        unit: _hasValue ? speedUnitText(_gaugeValue) : '',
                        color: gaugeColor,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                SpeedPhaseSteps(phase: _phase),
                const SizedBox(height: 14),
                Center(
                  child: TonalButton(
                    size: TonalButtonSize.bar,
                    glyph: _running ? AppGlyphs.close : AppGlyphs.bolt,
                    label: context.tr(
                      _running
                          ? 'Stop'
                          : _finished
                          ? 'Test again'
                          : 'Start',
                    ),
                    onPressed: _starting
                        ? null
                        : _running
                        ? _cancel
                        : _serviceRunning
                        ? _start
                        : null,
                  ),
                ),
                if (!_serviceRunning && !_running) ...[
                  const SizedBox(height: 12),
                  Text(
                    context.tr(
                      'Start the VPN first: the test measures through the running core.',
                    ),
                    textAlign: TextAlign.center,
                    style: context.listCaptionStyle,
                  ),
                ],
                if (errorText != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    errorText,
                    textAlign: TextAlign.center,
                    style: context.listCaptionStyle.copyWith(
                      color: scheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          // The curves, kept after the run so the run can be re-read.
          BoxPanel(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    _Legend(
                      label: context.tr('Download'),
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 12),
                    _Legend(label: context.tr('Upload'), color: scheme.tertiary),
                  ],
                ),
                const SizedBox(height: 8),
                SpeedCurves(
                  download: _curve('downloadCurve'),
                  upload: _curve('uploadCurve'),
                  height: 120,
                  revision: _curve('downloadCurve').length +
                      _curve('uploadCurve').length,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _ResultTiles(state: _state),
          const SizedBox(height: 16),
          // One row summarising the run, opening the full dialog. The dialog
          // owns every knob Bettbox's does, so the page does not repeat them.
          generateSection(
            title: context.tr('Test settings'),
            items: [
              ListItem(
                leading: const GlyphIcon(AppGlyphs.settings),
                title: Text(context.tr('Run settings')),
                subtitle: Text(
                  [
                    _providerLabel,
                    _protocolLabel,
                    '${_settings.duration}s',
                    '${_settings.streams} ${context.tr('connections')}',
                    if (_settings.hasServer) context.tr('Pinned server'),
                  ].join(' · '),
                ),
                onTap: _running ? null : _openSettings,
              ),
            ],
            footer: context.tr(
              'The test measures through the running core, so start the VPN first.',
            ),
          ),
        ],
      ),
    );
  }

}

/// The gauge's centre: the phase label, the big number and its unit.
class _GaugeReadout extends StatelessWidget {
  const _GaugeReadout({
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
  });

  final String label;
  final String value;
  final String unit;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: Text(
          label,
          key: ValueKey(label),
          style: context.listCaptionStyle,
        ),
      ),
      Text(
        value,
        style: AppTextStyle.title1
            .of(context, emphasized: true)
            .toTabular
            .copyWith(letterSpacing: -.5, height: 1.05),
      ),
      if (unit.isNotEmpty)
        Text(unit, style: context.listCaptionStyle.copyWith(color: color)),
    ],
  );
}

/// The server line: the provider's own answer once a test ran, the picked
/// speedtest.net server before that.

class _Legend extends StatelessWidget {
  const _Legend({required this.label, required this.color});
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

/// The measured figures: delay/jitter, throughput, loaded latency and RPM.
class _ResultTiles extends StatelessWidget {
  const _ResultTiles({required this.state});
  final Json state;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    double value(String key) => (state[key] as num? ?? 0).toDouble();
    final idle = value('latency');
    final jitter = value('jitter');
    final loaded = speedLoadedText(
      value('downloadLatency'),
      value('uploadLatency'),
    );
    final tiles = <(String, String, Color)>[
      (
        context.tr('Delay'),
        idle > 0 ? '${idle.round()} ms' : '—',
        scheme.primary,
      ),
      (
        context.tr('Jitter'),
        jitter > 0 ? '${jitter.round()} ms' : '—',
        scheme.onSurfaceVariant,
      ),
      (
        context.tr('Download'),
        value('download') > 0 ? speedRateText(value('download')) : '—',
        scheme.primary,
      ),
      (
        context.tr('Upload'),
        value('upload') > 0 ? speedRateText(value('upload')) : '—',
        scheme.tertiary,
      ),
      (
        context.tr('Loaded latency'),
        loaded.isEmpty ? '—' : loaded,
        scheme.onSurfaceVariant,
      ),
      (
        context.tr('RPM'),
        value('rpm') > 0 ? '${value('rpm').round()}' : '—',
        scheme.onSurfaceVariant,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 480 ? 3 : 2;
        return Column(
          children: [
            for (var start = 0; start < tiles.length; start += columns) ...[
              if (start > 0) const SizedBox(height: 10),
              _TileRow(tiles: tiles, start: start, columns: columns),
            ],
          ],
        );
      },
    );
  }
}

/// One row of the result grid: [columns] slots starting at [start], with the
/// trailing slots padded to nothing when the tiles run out.
class _TileRow extends StatelessWidget {
  const _TileRow({
    required this.tiles,
    required this.start,
    required this.columns,
  });

  final List<(String, String, Color)> tiles;
  final int start;
  final int columns;

  @override
  Widget build(BuildContext context) => Row(
    spacing: 10,
    children: [
      for (var slot = 0; slot < columns; slot++)
        Expanded(child: _slot(start + slot)),
    ],
  );

  Widget _slot(int index) {
    if (index >= tiles.length) return const SizedBox.shrink();
    final (title, value, color) = tiles[index];
    return _ResultTile(title: title, value: value, color: color);
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({
    required this.title,
    required this.value,
    required this.color,
  });
  final String title;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => BoxPanel(
    padding: const EdgeInsets.all(14),
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
              .toTabular
              .copyWith(color: color),
        ),
      ],
    ),
  );
}
