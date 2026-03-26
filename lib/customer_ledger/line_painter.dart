import 'package:flutter/material.dart';

class LinePainter extends CustomPainter {
  final String text;
  final TextStyle style;
  final Color color;
  final Color focusedColor;
  final bool isFocused;

  LinePainter({
    required this.text,
    required this.style,
    required this.color,
    required this.focusedColor,
    required this.isFocused,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // No underlines drawn
  }

  @override
  bool shouldRepaint(LinePainter oldDelegate) {
    return oldDelegate.text != text ||
        oldDelegate.color != color ||
        oldDelegate.isFocused != isFocused;
  }
}
