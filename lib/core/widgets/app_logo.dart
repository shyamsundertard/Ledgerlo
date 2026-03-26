import 'package:flutter/material.dart';

class AppLogo extends StatelessWidget {
  final double height;
  final double? width;
  final BoxFit fit;

  const AppLogo({
    super.key,
    this.height = 28,
    this.width,
    this.fit = BoxFit.contain,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final assetPath = isDark ? 'logo_light.png' : 'logo_dark.png';

    return Image.asset(
      assetPath,
      height: height,
      width: width,
      fit: fit,
      filterQuality: FilterQuality.high,
    );
  }
}
