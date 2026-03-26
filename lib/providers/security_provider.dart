import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSecuritySettings {
  final bool appLockEnabled;
  final bool isLoaded;

  const AppSecuritySettings({
    required this.appLockEnabled,
    required this.isLoaded,
  });

  AppSecuritySettings copyWith({bool? appLockEnabled, bool? isLoaded}) {
    return AppSecuritySettings(
      appLockEnabled: appLockEnabled ?? this.appLockEnabled,
      isLoaded: isLoaded ?? this.isLoaded,
    );
  }
}

final securityProvider =
    StateNotifierProvider<SecurityNotifier, AppSecuritySettings>((ref) {
      return SecurityNotifier();
    });

class SecurityNotifier extends StateNotifier<AppSecuritySettings> {
  SecurityNotifier()
    : super(const AppSecuritySettings(appLockEnabled: false, isLoaded: false)) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final appLockEnabled = prefs.getBool('appLockEnabled') ?? false;
    state = state.copyWith(appLockEnabled: appLockEnabled, isLoaded: true);
  }

  Future<void> setAppLockEnabled(bool enabled) async {
    state = state.copyWith(appLockEnabled: enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('appLockEnabled', enabled);
  }
}
