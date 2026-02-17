import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:task_roulette/providers/theme_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ThemeProvider', () {
    late ThemeProvider provider;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      provider = ThemeProvider();
    });

    test('toggle switches from initial mode to opposite', () {
      final initial = provider.themeMode;
      provider.toggle();
      expect(provider.themeMode, isNot(initial));
    });

    test('toggle twice returns to original mode', () {
      final initial = provider.themeMode;
      provider.toggle();
      provider.toggle();
      expect(provider.themeMode, initial);
    });

    test('icon returns dark_mode when theme is dark', () {
      // Toggle until dark
      while (provider.themeMode != ThemeMode.dark) {
        provider.toggle();
      }
      expect(provider.icon, Icons.dark_mode);
    });

    test('icon returns light_mode when theme is light', () {
      // Toggle until light
      while (provider.themeMode != ThemeMode.light) {
        provider.toggle();
      }
      expect(provider.icon, Icons.light_mode);
    });

    test('notifies listeners on toggle', () {
      int notifyCount = 0;
      provider.addListener(() => notifyCount++);
      provider.toggle();
      expect(notifyCount, 1);
    });

    test('restores saved dark theme preference', () async {
      SharedPreferences.setMockInitialValues({'theme_mode': 'dark'});
      final p = ThemeProvider();
      // Allow async _loadPreference to complete
      await Future.delayed(Duration.zero);
      expect(p.themeMode, ThemeMode.dark);
    });

    test('restores saved light theme preference', () async {
      SharedPreferences.setMockInitialValues({'theme_mode': 'light'});
      final p = ThemeProvider();
      await Future.delayed(Duration.zero);
      expect(p.themeMode, ThemeMode.light);
    });
  });
}
