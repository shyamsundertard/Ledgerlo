import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'csv_backup_service.dart';

class BackupNotificationService {
  static const String _channelId = 'ledgerlo_auto_backup';
  static const String _channelName = 'Automatic Backup';
  static const String _channelDescription =
      'Shows automatic backup status updates.';

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  static Future<void> initialize() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    await _plugin.initialize(
      const InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      ),
    );

    const channel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: _channelDescription,
      importance: Importance.defaultImportance,
    );

    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    _initialized = true;
  }

  static Future<void> showAutoBackupStatus(
    AutoBackupRunResult result,
  ) async {
    if (!_initialized) {
      await initialize();
    }

    if (result.outcome == AutoBackupRunOutcome.notDue ||
        result.outcome == AutoBackupRunOutcome.disabled) {
      return;
    }

    if (result.outcome == AutoBackupRunOutcome.missingFolder) {
      return;
    }

    final details = NotificationDetails(
      android: const AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDescription,
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      ),
      iOS: const DarwinNotificationDetails(),
    );

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final notificationId = now % 2147483647;

    await _plugin.show(
      notificationId,
      result.notificationTitle,
      result.notificationBody,
      details,
    );
  }
}
