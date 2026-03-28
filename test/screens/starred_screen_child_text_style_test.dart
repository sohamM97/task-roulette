import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/screens/starred_screen.dart';

void main() {
  group('childTextStyle', () {
    const baseColor = Colors.white;
    const accent = Colors.blue;
    const fontSize = 14.0;

    test('returns dimmed style for blocked tasks', () {
      final task = Task(name: 'Blocked task', priority: 0);
      final style = childTextStyle(
        task: task,
        baseColor: baseColor,
        accent: accent,
        fontSize: fontSize,
        isBlocked: true,
      );

      expect(style.fontSize, fontSize);
      expect(style.color!.a, closeTo(100 / 255, 0.01));
      expect(style.fontWeight, isNull);
      expect(style.height, 1.3);
    });

    test('returns accent-tinted bold style for high-priority tasks', () {
      final task = Task(name: 'Urgent task', priority: 2);
      final style = childTextStyle(
        task: task,
        baseColor: baseColor,
        accent: accent,
        fontSize: fontSize,
      );

      expect(style.fontSize, fontSize);
      // Color should be a blend of baseColor and accent (50% lerp)
      final expectedColor = Color.lerp(baseColor, accent, 0.5)!;
      expect(style.color, expectedColor);
      expect(style.fontWeight, FontWeight.w600);
      expect(style.height, 1.3);
    });

    test('returns normal style for non-priority, non-blocked tasks', () {
      final task = Task(name: 'Normal task', priority: 0);
      final style = childTextStyle(
        task: task,
        baseColor: baseColor,
        accent: accent,
        fontSize: fontSize,
      );

      expect(style.fontSize, fontSize);
      expect(style.color, baseColor);
      expect(style.fontWeight, isNull);
      expect(style.height, 1.3);
    });

    test('blocked takes precedence over high-priority', () {
      // A task that is both high-priority and blocked should show dimmed style
      final task = Task(name: 'Priority blocked', priority: 2);
      final style = childTextStyle(
        task: task,
        baseColor: baseColor,
        accent: accent,
        fontSize: fontSize,
        isBlocked: true,
      );

      // Blocked style: dimmed alpha, no bold
      expect(style.color!.a, closeTo(100 / 255, 0.01));
      expect(style.fontWeight, isNull);
    });

    test('priority 1 is also treated as high priority', () {
      final task = Task(name: 'Priority 1', priority: 1);
      final style = childTextStyle(
        task: task,
        baseColor: baseColor,
        accent: accent,
        fontSize: fontSize,
      );

      expect(style.fontWeight, FontWeight.w600);
      final expectedColor = Color.lerp(baseColor, accent, 0.5)!;
      expect(style.color, expectedColor);
    });

    test('respects custom fontSize', () {
      final task = Task(name: 'Small text', priority: 0);
      final style = childTextStyle(
        task: task,
        baseColor: baseColor,
        accent: accent,
        fontSize: 10.0,
      );

      expect(style.fontSize, 10.0);
    });
  });
}
