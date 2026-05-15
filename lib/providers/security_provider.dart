import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppLockCooldownOption {
  immediate,
  fifteenSeconds,
  thirtySeconds,
  oneMinute,
  fiveMinutes,
}

extension AppLockCooldownOptionX on AppLockCooldownOption {
  int get seconds {
    switch (this) {
      case AppLockCooldownOption.immediate:
        return 0;
      case AppLockCooldownOption.fifteenSeconds:
        return 15;
      case AppLockCooldownOption.thirtySeconds:
        return 30;
      case AppLockCooldownOption.oneMinute:
        return 60;
      case AppLockCooldownOption.fiveMinutes:
        return 300;
    }
  }

  String get label {
    switch (this) {
      case AppLockCooldownOption.immediate:
        return 'Immediately';
      case AppLockCooldownOption.fifteenSeconds:
        return 'After 15 seconds';
      case AppLockCooldownOption.thirtySeconds:
        return 'After 30 seconds';
      case AppLockCooldownOption.oneMinute:
        return 'After 1 minute';
      case AppLockCooldownOption.fiveMinutes:
        return 'After 5 minutes';
    }
  }

  String get storageValue {
    switch (this) {
      case AppLockCooldownOption.immediate:
        return 'immediate';
      case AppLockCooldownOption.fifteenSeconds:
        return '15s';
      case AppLockCooldownOption.thirtySeconds:
        return '30s';
      case AppLockCooldownOption.oneMinute:
        return '1m';
      case AppLockCooldownOption.fiveMinutes:
        return '5m';
    }
  }
}

AppLockCooldownOption appLockCooldownOptionFromStorage(String? value) {
  for (final option in AppLockCooldownOption.values) {
    if (option.storageValue == value) return option;
  }
  return AppLockCooldownOption.immediate;
}

class AppSecuritySettings {
  final bool appLockEnabled;
  final AppLockCooldownOption appLockCooldown;
  final bool isLoaded;

  const AppSecuritySettings({
    required this.appLockEnabled,
    required this.appLockCooldown,
    required this.isLoaded,
  });

  AppSecuritySettings copyWith({
    bool? appLockEnabled,
    AppLockCooldownOption? appLockCooldown,
    bool? isLoaded,
  }) {
    return AppSecuritySettings(
      appLockEnabled: appLockEnabled ?? this.appLockEnabled,
      appLockCooldown: appLockCooldown ?? this.appLockCooldown,
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
    : super(
        const AppSecuritySettings(
          appLockEnabled: false,
          appLockCooldown: AppLockCooldownOption.immediate,
          isLoaded: false,
        ),
      ) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final appLockEnabled = prefs.getBool('appLockEnabled') ?? false;
    final cooldown = appLockCooldownOptionFromStorage(
      prefs.getString('appLockCooldown'),
    );
    state = state.copyWith(
      appLockEnabled: appLockEnabled,
      appLockCooldown: cooldown,
      isLoaded: true,
    );
  }

  Future<void> setAppLockEnabled(bool enabled) async {
    state = state.copyWith(appLockEnabled: enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('appLockEnabled', enabled);
  }

  Future<void> setAppLockCooldown(AppLockCooldownOption option) async {
    state = state.copyWith(appLockCooldown: option);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('appLockCooldown', option.storageValue);
  }
}
