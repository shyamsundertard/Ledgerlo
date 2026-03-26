import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workmanager/workmanager.dart';

import '../../data/models/app_metadata.dart';
import '../../data/models/business_profile.dart';
import '../../data/models/customer.dart';
import '../../data/models/transaction.dart';
import 'backup_notification_service.dart';
import 'csv_backup_service.dart';

const String _kAutoBackupTaskName = 'ledgerlo_auto_backup_task';
const String _kAutoBackupUniqueName = 'ledgerlo.auto.backup.periodic';

@pragma('vm:entry-point')
void backupCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    await BackupNotificationService.initialize();

    if (task != _kAutoBackupTaskName) {
      return true;
    }

    Isar? isar;
    try {
      final dir = await getApplicationDocumentsDirectory();
      isar = await Isar.open([
        CustomerSchema,
        TransactionSchema,
        AppMetadataSchema,
        BusinessProfileSchema,
      ], directory: dir.path);

      final result = await CsvBackupService.runScheduledBackupWithResult(isar);
      await BackupNotificationService.showAutoBackupStatus(result);
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        await isar?.close();
      } catch (_) {}
    }
  });
}

class BackupScheduler {
  static bool _initialized = false;

  static Future<void> initialize() async {
    if (_initialized) return;

    await Workmanager().initialize(
      backupCallbackDispatcher,
      isInDebugMode: false,
    );
    _initialized = true;
  }

  static Future<void> ensurePeriodicAutoBackupTask() async {
    if (!_initialized) {
      await initialize();
    }

    if (Platform.isAndroid) {
      await Workmanager().registerPeriodicTask(
        _kAutoBackupUniqueName,
        _kAutoBackupTaskName,
        frequency: const Duration(minutes: 15),
        existingWorkPolicy: ExistingWorkPolicy.replace,
        initialDelay: const Duration(minutes: 1),
      );
      return;
    }

    if (Platform.isIOS) {
      await Workmanager().registerPeriodicTask(
        _kAutoBackupUniqueName,
        _kAutoBackupTaskName,
        frequency: const Duration(hours: 1),
        existingWorkPolicy: ExistingWorkPolicy.replace,
        initialDelay: const Duration(minutes: 5),
      );
    }
  }
}
