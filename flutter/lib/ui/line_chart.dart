import 'dart:math' as math;

import 'package:flutter/widgets.dart';

class LineChart extends StatefulWidget {
  const LineChart({
    super.key,
    required this.values,
    required this.revision,
    required this.capacity,
    required this.minScale,
    required this.color,
    required this.baselineRatio,
    this.secondaryValues,
    this.secondaryColor,
  }) : assert(capacity > 1),
       assert(minScale > 0);

  final List<double> values;

  /// Advances by one for each sample appended to [values]. Any other change,
  /// such as a clear, starts the chart over.
  final int revision;

  final int capacity;

  /// The least value the top stands for, so idle noise stays near the baseline.
  final double minScale;

  final Color color;

  /// A second line drawn against the same scale, used by the speed test's
  /// upload and download graph. Both lists are sampled in the same window.
  final List<double>? secondaryValues;
  final Color? secondaryColor;

  /// Where the zero line sits, as a share of the height from the top.
  final double baselineRatio;

  @override
  State<LineChart> createState() => _LineChartState();
}

class _LineChartState extends State<LineChart> {
  late _Series _series;
  _Series? _secondarySeries;

  @override
  void initState() {
    super.initState();
    _series = _Series.of(widget.values, _seriesLength);
    _secondarySeries = widget.secondaryValues == null
        ? null
        : _Series.of(widget.secondaryValues!, _seriesLength);
  }

  int get _seriesLength => widget.capacity + _Series.radius + 1;

  @override
  void didUpdateWidget(LineChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    final appended = widget.revision - oldWidget.revision;
    if (widget.capacity != oldWidget.capacity ||
        appended < 0 ||
        appended > widget.values.length ||
        (widget.secondaryValues != null &&
            (oldWidget.secondaryValues == null ||
                appended > widget.secondaryValues!.length))) {
      _series = _Series.of(widget.values, _seriesLength);
      _secondarySeries = widget.secondaryValues == null
          ? null
          : _Series.of(widget.secondaryValues!, _seriesLength);
    } else if (appended > 0) {
      _series = _series.append(
        widget.values.sublist(widget.values.length - appended),
      );
      if (_secondarySeries != null) {
        _secondarySeries = _secondarySeries!.append(
          widget.secondaryValues!.sublist(
            widget.secondaryValues!.length - appended,
          ),
        );
      }
    } else if (widget.secondaryValues == null || oldWidget.secondaryValues == null) {
      _secondarySeries = widget.secondaryValues == null
          ? null
          : _Series.of(widget.secondaryValues!, _seriesLength);
    }
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox.expand(
        child: CustomPaint(
          painter: _LineChartPainter(
            series: _series,
            capacity: widget.capacity,
            minScale: widget.minScale,
            color: widget.color,
            secondarySeries: _secondarySeries,
            secondaryColor: widget.secondaryColor,
            baselineRatio: widget.baselineRatio,
          ),
        ),
      ),
    );
  }
}

@immutable
class _Series {
  _Series._(this.values) : heights = _blur(values);

  factory _Series.of(List<double> window, int length) {
    final count = math.min(window.length, length);
    return _Series._(
      List.filled(length, 0.0)
        ..setAll(length - count, window.sublist(window.length - count)),
    );
  }

  static const _sigma = 1.5;
  static final radius = (_sigma * 2.5).ceil();
  static final _kernel = [
    for (var d = 0; d <= radius; d++) math.exp(-d * d / (2 * _sigma * _sigma)),
  ];

  final List<double> values;

  final List<double> heights;

  _Series append(List<double> samples) {
    final next = [...values, ...samples];
    return _Series._(next.sublist(next.length - values.length));
  }

  static List<double> _blur(List<double> values) {
    return [for (var i = 0; i < values.length; i++) _blurAt(values, i)];
  }

  static double _blurAt(List<double> values, int i) {
    var sum = 0.0;
    var weight = 0.0;
    final from = math.max(i - radius, 0);
    final to = math.min(i + radius, values.length - 1);
    for (var j = from; j <= to; j++) {
      final w = _kernel[(j - i).abs()];
      sum += w * values[j];
      weight += w;
    }
    return sum / weight;
  }

  /// Catmull-Rom slopes, clamped so no control point and no curve dips below 0.
  static List<double> slopesOf(List<double> values) {
    final last = values.length - 1;
    return [
      for (var i = 0; i <= last; i++)
        i == 0 || i == last
            ? 0.0
            : ((values[i + 1] - values[i - 1]) / 2).clamp(
                -3 * values[i],
                3 * values[i],
              ),
    ];
  }
}

class _LineChartPainter extends CustomPainter {
  _LineChartPainter({
    required this.series,
    required this.capacity,
    required this.minScale,
    required this.color,
    required this.baselineRatio,
    this.secondarySeries,
    this.secondaryColor,
  }) : _strokePaint = Paint()
         ..color = color
         ..strokeWidth = _strokeWidth
         ..strokeCap = StrokeCap.round
         ..strokeJoin = StrokeJoin.round
         ..style = PaintingStyle.stroke;

  static const _strokeWidth = 2.0;
  static const _fillOpacity = 0.14;

  final _Series series;
  final int capacity;
  final double minScale;
  final Color color;
  final _Series? secondarySeries;
  final Color? secondaryColor;
  final double baselineRatio;

  final Paint _strokePaint;

  @override
  void paint(Canvas canvas, Size size) {
    final top = math.max(
      minScale,
      [series, ?secondarySeries]
          .expand((item) => item.heights)
          .fold<double>(0, math.max),
    );
    _paintSeries(canvas, size, series, color, top);
    if (secondarySeries != null) {
      _paintSeries(canvas, size, secondarySeries!, secondaryColor ?? color, top);
    }
  }

  void _paintSeries(
    Canvas canvas,
    Size size,
    _Series series,
    Color color,
    double top,
  ) {
    final step = size.width / (capacity - 1);
    final baseline = size.height * baselineRatio;
    final heights = series.heights;
    final slopes = _Series.slopesOf(heights);
    final firstX = size.width - (heights.length - 1) * step;

    var x = firstX;
    var y = -heights[0];
    final curve = Path()..moveTo(x, y);
    for (var i = 1; i < heights.length; i++) {
      final nextX = x + step;
      final nextY = -heights[i];
      curve.cubicTo(
        x + step / 3,
        y - slopes[i - 1] / 3,
        nextX - step / 3,
        nextY + slopes[i] / 3,
        nextX,
        nextY,
      );
      x = nextX;
      y = nextY;
    }
    final yScale = (baseline - _strokeWidth) / top;
    final line = curve.transform(
      (Matrix4.identity()
            ..translateByDouble(0, baseline, 0, 1)
            ..scaleByDouble(1, yScale, 1, 1))
          .storage,
    );
    final area = Path.from(line)
      ..lineTo(x, size.height)
      ..lineTo(firstX, size.height)
      ..close();
    final fillPaint = Paint()
      ..color = color.withValues(alpha: color.a * _fillOpacity);
    canvas
      ..save()
      ..clipRect(Offset.zero & size)
      ..drawPath(area, fillPaint)
      ..drawPath(
        line,
        _strokePaint
          ..color = color,
      )
      ..restore();
  }

  @override
  bool shouldRepaint(_LineChartPainter oldDelegate) {
    return oldDelegate.series != series ||
        oldDelegate.capacity != capacity ||
        oldDelegate.minScale != minScale ||
        oldDelegate.color != color ||
        oldDelegate.secondarySeries != secondarySeries ||
        oldDelegate.secondaryColor != secondaryColor ||
        oldDelegate.baselineRatio != baselineRatio;
  }
}
