import 'package:flutter/widgets.dart';
import 'package:flrone/ui/common_button.dart';
import 'package:flrone/ui/metrics.dart';
import 'package:flrone/ui/theme_data.dart';

class MinIconButtonTheme extends StatelessWidget {
  final Widget child;

  const MinIconButtonTheme({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ButtonTheme.merge(
      data: ButtonThemeData(
        icon: ButtonStyle(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          visualDensity: VisualDensity.compact,
          tapTargetSize: TapTargetSize.shrinkWrap,
          iconSize: 20.ap(context),
        ),
      ),
      child: child,
    );
  }
}
