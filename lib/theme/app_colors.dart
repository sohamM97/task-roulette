import 'package:flutter/material.dart';

class AppColors {
  static const cardColors = [
    Color(0xFFE8DEF8), // purple
    Color(0xFFD0E8FF), // blue
    Color(0xFFDCEDC8), // green
    Color(0xFFFFE0B2), // orange
    Color(0xFFF8BBD0), // pink
    Color(0xFFB2EBF2), // cyan
    Color(0xFFFFF9C4), // yellow
    Color(0xFFD1C4E9), // lavender
  ];

  static const cardColorsDark = [
    Color(0xFF352E4D), // purple
    Color(0xFF2E354D), // blue
    Color(0xFF2E3E35), // sage
    Color(0xFF3E3530), // warm grey
    Color(0xFF3E2E38), // mauve
    Color(0xFF2E3E3E), // teal
    Color(0xFF38362E), // taupe
    Color(0xFF302E45), // slate
  ];

  static Color cardColor(BuildContext context, int taskId) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = isDark ? cardColorsDark : cardColors;
    return colors[taskId % colors.length];
  }
}
