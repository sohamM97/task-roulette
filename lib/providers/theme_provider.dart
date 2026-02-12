import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeProvider extends ChangeNotifier {
  static const _key = 'theme_mode';
  late ThemeMode _themeMode;

  ThemeProvider() {
    final brightness = SchedulerBinding.instance.platformDispatcher.platformBrightness;
    _themeMode = brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light;
    _loadPreference();
  }

  ThemeMode get themeMode => _themeMode;

  Future<void> _loadPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_key);
    if (saved != null) {
      _themeMode = saved == 'dark' ? ThemeMode.dark : ThemeMode.light;
      notifyListeners();
    }
  }

  void toggle() {
    _themeMode = _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    notifyListeners();
    _savePreference();
  }

  Future<void> _savePreference() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, _themeMode == ThemeMode.dark ? 'dark' : 'light');
  }

  IconData get icon {
    return _themeMode == ThemeMode.dark ? Icons.dark_mode : Icons.light_mode;
  }
}
