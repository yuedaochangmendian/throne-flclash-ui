import 'package:flutter/widgets.dart';

/// The fonts FlClash bundles, declared in its `pubspec.yaml`.
enum FontFamily {
  jetBrainsMono('JetBrainsMono');

  final String value;

  const FontFamily(this.value);
}

extension FontFamilyTextStyle on TextStyle {
  TextStyle get toJetBrainsMono =>
      copyWith(fontFamily: FontFamily.jetBrainsMono.value);
}
