import 'package:flutter/widgets.dart' show Curves;

/// Shared easing for proxy tab-strip and list motion. Kept out of the vendored
/// Prism UI `ui/metrics.dart` so the drift gate sees only the reviewed patch
/// set; the indicator, tab label and scroll-to-selected use the same curve.
const proxyMotionCurve = Curves.easeOutCubic;
