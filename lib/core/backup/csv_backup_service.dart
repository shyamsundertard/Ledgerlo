import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/services.dart';
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/enums/transaction_type.dart';
import '../../data/models/app_metadata.dart';
import '../../data/models/business_profile.dart';
import '../../data/models/customer.dart';
import '../../data/models/transaction.dart' as txn_model;

enum BackupFileType { csv, zip }

enum AutoBackupFrequency { manual, daily }

enum AutoBackupRunOutcome {
  disabled,
  notDue,
  missingFolder,
  backupCreated,
  skippedNoChanges,
  failed,
}

class AutoBackupRunResult {
  final AutoBackupRunOutcome outcome;
  final DateTime timestamp;
  final String? error;

  const AutoBackupRunResult({
    required this.outcome,
    required this.timestamp,
    this.error,
  });

  bool get createdBackup => outcome == AutoBackupRunOutcome.backupCreated;

  String get notificationTitle {
    switch (outcome) {
      case AutoBackupRunOutcome.backupCreated:
        return 'Automatic backup complete';
      case AutoBackupRunOutcome.skippedNoChanges:
        return 'Automatic backup skipped';
      case AutoBackupRunOutcome.failed:
        return 'Automatic backup failed';
      case AutoBackupRunOutcome.missingFolder:
        return 'Automatic backup not configured';
      case AutoBackupRunOutcome.disabled:
      case AutoBackupRunOutcome.notDue:
        return 'Automatic backup';
    }
  }

  String get notificationBody {
    switch (outcome) {
      case AutoBackupRunOutcome.backupCreated:
        return 'Your scheduled backup was created successfully.';
      case AutoBackupRunOutcome.skippedNoChanges:
        return 'No changes were detected since the last backup.';
      case AutoBackupRunOutcome.failed:
        return error == null || error!.trim().isEmpty
            ? 'Backup could not be completed.'
            : error!;
      case AutoBackupRunOutcome.missingFolder:
        return 'Select a backup folder to continue automatic backups.';
      case AutoBackupRunOutcome.disabled:
      case AutoBackupRunOutcome.notDue:
        return '';
    }
  }
}

class BackupExportResult {
  final BackupFileType type;
  final String savedPath;

  const BackupExportResult({required this.type, required this.savedPath});
}

enum ManualBackupOutcome {
  created,
  skippedNoChanges,
  missingFolder,
}

class ManualBackupResult {
  final ManualBackupOutcome outcome;
  final BackupFileType? type;
  final String? savedPath;

  const ManualBackupResult({
    required this.outcome,
    this.type,
    this.savedPath,
  });

  bool get created => outcome == ManualBackupOutcome.created;
}

class PickedBackupFile {
  final BackupFileType type;
  final String? csvContent;
  final Uint8List? zipBytes;

  const PickedBackupFile._({
    required this.type,
    this.csvContent,
    this.zipBytes,
  });

  const PickedBackupFile.csv(String content)
    : this._(type: BackupFileType.csv, csvContent: content);

  const PickedBackupFile.zip(Uint8List bytes)
    : this._(type: BackupFileType.zip, zipBytes: bytes);
}

class AutoBackupSettings {
  final String? directoryPath;
  final AutoBackupFrequency frequency;
  final int maxAutoBackupFiles;
  final DateTime? lastBackupAt;
  final String? lastStatus;
  final DateTime? lastStatusAt;
  final DateTime? lastCheckAt;
  final String? lastError;
  final int backupHour;
  final int backupMinute;

  const AutoBackupSettings({
    required this.directoryPath,
    required this.frequency,
    required this.maxAutoBackupFiles,
    required this.lastBackupAt,
    required this.lastStatus,
    required this.lastStatusAt,
    required this.lastCheckAt,
    required this.lastError,
    required this.backupHour,
    required this.backupMinute,
  });
}

class CsvBackupService {
  static const String _filePrefix = 'ledger_app_backup';
  static const String _zipPrefix = 'ledger_app_backup_full';
  static const int _minAutoBackupFiles = 3;
  static const int _defaultAutoBackupFiles = 3;
  static const int _maxAutoBackupFiles = 30;
  static const String _csvEntryName = 'backup.csv';
  static const String _mediaFolderName = 'media';
  static const String _autoBackupDirKey = 'autoBackupDirectoryPath';
  static const String _autoBackupFreqKey = 'autoBackupFrequency';
  static const String _autoBackupMaxFilesKey = 'autoBackupMaxFiles';
  static const String _autoBackupLastRunKey = 'autoBackupLastRunAt';
  static const String _autoBackupLastStatusKey = 'autoBackupLastStatus';
  static const String _autoBackupLastStatusAtKey = 'autoBackupLastStatusAt';
  static const String _autoBackupLastCheckKey = 'autoBackupLastCheckAt';
  static const String _autoBackupLastErrorKey = 'autoBackupLastError';
  static const String _autoBackupLastHashKey = 'autoBackupLastContentHash';
  static const String _autoBackupHourKey = 'autoBackupHour';
  static const String _autoBackupMinuteKey = 'autoBackupMinute';
  static final StreamController<void> _autoBackupStateController =
      StreamController<void>.broadcast();
  static const MethodChannel _fileOpsChannel = MethodChannel(
    'com.ledgerlo.app/file_ops',
  );
  static const MethodChannel _legacyFileOpsChannel = MethodChannel(
    'com.ledgerlo.app/files_ops',
  );

  static const List<String> _prefKeys = <String>[
    'currencyCode',
    'isDarkMode',
    'transactionLabelStyle',
    'appLockEnabled',
  ];

  static Stream<void> get autoBackupStateStream =>
      _autoBackupStateController.stream;

  static void _notifyAutoBackupStateChanged() {
    if (!_autoBackupStateController.isClosed) {
      _autoBackupStateController.add(null);
    }
  }

  static Future<void> _setLastAutoBackupStatus(
    SharedPreferences prefs,
    String status,
    DateTime when,
  ) async {
    await prefs.setString(_autoBackupLastStatusKey, status);
    await prefs.setString(_autoBackupLastStatusAtKey, when.toIso8601String());
  }

  static Future<AutoBackupSettings> getAutoBackupSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_autoBackupDirKey);
    final freqRaw = prefs.getString(_autoBackupFreqKey);
    final maxFilesRaw = prefs.getInt(_autoBackupMaxFilesKey);
    final lastRaw = prefs.getString(_autoBackupLastRunKey);
    final statusRaw = prefs.getString(_autoBackupLastStatusKey);
    final statusAtRaw = prefs.getString(_autoBackupLastStatusAtKey);
    final checkRaw = prefs.getString(_autoBackupLastCheckKey);
    final errorRaw = prefs.getString(_autoBackupLastErrorKey);
    final storedHour = prefs.getInt(_autoBackupHourKey);
    final storedMinute = prefs.getInt(_autoBackupMinuteKey);

    AutoBackupFrequency frequency = AutoBackupFrequency.manual;
    if (freqRaw == AutoBackupFrequency.daily.name || freqRaw == 'weekly') {
      frequency = AutoBackupFrequency.daily;
    }

    return AutoBackupSettings(
      directoryPath: (path == null || path.trim().isEmpty) ? null : path,
      frequency: frequency,
      maxAutoBackupFiles:
          _normalizeAutoBackupFileCount(maxFilesRaw),
      lastBackupAt: lastRaw == null ? null : DateTime.tryParse(lastRaw),
      lastStatus: (statusRaw == null || statusRaw.trim().isEmpty)
          ? null
          : statusRaw,
      lastStatusAt: statusAtRaw == null ? null : DateTime.tryParse(statusAtRaw),
        lastCheckAt: checkRaw == null ? null : DateTime.tryParse(checkRaw),
        lastError: (errorRaw == null || errorRaw.trim().isEmpty)
          ? null
          : errorRaw,
      backupHour: storedHour == null || storedHour < 0 || storedHour > 23
          ? 2
          : storedHour,
      backupMinute: storedMinute == null || storedMinute < 0 || storedMinute > 59
          ? 0
          : storedMinute,
    );
  }

  static Future<void> setAutoBackupDirectory(String? directoryPath) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = directoryPath?.trim();
    if (normalized == null || normalized.isEmpty) {
      await prefs.remove(_autoBackupDirKey);
      _notifyAutoBackupStateChanged();
      return;
    }
    await prefs.setString(_autoBackupDirKey, normalized);
    _notifyAutoBackupStateChanged();
  }

  static Future<void> validateAutoBackupDirectoryWritable(
    String directoryPath,
  ) async {
    final trimmed = directoryPath.trim();
    if (trimmed.isEmpty) {
      throw Exception('Please select a valid backup folder.');
    }
    if (trimmed.startsWith('content://')) {
      throw Exception(
        'This folder path is not directly writable by scheduled backup on this device. Please choose a standard local folder path.',
      );
    }

    final dir = Directory(trimmed);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final testFile = File(
      '${dir.path}/.ledgerlo_write_test_${DateTime.now().microsecondsSinceEpoch}.tmp',
    );

    try {
      await testFile.writeAsString('ok', flush: true);
    } finally {
      try {
        if (await testFile.exists()) {
          await testFile.delete();
        }
      } catch (_) {}
    }
  }

  static Future<void> setAutoBackupFrequency(AutoBackupFrequency frequency) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_autoBackupFreqKey, frequency.name);
    _notifyAutoBackupStateChanged();
  }

  static Future<void> setAutoBackupMaxFiles(int maxFiles) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = _normalizeAutoBackupFileCount(maxFiles);
    await prefs.setInt(_autoBackupMaxFilesKey, normalized);
    _notifyAutoBackupStateChanged();
  }

  static Future<void> setAutoBackupTime({
    required int hour,
    required int minute,
  }) async {
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      throw ArgumentError('Invalid backup time');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_autoBackupHourKey, hour);
    await prefs.setInt(_autoBackupMinuteKey, minute);
    _notifyAutoBackupStateChanged();
  }

  static Future<bool> runScheduledBackupIfDue(Isar isar) async {
    final result = await runScheduledBackupWithResult(isar);
    return result.createdBackup;
  }

  static Future<AutoBackupRunResult> runScheduledBackupWithResult(Isar isar) async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    await prefs.setString(_autoBackupLastCheckKey, now.toIso8601String());

    final settings = await getAutoBackupSettings();
    if (settings.frequency == AutoBackupFrequency.manual) {
      await prefs.remove(_autoBackupLastErrorKey);
      _notifyAutoBackupStateChanged();
      return AutoBackupRunResult(
        outcome: AutoBackupRunOutcome.disabled,
        timestamp: now,
      );
    }

    final directoryPath = settings.directoryPath;
    if (directoryPath == null || directoryPath.trim().isEmpty) {
      await prefs.setString(
        _autoBackupLastErrorKey,
        'Backup folder is not selected.',
      );
      _notifyAutoBackupStateChanged();
      return AutoBackupRunResult(
        outcome: AutoBackupRunOutcome.missingFolder,
        timestamp: now,
        error: 'Backup folder is not selected.',
      );
    }

    final lastRun = settings.lastBackupAt;

    final scheduledToday = DateTime(
      now.year,
      now.month,
      now.day,
      settings.backupHour,
      settings.backupMinute,
    );

    final reachedScheduledTime =
        now.isAfter(scheduledToday) || now.isAtSameMomentAs(scheduledToday);

    final isDue = reachedScheduledTime &&
      (lastRun == null || lastRun.isBefore(scheduledToday));

    if (!isDue) {
      await prefs.remove(_autoBackupLastErrorKey);
      return AutoBackupRunResult(
        outcome: AutoBackupRunOutcome.notDue,
        timestamp: now,
      );
    }

    try {
      await validateAutoBackupDirectoryWritable(directoryPath);

      final payload = await _buildSmartBackupPayload(isar);
      final currentHash = payload.contentHash;
      final previousHash = prefs.getString(_autoBackupLastHashKey);

      if (previousHash != null && previousHash == currentHash) {
        await prefs.setString(_autoBackupLastRunKey, now.toIso8601String());
        await _setLastAutoBackupStatus(prefs, 'Skipped (no changes)', now);
        await prefs.remove(_autoBackupLastErrorKey);
        _notifyAutoBackupStateChanged();
        return AutoBackupRunResult(
          outcome: AutoBackupRunOutcome.skippedNoChanges,
          timestamp: now,
        );
      }

      final timestamp = now.toIso8601String().replaceAll(':', '-');
      final baseName = payload.type == BackupFileType.zip
          ? '${_zipPrefix}_auto-$timestamp'
          : '${_filePrefix}_auto-$timestamp';

      await _saveBytesToDirectory(
        bytes: payload.bytes,
        directoryPath: directoryPath,
        baseName: baseName,
        extension: payload.extension,
      );

      await _enforceAutoBackupRetention(
        directoryPath,
        settings.maxAutoBackupFiles,
      );

      await prefs.setString(_autoBackupLastRunKey, now.toIso8601String());
      await prefs.setString(_autoBackupLastHashKey, currentHash);
      await _setLastAutoBackupStatus(prefs, 'Backup created', now);
      await prefs.remove(_autoBackupLastErrorKey);
      _notifyAutoBackupStateChanged();
      return AutoBackupRunResult(
        outcome: AutoBackupRunOutcome.backupCreated,
        timestamp: now,
      );
    } catch (error) {
      await prefs.setString(_autoBackupLastErrorKey, error.toString());
      await _setLastAutoBackupStatus(prefs, 'Failed', now);
      _notifyAutoBackupStateChanged();
      return AutoBackupRunResult(
        outcome: AutoBackupRunOutcome.failed,
        timestamp: now,
        error: error.toString(),
      );
    }
  }

  static Future<BackupExportResult> exportSmartBackup(Isar isar) async {
    final payload = await _buildSmartBackupPayload(isar);
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final baseName = payload.type == BackupFileType.zip
        ? '$_zipPrefix-$timestamp'
        : '$_filePrefix-$timestamp';

    final savedPath = await _saveBytesToUser(
      bytes: payload.bytes,
      baseName: baseName,
      extension: payload.extension,
      mimeType: payload.mimeType,
    );

    return BackupExportResult(type: payload.type, savedPath: savedPath);
  }

  static Future<ManualBackupResult> exportSmartBackupToSelectedFolderIfChanged(
    Isar isar,
  ) async {
    final settings = await getAutoBackupSettings();
    final directoryPath = settings.directoryPath;
    if (directoryPath == null || directoryPath.trim().isEmpty) {
      return const ManualBackupResult(
        outcome: ManualBackupOutcome.missingFolder,
      );
    }

    final prefs = await SharedPreferences.getInstance();
    await validateAutoBackupDirectoryWritable(directoryPath);

    final payload = await _buildSmartBackupPayload(isar);
    final currentHash = payload.contentHash;
    final previousHash = prefs.getString(_autoBackupLastHashKey);
    if (previousHash != null && previousHash == currentHash) {
      return const ManualBackupResult(
        outcome: ManualBackupOutcome.skippedNoChanges,
      );
    }

    final now = DateTime.now();
    final timestamp = now.toIso8601String().replaceAll(':', '-');
    final baseName = payload.type == BackupFileType.zip
        ? '${_zipPrefix}_manual-$timestamp'
        : '${_filePrefix}_manual-$timestamp';

    final savedPath = await _saveBytesToDirectory(
      bytes: payload.bytes,
      directoryPath: directoryPath,
      baseName: baseName,
      extension: payload.extension,
    );

    await prefs.setString(_autoBackupLastHashKey, currentHash);
    await _enforceAutoBackupRetention(directoryPath, settings.maxAutoBackupFiles);

    return ManualBackupResult(
      outcome: ManualBackupOutcome.created,
      type: payload.type,
      savedPath: savedPath,
    );
  }

  static Future<PickedBackupFile?> pickBackupFromPicker({
    String? initialDirectory,
  }) async {
    final normalizedInitialDirectory = initialDirectory?.trim();
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'zip'],
      withData: true,
      initialDirectory: (normalizedInitialDirectory == null ||
              normalizedInitialDirectory.isEmpty)
          ? null
          : normalizedInitialDirectory,
    );

    if (picked == null || picked.files.isEmpty) {
      return null;
    }

    final file = picked.files.single;
    final ext = (file.extension ?? '').trim().toLowerCase();
    if (ext == 'zip') {
      final bytes = file.bytes ??
          (file.path != null ? await File(file.path!).readAsBytes() : null);
      if (bytes == null || bytes.isEmpty) return null;
      return PickedBackupFile.zip(bytes);
    }

    if (ext == 'csv') {
      if (file.bytes != null) {
        return PickedBackupFile.csv(utf8.decode(file.bytes!));
      }
      if (file.path != null) {
        return PickedBackupFile.csv(await File(file.path!).readAsString());
      }
      return null;
    }

    throw Exception('Unsupported backup file. Please select CSV or ZIP.');
  }

  static Future<PickedBackupFile?> pickRestoreBackupFromPicker({
    String? initialDirectory,
  }) {
    return pickBackupFromPicker(initialDirectory: initialDirectory);
  }

  static Future<CsvImportDiff> buildImportDiffFromBackup(
    Isar isar,
    PickedBackupFile file,
  ) async {
    switch (file.type) {
      case BackupFileType.csv:
        return buildImportDiff(isar, file.csvContent ?? '');
      case BackupFileType.zip:
        final bytes = file.zipBytes;
        if (bytes == null || bytes.isEmpty) {
          throw Exception('ZIP backup is empty.');
        }
        return buildImportDiffFromZipBytes(isar, bytes);
    }
  }

  static Future<CsvImportDiff> buildRestoreDiffFromBackup(
    Isar isar,
    PickedBackupFile file,
  ) {
    return buildImportDiffFromBackup(isar, file);
  }

  static Future<int> replaceAllDataFromBackup(
    Isar isar,
    PickedBackupFile file,
  ) async {
    switch (file.type) {
      case BackupFileType.csv:
        return replaceAllDataFromCsv(isar, file.csvContent ?? '');
      case BackupFileType.zip:
        final bytes = file.zipBytes;
        if (bytes == null || bytes.isEmpty) {
          throw Exception('ZIP backup is empty.');
        }
        return replaceAllDataFromZipBytes(isar, bytes);
    }
  }

  static Future<int> restoreAllDataFromBackup(
    Isar isar,
    PickedBackupFile file,
  ) {
    return replaceAllDataFromBackup(isar, file);
  }

  static Future<ProfileCustomerImportResult>
  importCustomersIntoProfileFromBackup(
    Isar isar, {
    required int targetProfileId,
    required PickedBackupFile file,
    Set<String>? replaceConflictKeys,
    Set<String>? skipConflictKeys,
    Map<String, String>? renameByImportKey,
  }) async {
    final resolved = await _resolveImportCsvAndMedia(file);
    final rows = _parseCsv(resolved.csv);

    final entries = _extractImportCustomerEntries(rows);
    final replaceKeys = replaceConflictKeys ?? const <String>{};
    final skipKeys = skipConflictKeys ?? const <String>{};
    if (replaceKeys.isNotEmpty) {
      final conflicts = await _buildCustomerImportConflicts(
        isar,
        targetProfileId: targetProfileId,
        entries: entries,
      );
      await _replaceExistingCustomersForConflictKeys(
        isar,
        targetProfileId: targetProfileId,
        conflicts: conflicts,
        replaceKeys: replaceKeys,
      );
    }

    return _importCustomersIntoProfileFromCsv(
      isar,
      targetProfileId: targetProfileId,
      csv: resolved.csv,
      mediaPathMap: resolved.mediaPathMap,
      skipConflictKeys: skipKeys,
      renameByImportKey: renameByImportKey,
    );
  }

  static Future<List<CustomerImportConflict>> getCustomerImportConflicts(
    Isar isar, {
    required int targetProfileId,
    required PickedBackupFile file,
  }) async {
    final resolved = await _resolveImportCsvAndMedia(file);
    final rows = _parseCsv(resolved.csv);
    final entries = _extractImportCustomerEntries(rows);

    return _buildCustomerImportConflicts(
      isar,
      targetProfileId: targetProfileId,
      entries: entries,
    );
  }

  static Future<List<CustomerImportConflict>> _buildCustomerImportConflicts(
    Isar isar, {
    required int targetProfileId,
    required List<_ImportCustomerEntry> entries,
  }) async {

    final existingCustomers = await isar.customers
        .filter()
        .profileIdEqualTo(targetProfileId)
        .findAll();

    final existingByNormalizedName = <String, List<Customer>>{};
    for (final customer in existingCustomers) {
      final normalized = _normalizeCustomerNameForImport(customer.name);
      if (normalized.isEmpty) continue;
      existingByNormalizedName.putIfAbsent(normalized, () => <Customer>[]).add(customer);
    }

    final existingTransactions = await isar.transactions
        .filter()
        .profileIdEqualTo(targetProfileId)
        .findAll();
    final existingCustomerIdByTxUuid = <String, int>{};
    for (final tx in existingTransactions) {
      final key = tx.uuid.trim();
      if (key.isEmpty) continue;
      existingCustomerIdByTxUuid.putIfAbsent(key, () => tx.customerId);
    }

    final conflicts = <CustomerImportConflict>[];
    final seenKeys = <String>{};
    for (final entry in entries) {
      if (!seenKeys.add(entry.key)) continue;
      final normalized = _normalizeCustomerNameForImport(entry.name);
      if (normalized.isEmpty) continue;
      final candidates = existingByNormalizedName[normalized];
      if (candidates == null || candidates.isEmpty) continue;

      Customer? matched;
      var conflictType = CustomerImportConflictType.sameNameDifferentCustomer;

      if (entry.sourceCustomerUuid != null && entry.sourceCustomerUuid!.trim().isNotEmpty) {
        final sourceUuid = entry.sourceCustomerUuid!.trim();
        final customerUuidNamespace = _customerUuidNamespaceForImportKey(entry.key);
        final scopedSourceUuid = _scopedImportedUuid(
          targetProfileId: targetProfileId,
          sourceUuid: sourceUuid,
          namespace: customerUuidNamespace,
        );
        for (final customer in candidates) {
          final existingUuid = customer.uuid.trim();
          if (existingUuid == sourceUuid || existingUuid == scopedSourceUuid) {
            matched = customer;
            conflictType = CustomerImportConflictType.sameCustomer;
            break;
          }
        }
      }

      if (matched == null && entry.transactionUuids.isNotEmpty) {
        final txUuidNamespace = _transactionUuidNamespaceForImportKey(entry.key);
        for (final txUuid in entry.transactionUuids) {
          final scopedTxUuid = _scopedImportedUuid(
            targetProfileId: targetProfileId,
            sourceUuid: txUuid,
            namespace: txUuidNamespace,
          );
          final customerId =
              existingCustomerIdByTxUuid[txUuid] ??
              existingCustomerIdByTxUuid[scopedTxUuid];
          if (customerId == null) continue;
          final candidate = candidates
              .where((customer) => customer.id == customerId)
              .firstOrNull;
          if (candidate != null) {
            matched = candidate;
            conflictType = CustomerImportConflictType.sameCustomer;
            break;
          }
        }
      }

      matched ??= candidates.first;

      conflicts.add(
        CustomerImportConflict(
          importKey: entry.key,
          incomingName: entry.name,
          existingCustomerId: matched.id,
          existingName: matched.name,
          type: conflictType,
        ),
      );
    }

    return conflicts;
  }

  static Future<ProfileCustomerImportResult> _importCustomersIntoProfileFromCsv(
    Isar isar, {
    required int targetProfileId,
    required String csv,
    Map<String, String>? mediaPathMap,
    Set<String>? skipConflictKeys,
    Map<String, String>? renameByImportKey,
  }) async {
    final rows = _parseCsv(csv);
    if (rows.length <= 1) {
      return const ProfileCustomerImportResult(
        customersImported: 0,
        transactionsImported: 0,
      );
    }

    final header = rows.first.map((value) => value.trim().toLowerCase()).toList();
    final isCustomerExportFormat =
        header.contains('customer_id') &&
        header.contains('transaction_id') &&
        header.contains('bill_primary');

    if (isCustomerExportFormat) {
      return _importFromCustomerExportRows(
        isar,
        targetProfileId: targetProfileId,
        rows: rows,
        mediaPathMap: mediaPathMap,
        skipConflictKeys: skipConflictKeys,
        renameByImportKey: renameByImportKey,
      );
    }

    return _importFromBackupRows(
      isar,
      targetProfileId: targetProfileId,
      rows: rows,
      mediaPathMap: mediaPathMap,
      skipConflictKeys: skipConflictKeys,
      renameByImportKey: renameByImportKey,
    );
  }

  static Future<ProfileCustomerImportResult> _importFromCustomerExportRows(
    Isar isar, {
    required int targetProfileId,
    required List<List<String>> rows,
    Map<String, String>? mediaPathMap,
    Set<String>? skipConflictKeys,
    Map<String, String>? renameByImportKey,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final sourceCustomerToCreated = <String, int>{};
    final skippedSourceCustomerIds = <String>{};
    var customersImported = 0;
    var transactionsImported = 0;

    Future<int?> ensureCustomer({
      required String sourceCustomerId,
      required String sourceProfileId,
      required String customerName,
      String? profilePhotoPath,
    }) async {
      if (skippedSourceCustomerIds.contains(sourceCustomerId)) return null;

      final existingId = sourceCustomerToCreated[sourceCustomerId];
      if (existingId != null) return existingId;

      final importKey = 'export:$sourceCustomerId';
      if (skipConflictKeys != null && skipConflictKeys.contains(importKey)) {
        skippedSourceCustomerIds.add(sourceCustomerId);
        return null;
      }

      final sourceCustomerUuid = _exportImportSourceUuid(
        sourceProfileId: sourceProfileId,
        sourceCustomerId: sourceCustomerId,
      );
      final storedCustomerUuid = _scopedImportedUuid(
        targetProfileId: targetProfileId,
        sourceUuid: sourceCustomerUuid,
        namespace: 'export-customer',
      );

      final customer = Customer()
        ..uuid = storedCustomerUuid;

      final existingCustomer = await isar.customers
          .filter()
          .uuidEqualTo(storedCustomerUuid)
          .findFirst();

      final customerToSave = existingCustomer ?? customer;
      customerToSave
        ..profileId = targetProfileId
        ..name = _resolvedImportCustomerName(
          key: importKey,
          originalName: customerName,
          renameByImportKey: renameByImportKey,
        )
        ..isDeleted = false
        ..updatedAt = DateTime.now();

      final id = await isar.customers.put(customerToSave);
      if (existingCustomer == null) {
        customersImported++;
      }
      sourceCustomerToCreated[sourceCustomerId] = id;

      final resolvedProfilePhoto = _resolveMediaPath(profilePhotoPath, mediaPathMap);
      if (resolvedProfilePhoto != null && resolvedProfilePhoto.trim().isNotEmpty) {
        final key = 'customer_profile_photo_${targetProfileId}_$id';
        await prefs.setString(key, resolvedProfilePhoto);
      }
      return id;
    }

    await isar.writeTxn(() async {
      for (var index = 1; index < rows.length; index++) {
        final row = rows[index];
        final section = _field(row, 0);
        if (section != 'customer') continue;

        final sourceCustomerId = _field(row, 1);
        final sourceProfileId = _field(row, 2);
        if (sourceCustomerId.isEmpty) continue;

        final customerName = _field(row, 3);
        final profilePhotoPath = _field(row, 4);
        await ensureCustomer(
          sourceCustomerId: sourceCustomerId,
          sourceProfileId: sourceProfileId,
          customerName: customerName,
          profilePhotoPath: profilePhotoPath,
        );
      }

      for (var index = 1; index < rows.length; index++) {
        final row = rows[index];
        final section = _field(row, 0);
        if (section != 'transaction') continue;

        final sourceCustomerId = _field(row, 1);
        final sourceProfileId = _field(row, 2);
        if (sourceCustomerId.isEmpty) continue;

        final customerName = _field(row, 3);
        final customerId = await ensureCustomer(
          sourceCustomerId: sourceCustomerId,
          sourceProfileId: sourceProfileId,
          customerName: customerName,
        );
        if (customerId == null) continue;

        final typeRaw = _field(row, 8);
        final amount = double.tryParse(_field(row, 9)) ?? 0;

        final tx = txn_model.Transaction()
          ..uuid = _nullIfEmpty(_field(row, 6)) == null
            ? DateTime.now().microsecondsSinceEpoch.toString()
            : _scopedImportedUuid(
              targetProfileId: targetProfileId,
              sourceUuid: _field(row, 6),
              namespace: 'export-transaction',
            );

        final existingTx = await isar.transactions
          .filter()
          .uuidEqualTo(tx.uuid)
          .findFirst();

        final txToSave = existingTx ?? tx;
        txToSave
          ..profileId = targetProfileId
          ..customerId = customerId
          ..type = typeRaw == TransactionType.debit.name
              ? TransactionType.debit
              : TransactionType.credit
          ..amount = amount
          ..note = _nullIfEmpty(_field(row, 10))
          ..photoPath = _resolveMediaPath(_nullIfEmpty(_field(row, 11)), mediaPathMap)
          ..photoPaths = _parsePhotoPaths(_field(row, 12))
              .map((path) => _resolveMediaPath(path, mediaPathMap) ?? path)
              .toList()
          ..date = _parseDate(_field(row, 7)) ?? DateTime.now()
          ..isDeleted = false
          ..isEdited = false
          ..createdAt =
              _parseDate(_field(row, 13)) ??
              (existingTx?.createdAt ?? DateTime.now())
          ..updatedAt = _parseDate(_field(row, 14)) ?? DateTime.now();

        await isar.transactions.put(txToSave);
        if (existingTx == null) {
          transactionsImported++;
        }
      }
    });

    return ProfileCustomerImportResult(
      customersImported: customersImported,
      transactionsImported: transactionsImported,
    );
  }

  static Future<ProfileCustomerImportResult> _importFromBackupRows(
    Isar isar, {
    required int targetProfileId,
    required List<List<String>> rows,
    Map<String, String>? mediaPathMap,
    Set<String>? skipConflictKeys,
    Map<String, String>? renameByImportKey,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final backupCustomerIdToCreated = <int, int>{};
    var customersImported = 0;
    var transactionsImported = 0;

    await isar.writeTxn(() async {
      for (var index = 1; index < rows.length; index++) {
        final row = rows[index];
        if (_field(row, 0) != 'customer') continue;

        final backupCustomerId = int.tryParse(_field(row, 2)) ?? 0;
        final importKey = _backupImportKey(backupCustomerId, index);
        if (skipConflictKeys != null && skipConflictKeys.contains(importKey)) {
          continue;
        }
        final customer = Customer()
          ..uuid = _nullIfEmpty(_field(row, 1)) == null
              ? DateTime.now().microsecondsSinceEpoch.toString()
              : _scopedImportedUuid(
                  targetProfileId: targetProfileId,
                  sourceUuid: _field(row, 1),
                  namespace: 'backup-customer',
                )
          ;

        final existingCustomer = await isar.customers
            .filter()
            .uuidEqualTo(customer.uuid)
            .findFirst();

        final customerToSave = existingCustomer ?? customer;
        customerToSave
          ..profileId = targetProfileId
          ..name = _resolvedImportCustomerName(
            key: importKey,
            originalName: _field(row, 4),
            renameByImportKey: renameByImportKey,
          )
          ..phone = _nullIfEmpty(_field(row, 5))
          ..note = _nullIfEmpty(_field(row, 6))
          ..currentBalance = double.tryParse(_field(row, 7)) ?? 0
          ..isDeleted = false
          ..createdAt =
              _parseDate(_field(row, 9)) ??
              (existingCustomer?.createdAt ?? DateTime.now())
          ..updatedAt = _parseDate(_field(row, 10)) ?? DateTime.now();

        final createdId = await isar.customers.put(customerToSave);
        if (existingCustomer == null) {
          customersImported++;
        }
        if (backupCustomerId > 0) {
          backupCustomerIdToCreated[backupCustomerId] = createdId;
        }
      }

      for (var index = 1; index < rows.length; index++) {
        final row = rows[index];
        if (_field(row, 0) != 'transaction') continue;

        final backupCustomerId = int.tryParse(_field(row, 4)) ?? 0;
        final mappedCustomerId = backupCustomerIdToCreated[backupCustomerId];
        if (mappedCustomerId == null) continue;

        final tx = txn_model.Transaction()
          ..uuid = _nullIfEmpty(_field(row, 1)) == null
            ? DateTime.now().microsecondsSinceEpoch.toString()
            : _scopedImportedUuid(
              targetProfileId: targetProfileId,
              sourceUuid: _field(row, 1),
              namespace: 'backup-transaction',
            );

        final existingTx = await isar.transactions
          .filter()
          .uuidEqualTo(tx.uuid)
          .findFirst();

        final txToSave = existingTx ?? tx;
        txToSave
          ..profileId = targetProfileId
          ..customerId = mappedCustomerId
          ..type = _field(row, 5) == TransactionType.debit.name
              ? TransactionType.debit
              : TransactionType.credit
          ..amount = double.tryParse(_field(row, 6)) ?? 0
          ..note = _nullIfEmpty(_field(row, 7))
          ..photoPath = _resolveMediaPath(_nullIfEmpty(_field(row, 8)), mediaPathMap)
          ..photoPaths = _parsePhotoPaths(_field(row, 9))
              .map((path) => _resolveMediaPath(path, mediaPathMap) ?? path)
              .toList()
          ..date = _parseDate(_field(row, 10)) ?? DateTime.now()
          ..isDeleted = false
          ..isEdited = _field(row, 12) == '1'
          ..createdAt =
              _parseDate(_field(row, 13)) ??
              (existingTx?.createdAt ?? DateTime.now())
          ..updatedAt = _parseDate(_field(row, 14)) ?? DateTime.now();

        await isar.transactions.put(txToSave);
        if (existingTx == null) {
          transactionsImported++;
        }
      }

      for (var index = 1; index < rows.length; index++) {
        final row = rows[index];
        if (_field(row, 0) != 'profile_photo') continue;

        final backupCustomerId = int.tryParse(_field(row, 3)) ?? 0;
        final mappedCustomerId = backupCustomerIdToCreated[backupCustomerId];
        if (mappedCustomerId == null) continue;

        final resolved = _resolveMediaPath(_field(row, 4), mediaPathMap);
        if (resolved == null || resolved.trim().isEmpty) continue;

        final key = 'customer_profile_photo_${targetProfileId}_$mappedCustomerId';
        await prefs.setString(key, resolved);
      }
    });

    return ProfileCustomerImportResult(
      customersImported: customersImported,
      transactionsImported: transactionsImported,
    );
  }

  static Future<_ZipPayload> _extractCustomerImportZipPayload(
    Uint8List zipBytes,
  ) async {
    final archive = ZipDecoder().decodeBytes(zipBytes, verify: true);
    String? csv;
    final mediaPathMap = <String, String>{};

    final appDir = await getApplicationDocumentsDirectory();
    final mediaRoot = Directory(
      '${appDir.path}/customer_import_media/${DateTime.now().microsecondsSinceEpoch}',
    );
    if (!mediaRoot.existsSync()) {
      mediaRoot.createSync(recursive: true);
    }

    for (final file in archive.files) {
      if (!file.isFile) continue;

      final lowerName = file.name.toLowerCase();
      if (lowerName.endsWith('.csv')) {
        final data = file.content as List<int>;
        csv ??= utf8.decode(data);
        continue;
      }

      if (!lowerName.startsWith('media/')) {
        continue;
      }

      final relative = file.name.substring('media/'.length);
      if (relative.trim().isEmpty) continue;

      final outputFile = File('${mediaRoot.path}/$relative');
      outputFile.parent.createSync(recursive: true);

      final data = file.content as List<int>;
      outputFile.writeAsBytesSync(data, flush: true);
      mediaPathMap[file.name] = outputFile.path;
    }

    if (csv == null || csv.trim().isEmpty) {
      throw Exception('Invalid ZIP: CSV file not found.');
    }

    return _ZipPayload(csv: csv, mediaPathMap: mediaPathMap);
  }

  static Future<_ZipPayload> _resolveImportCsvAndMedia(
    PickedBackupFile file,
  ) async {
    switch (file.type) {
      case BackupFileType.csv:
        return _ZipPayload(
          csv: file.csvContent ?? '',
          mediaPathMap: const {},
        );
      case BackupFileType.zip:
        final bytes = file.zipBytes;
        if (bytes == null || bytes.isEmpty) {
          throw Exception('ZIP backup is empty.');
        }
        return _extractCustomerImportZipPayload(bytes);
    }
  }

  static String _normalizeCustomerNameForImport(String value) {
    return value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  }

  static String _resolvedImportCustomerName({
    required String key,
    required String originalName,
    Map<String, String>? renameByImportKey,
  }) {
    final renamed = renameByImportKey?[key];
    final selected = renamed ?? originalName;
    final normalized = selected.trim().replaceAll(RegExp(r'\s+'), ' ');
    return normalized.isEmpty ? 'Imported Customer' : normalized;
  }

  static String _backupImportKey(int backupCustomerId, int rowIndex) {
    if (backupCustomerId > 0) {
      return 'backup:$backupCustomerId';
    }
    return 'backup:row:$rowIndex';
  }

  static String _customerUuidNamespaceForImportKey(String importKey) {
    return importKey.startsWith('export:')
        ? 'export-customer'
        : 'backup-customer';
  }

  static String _transactionUuidNamespaceForImportKey(String importKey) {
    return importKey.startsWith('export:')
        ? 'export-transaction'
        : 'backup-transaction';
  }

  static String _scopedImportedUuid({
    required int targetProfileId,
    required String sourceUuid,
    required String namespace,
  }) {
    final normalizedSource = sourceUuid.trim();
    if (normalizedSource.isEmpty) {
      return DateTime.now().microsecondsSinceEpoch.toString();
    }
    return '$namespace:p$targetProfileId:$normalizedSource';
  }

  static String _exportImportSourceUuid({
    required String sourceProfileId,
    required String sourceCustomerId,
  }) {
    final profilePart = sourceProfileId.trim().isEmpty
        ? 'unknown'
        : sourceProfileId.trim();
    final customerPart = sourceCustomerId.trim().isEmpty
        ? 'unknown'
        : sourceCustomerId.trim();
    return 'export:$profilePart:$customerPart';
  }

  static List<_ImportCustomerEntry> _extractImportCustomerEntries(
    List<List<String>> rows,
  ) {
    if (rows.length <= 1) return const [];

    final header = rows.first.map((value) => value.trim().toLowerCase()).toList();
    final isCustomerExportFormat =
        header.contains('customer_id') &&
        header.contains('transaction_id') &&
        header.contains('bill_primary');

    final entries = <_ImportCustomerEntry>[];

    if (isCustomerExportFormat) {
      final bySourceId = <String, _ImportCustomerEntryBuilder>{};

      for (var index = 1; index < rows.length; index++) {
        final row = rows[index];
        final section = _field(row, 0);
        final sourceCustomerId = _field(row, 1);
        if (sourceCustomerId.isEmpty) continue;

        final builder = bySourceId.putIfAbsent(
          sourceCustomerId,
          () => _ImportCustomerEntryBuilder(key: 'export:$sourceCustomerId'),
        );

        if (section == 'customer') {
          builder.name = _field(row, 3);
          builder.sourceCustomerUuid = _exportImportSourceUuid(
            sourceProfileId: _field(row, 2),
            sourceCustomerId: sourceCustomerId,
          );
        } else if (section == 'transaction') {
          builder.addTransactionUuid(_field(row, 6));
          if (builder.name.trim().isEmpty) {
            builder.name = _field(row, 3);
          }
        }
      }

      for (final builder in bySourceId.values) {
        entries.add(builder.build());
      }
      return entries;
    }

    final byKey = <String, _ImportCustomerEntryBuilder>{};

    for (var index = 1; index < rows.length; index++) {
      final row = rows[index];
      final section = _field(row, 0);

      if (section == 'customer') {
        final backupCustomerId = int.tryParse(_field(row, 2)) ?? 0;
        final key = _backupImportKey(backupCustomerId, index);
        final builder = byKey.putIfAbsent(
          key,
          () => _ImportCustomerEntryBuilder(key: key),
        );
        builder.name = _field(row, 4);
        builder.sourceCustomerUuid = _nullIfEmpty(_field(row, 1));
        continue;
      }

      if (section == 'transaction') {
        final backupCustomerId = int.tryParse(_field(row, 4)) ?? 0;
        if (backupCustomerId <= 0) continue;
        final key = _backupImportKey(backupCustomerId, -1);
        final builder = byKey.putIfAbsent(
          key,
          () => _ImportCustomerEntryBuilder(key: key),
        );
        builder.addTransactionUuid(_field(row, 1));
      }
    }

    for (final builder in byKey.values) {
      entries.add(builder.build());
    }

    return entries;
  }

  static Future<void> _replaceExistingCustomersForConflictKeys(
    Isar isar, {
    required int targetProfileId,
    required List<CustomerImportConflict> conflicts,
    required Set<String> replaceKeys,
  }) async {
    if (replaceKeys.isEmpty) return;

    final customerIdsToDelete = conflicts
        .where((conflict) => replaceKeys.contains(conflict.importKey))
        .map((conflict) => conflict.existingCustomerId)
        .where((id) => id > 0)
        .toSet();
    if (customerIdsToDelete.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();

    await isar.writeTxn(() async {
      for (final customerId in customerIdsToDelete) {
        final txs = await isar.transactions
            .filter()
            .profileIdEqualTo(targetProfileId)
            .customerIdEqualTo(customerId)
            .findAll();
        for (final tx in txs) {
          await isar.transactions.delete(tx.id);
        }
        await isar.customers.delete(customerId);
      }
    });

    for (final customerId in customerIdsToDelete) {
      final key = 'customer_profile_photo_${targetProfileId}_$customerId';
      await prefs.remove(key);
    }
  }

  static Future<String?> pickCsvContentFromPicker() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
      withData: true,
    );

    if (picked == null || picked.files.isEmpty) {
      return null;
    }

    final file = picked.files.single;
    if (file.bytes != null) {
      return utf8.decode(file.bytes!);
    }
    if (file.path != null) {
      return File(file.path!).readAsString();
    }
    return null;
  }

  static Future<Uint8List?> pickZipBytesFromPicker() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      withData: true,
    );

    if (picked == null || picked.files.isEmpty) {
      return null;
    }

    final file = picked.files.single;
    if (file.bytes != null) {
      return file.bytes;
    }
    if (file.path != null) {
      return File(file.path!).readAsBytes();
    }
    return null;
  }

  static Future<CsvImportDiff> buildImportDiffFromZipBytes(
    Isar isar,
    Uint8List zipBytes,
  ) async {
    final csv = _extractCsvFromZipBytes(zipBytes);
    return buildImportDiff(isar, csv);
  }

  static Future<int> replaceAllDataFromZipBytes(
    Isar isar,
    Uint8List zipBytes,
  ) async {
    final payload = await _extractZipPayload(zipBytes);
    return replaceAllDataFromCsv(
      isar,
      payload.csv,
      mediaPathMap: payload.mediaPathMap,
    );
  }

  static Future<String> exportZipBackup(Isar isar) async {
    final mediaAliasByPath = await _collectMediaAliasByPath(isar);
    final csv = await _buildCsvContent(isar, mediaAliasByPath: mediaAliasByPath);
    final zipBytes = await _buildZipBytes(csv, mediaAliasByPath);

    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    return _saveBytesToUser(
      bytes: zipBytes,
      baseName: '$_zipPrefix-$timestamp',
      extension: 'zip',
      mimeType: 'application/zip',
    );
  }

  static Future<CsvImportDiff> buildImportDiff(Isar isar, String csv) async {
    final rows = _parseCsv(csv);

    final currentProfiles = await isar.businessProfiles.count();
    final currentCustomers = await isar.customers.count();
    final currentTransactions = await isar.transactions.count();
    final currentMetadata = await isar.appMetadatas.count();

    final prefs = await SharedPreferences.getInstance();
    final currentPrefs = _prefKeys.where(prefs.containsKey).length;

    var csvProfiles = 0;
    var csvCustomers = 0;
    var csvTransactions = 0;
    var csvMetadata = 0;
    var csvPrefs = 0;

    for (var i = 1; i < rows.length; i++) {
      final section = _field(rows[i], 0);
      switch (section) {
        case 'profile':
          csvProfiles++;
          break;
        case 'customer':
          csvCustomers++;
          break;
        case 'transaction':
          csvTransactions++;
          break;
        case 'metadata':
          csvMetadata++;
          break;
        case 'preference':
          csvPrefs++;
          break;
      }
    }

    return CsvImportDiff(
      currentProfiles: currentProfiles,
      currentCustomers: currentCustomers,
      currentTransactions: currentTransactions,
      currentMetadata: currentMetadata,
      currentPreferences: currentPrefs,
      csvProfiles: csvProfiles,
      csvCustomers: csvCustomers,
      csvTransactions: csvTransactions,
      csvMetadata: csvMetadata,
      csvPreferences: csvPrefs,
    );
  }

  static Future<int> replaceAllDataFromCsv(
    Isar isar,
    String csv, {
    Map<String, String>? mediaPathMap,
  }) async {
    await isar.writeTxn(() async {
      await isar.transactions.clear();
      await isar.customers.clear();
      await isar.businessProfiles.clear();
      await isar.appMetadatas.clear();
    });

    final prefs = await SharedPreferences.getInstance();
    for (final key in _prefKeys) {
      await prefs.remove(key);
    }
    final dynamicKeys = prefs.getKeys();
    for (final key in dynamicKeys) {
      if (key.startsWith('customer_profile_photo_')) {
        await prefs.remove(key);
      }
    }

    return importAllDataFromCsv(isar, csv, mediaPathMap: mediaPathMap);
  }

  static Future<String> exportAllData(Isar isar) async {
    final content = await _buildCsvContent(isar);
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    return _saveBytesToUser(
      bytes: Uint8List.fromList(utf8.encode(content)),
      baseName: '$_filePrefix-$timestamp',
      extension: 'csv',
      mimeType: 'text/csv',
    );
  }

  static Future<String> _buildCsvContent(
    Isar isar, {
    Map<String, String>? mediaAliasByPath,
  }) async {
    final profiles = await isar.businessProfiles.where().findAll();
    final customers = await isar.customers.where().findAll();
    final transactions = await isar.transactions.where().findAll();
    final metadata = await isar.appMetadatas.where().findAll();
    final prefs = await SharedPreferences.getInstance();

    final lines = <String>[
      'section,primary_key,id,profile_id,customer_id,type_or_name,amount_or_phone,note_or_extra,photo_path,photo_paths_json,date,is_deleted,is_edited,created_at,updated_at',
    ];

    for (final profile in profiles) {
      lines.add(
        _csvRow([
          'profile',
          profile.uuid,
          profile.id.toString(),
          profile.name,
          profile.createdAt.toIso8601String(),
          profile.updatedAt.toIso8601String(),
        ]),
      );
    }

    for (final customer in customers) {
      lines.add(
        _csvRow([
          'customer',
          customer.uuid,
          customer.id.toString(),
          customer.profileId.toString(),
          customer.name,
          customer.phone ?? '',
          customer.note ?? '',
          customer.currentBalance.toString(),
          customer.isDeleted ? '1' : '0',
          customer.createdAt.toIso8601String(),
          customer.updatedAt.toIso8601String(),
        ]),
      );
    }

    for (final tx in transactions) {
      final mappedPhotoPath = _mapMediaPath(tx.photoPath, mediaAliasByPath);
      final mappedPhotoPaths = tx.photoPaths
          .map((path) => _mapMediaPath(path, mediaAliasByPath) ?? path)
          .toList();

      lines.add(
        _csvRow([
          'transaction',
          tx.uuid,
          tx.id.toString(),
          tx.profileId.toString(),
          tx.customerId.toString(),
          tx.type.name,
          tx.amount.toString(),
          tx.note ?? '',
          mappedPhotoPath ?? '',
          jsonEncode(mappedPhotoPaths),
          tx.date.toIso8601String(),
          tx.isDeleted ? '1' : '0',
          tx.isEdited ? '1' : '0',
          tx.createdAt.toIso8601String(),
          tx.updatedAt.toIso8601String(),
        ]),
      );
    }

    for (final customer in customers) {
      final key = 'customer_profile_photo_${customer.profileId}_${customer.id}';
      final photoPath = prefs.getString(key);
      if (photoPath == null || photoPath.trim().isEmpty) continue;

      final mapped = _mapMediaPath(photoPath, mediaAliasByPath) ?? photoPath;
      lines.add(
        _csvRow([
          'profile_photo',
          '${customer.profileId}:${customer.id}',
          customer.profileId.toString(),
          customer.id.toString(),
          mapped,
        ]),
      );
    }

    for (final item in metadata) {
      lines.add(_csvRow(['metadata', item.key, item.value ?? '']));
    }

    for (final key in _prefKeys) {
      if (!prefs.containsKey(key)) continue;
      final value = prefs.get(key);
      lines.add(_csvRow(['preference', key, value?.toString() ?? '']));
    }

    return lines.join('\n');
  }

  static Future<int> importAllDataFromPicker(Isar isar) async {
    final content = await pickCsvContentFromPicker();
    if (content == null || content.trim().isEmpty) {
      return 0;
    }
    return importAllDataFromCsv(isar, content);
  }

  static Future<int> importAllDataFromCsv(
    Isar isar,
    String csv, {
    Map<String, String>? mediaPathMap,
  }) async {
    final rows = _parseCsv(csv);
    if (rows.length <= 1) {
      return 0;
    }

    final profileIdMap = <int, int>{};
    final customerIdMap = <int, int>{};

    int importedCount = 0;

    await isar.writeTxn(() async {
      for (var i = 1; i < rows.length; i++) {
        final row = rows[i];
        if (row.isEmpty) continue;

        final section = _field(row, 0);
        final uuid = _field(row, 1);
        if (section.isEmpty || uuid.isEmpty) continue;

        if (section == 'profile') {
          final backupId = int.tryParse(_field(row, 2)) ?? 0;
          final existing = await isar.businessProfiles
              .filter()
              .uuidEqualTo(uuid)
              .findFirst();

          final profile = existing ?? BusinessProfile()
            ..uuid = uuid;
          profile.name = _field(row, 3);
          profile.createdAt = _parseDate(_field(row, 4)) ?? profile.createdAt;
          profile.updatedAt = _parseDate(_field(row, 5)) ?? DateTime.now();

          final id = await isar.businessProfiles.put(profile);
          if (backupId > 0) {
            profileIdMap[backupId] = id;
          }
          importedCount++;
        }
      }

      for (var i = 1; i < rows.length; i++) {
        final row = rows[i];
        if (row.isEmpty) continue;

        final section = _field(row, 0);
        final uuid = _field(row, 1);
        if (section != 'customer' || uuid.isEmpty) continue;

        final backupId = int.tryParse(_field(row, 2)) ?? 0;
        final backupProfileId = int.tryParse(_field(row, 3)) ?? 0;
        final mappedProfileId =
            profileIdMap[backupProfileId] ?? backupProfileId;

        final existing = await isar.customers
            .filter()
            .uuidEqualTo(uuid)
            .findFirst();
        final customer = existing ?? Customer()
          ..uuid = uuid;

        customer.profileId = mappedProfileId;
        customer.name = _field(row, 4);
        customer.phone = _nullIfEmpty(_field(row, 5));
        customer.note = _nullIfEmpty(_field(row, 6));
        customer.currentBalance = double.tryParse(_field(row, 7)) ?? 0;
        customer.isDeleted = _field(row, 8) == '1';
        customer.createdAt = _parseDate(_field(row, 9)) ?? customer.createdAt;
        customer.updatedAt = _parseDate(_field(row, 10)) ?? DateTime.now();

        final id = await isar.customers.put(customer);
        if (backupId > 0) {
          customerIdMap[backupId] = id;
        }
        importedCount++;
      }

      for (var i = 1; i < rows.length; i++) {
        final row = rows[i];
        if (row.isEmpty) continue;

        final section = _field(row, 0);
        final uuid = _field(row, 1);
        if (section != 'transaction' || uuid.isEmpty) continue;

        final backupProfileId = int.tryParse(_field(row, 3)) ?? 0;
        final backupCustomerId = int.tryParse(_field(row, 4)) ?? 0;

        final mappedProfileId =
            profileIdMap[backupProfileId] ?? backupProfileId;
        final mappedCustomerId =
            customerIdMap[backupCustomerId] ?? backupCustomerId;

        final existing = await isar.transactions
            .filter()
            .uuidEqualTo(uuid)
            .findFirst();
        final tx = existing ?? txn_model.Transaction()
          ..uuid = uuid;

        tx.profileId = mappedProfileId;
        tx.customerId = mappedCustomerId;
        tx.type = _field(row, 5) == TransactionType.debit.name
            ? TransactionType.debit
            : TransactionType.credit;
        tx.amount = double.tryParse(_field(row, 6)) ?? 0;
        tx.note = _nullIfEmpty(_field(row, 7));
        tx.photoPath = _resolveMediaPath(_nullIfEmpty(_field(row, 8)), mediaPathMap);
        tx.photoPaths = _parsePhotoPaths(_field(row, 9))
          .map((path) => _resolveMediaPath(path, mediaPathMap) ?? path)
          .toList();
        tx.date = _parseDate(_field(row, 10)) ?? DateTime.now();
        tx.isDeleted = _field(row, 11) == '1';
        tx.isEdited = _field(row, 12) == '1';
        tx.createdAt = _parseDate(_field(row, 13)) ?? tx.createdAt;
        tx.updatedAt = _parseDate(_field(row, 14)) ?? DateTime.now();

        await isar.transactions.put(tx);
        importedCount++;
      }

      for (var i = 1; i < rows.length; i++) {
        final row = rows[i];
        if (row.isEmpty) continue;

        final section = _field(row, 0);
        final key = _field(row, 1);
        if (section != 'metadata' || key.isEmpty) continue;

        final existing = await isar.appMetadatas
            .filter()
            .keyEqualTo(key)
            .findFirst();
        final meta = existing ?? AppMetadata()
          ..key = key;
        meta.value = _nullIfEmpty(_field(row, 2));

        await isar.appMetadatas.put(meta);
        importedCount++;
      }

      final prefs = await SharedPreferences.getInstance();
      for (var i = 1; i < rows.length; i++) {
        final row = rows[i];
        if (row.isEmpty) continue;

        final section = _field(row, 0);
        final key = _field(row, 1);
        final value = _field(row, 2);
        if (section != 'preference' || key.isEmpty) continue;

        switch (key) {
          case 'currencyCode':
          case 'transactionLabelStyle':
            await prefs.setString(key, value);
            importedCount++;
            break;
          case 'isDarkMode':
          case 'appLockEnabled':
            final boolValue = _parseBool(value);
            if (boolValue != null) {
              await prefs.setBool(key, boolValue);
              importedCount++;
            }
            break;
        }
      }

      for (var i = 1; i < rows.length; i++) {
        final row = rows[i];
        if (row.isEmpty) continue;

        final section = _field(row, 0);
        if (section != 'profile_photo') continue;

        final backupProfileId = int.tryParse(_field(row, 2)) ?? 0;
        final backupCustomerId = int.tryParse(_field(row, 3)) ?? 0;
        final mappedProfileId = profileIdMap[backupProfileId] ?? backupProfileId;
        final mappedCustomerId = customerIdMap[backupCustomerId] ?? backupCustomerId;
        final resolvedPath = _resolveMediaPath(_field(row, 4), mediaPathMap);

        if (resolvedPath == null || resolvedPath.trim().isEmpty) continue;
        final key = 'customer_profile_photo_${mappedProfileId}_$mappedCustomerId';
        await prefs.setString(key, resolvedPath);
        importedCount++;
      }
    });

    return importedCount;
  }

  static String _csvRow(List<String> fields) {
    return fields.map(_escapeCsv).join(',');
  }

  static String _escapeCsv(String value) {
    final escaped = value.replaceAll('"', '""');
    return '"$escaped"';
  }

  static List<List<String>> _parseCsv(String input) {
    final rows = <List<String>>[];
    final row = <String>[];
    final cell = StringBuffer();
    var inQuotes = false;

    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      final next = i + 1 < input.length ? input[i + 1] : '';

      if (ch == '"') {
        if (inQuotes && next == '"') {
          cell.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (ch == ',' && !inQuotes) {
        row.add(cell.toString());
        cell.clear();
      } else if ((ch == '\n' || ch == '\r') && !inQuotes) {
        if (ch == '\r' && next == '\n') {
          i++;
        }
        row.add(cell.toString());
        cell.clear();
        if (row.any((e) => e.isNotEmpty)) {
          rows.add(List<String>.from(row));
        }
        row.clear();
      } else {
        cell.write(ch);
      }
    }

    row.add(cell.toString());
    if (row.any((e) => e.isNotEmpty)) {
      rows.add(List<String>.from(row));
    }

    return rows;
  }

  static String _field(List<String> row, int index) {
    if (index < 0 || index >= row.length) return '';
    return row[index].trim();
  }

  static DateTime? _parseDate(String value) {
    if (value.trim().isEmpty) return null;
    return DateTime.tryParse(value.trim());
  }

  static String? _nullIfEmpty(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static List<String> _parsePhotoPaths(String value) {
    if (value.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(value);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
    } catch (_) {}
    return [];
  }

  static bool? _parseBool(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'true' || normalized == '1') return true;
    if (normalized == 'false' || normalized == '0') return false;
    return null;
  }

  static String? _mapMediaPath(
    String? path,
    Map<String, String>? mediaAliasByPath,
  ) {
    if (path == null || path.trim().isEmpty) return null;
    if (mediaAliasByPath == null || mediaAliasByPath.isEmpty) return path;
    return mediaAliasByPath[path] ?? path;
  }

  static String? _resolveMediaPath(
    String? path,
    Map<String, String>? mediaPathMap,
  ) {
    if (path == null || path.trim().isEmpty) return null;
    if (mediaPathMap == null || mediaPathMap.isEmpty) return path;
    return mediaPathMap[path] ?? path;
  }

  static Future<String> _saveBytesToUser({
    required Uint8List bytes,
    required String baseName,
    required String extension,
    required String mimeType,
  }) async {
    final fileName = '$baseName.$extension';

    if (Platform.isAndroid) {
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/$fileName');
      await tempFile.writeAsBytes(bytes, flush: true);

      String? savedUri;
      try {
        savedUri = await _fileOpsChannel.invokeMethod<String>(
          'saveFileToDownloads',
          {
            'sourceFilePath': tempFile.path,
            'fileName': fileName,
            'mimeType': mimeType,
          },
        );
      } on MissingPluginException {
        try {
          savedUri = await _legacyFileOpsChannel.invokeMethod<String>(
            'saveFileToDownloads',
            {
              'sourceFilePath': tempFile.path,
              'fileName': fileName,
              'mimeType': mimeType,
            },
          );
        } on MissingPluginException {
          savedUri = null;
        }
      } finally {
        try {
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
        } catch (_) {}
      }

      if (savedUri != null && savedUri.isNotEmpty) {
        return savedUri;
      }
    }

    return FileSaver.instance.saveFile(
      name: baseName,
      bytes: bytes,
      fileExtension: extension,
      mimeType: extension == 'csv' ? MimeType.csv : MimeType.other,
    );
  }

  static String _extractCsvFromZipBytes(Uint8List zipBytes) {
    final archive = ZipDecoder().decodeBytes(zipBytes, verify: true);
    for (final file in archive.files) {
      if (!file.isFile) continue;
      if (file.name == _csvEntryName) {
        final data = file.content as List<int>;
        return utf8.decode(data);
      }
    }
    throw Exception('Invalid backup ZIP: backup.csv not found');
  }

  static Future<_ZipPayload> _extractZipPayload(Uint8List zipBytes) async {
    final archive = ZipDecoder().decodeBytes(zipBytes, verify: true);
    String? csv;
    final mediaPathMap = <String, String>{};

    final appDir = await getApplicationDocumentsDirectory();
    final mediaRoot = Directory(
      '${appDir.path}/backup_media/${DateTime.now().microsecondsSinceEpoch}',
    );
    if (!mediaRoot.existsSync()) {
      mediaRoot.createSync(recursive: true);
    }

    for (final file in archive.files) {
      if (!file.isFile) continue;

      if (file.name == _csvEntryName) {
        final data = file.content as List<int>;
        csv = utf8.decode(data);
        continue;
      }

      if (!file.name.startsWith('$_mediaFolderName/')) {
        continue;
      }

      final relative = file.name.substring('$_mediaFolderName/'.length);
      if (relative.trim().isEmpty) continue;

      final outputFile = File('${mediaRoot.path}/$relative');
      outputFile.parent.createSync(recursive: true);

      final data = file.content as List<int>;
      outputFile.writeAsBytesSync(data, flush: true);
      mediaPathMap[file.name] = outputFile.path;
    }

    if (csv == null || csv.trim().isEmpty) {
      throw Exception('Invalid backup ZIP: backup.csv not found');
    }

    return _ZipPayload(csv: csv, mediaPathMap: mediaPathMap);
  }

  static Future<Map<String, String>> _collectMediaAliasByPath(Isar isar) async {
    final transactions = await isar.transactions.where().findAll();
    final customers = await isar.customers.where().findAll();
    final prefs = await SharedPreferences.getInstance();

    final sourcePaths = <String>{};

    void addMedia(String? rawPath) {
      if (rawPath == null || rawPath.trim().isEmpty) return;
      final source = rawPath.trim();

      final file = File(source);
      if (!file.existsSync()) return;
      sourcePaths.add(source);
    }

    for (final tx in transactions) {
      addMedia(tx.photoPath);
      for (final path in tx.photoPaths) {
        addMedia(path);
      }
    }

    for (final customer in customers) {
      final key = 'customer_profile_photo_${customer.profileId}_${customer.id}';
      addMedia(prefs.getString(key));
    }

    final sortedSources = sourcePaths.toList()..sort();
    final mediaAliasByPath = <String, String>{};
    var mediaCounter = 1;
    for (final source in sortedSources) {
      final fileName = source.split(Platform.pathSeparator).last;
      final safeName = fileName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      mediaAliasByPath[source] = '$_mediaFolderName/${mediaCounter}_$safeName';
      mediaCounter++;
    }

    return mediaAliasByPath;
  }

  static Future<_BackupPayload> _buildSmartBackupPayload(Isar isar) async {
    final mediaAliasByPath = await _collectMediaAliasByPath(isar);
    final csv = await _buildCsvContent(isar, mediaAliasByPath: mediaAliasByPath);
    final zipBytes = await _buildZipBytes(csv, mediaAliasByPath);
    final contentHash = _fingerprintCsvAndMedia(csv, mediaAliasByPath);
    return _BackupPayload(
      type: BackupFileType.zip,
      bytes: zipBytes,
      extension: 'zip',
      mimeType: 'application/zip',
      contentHash: contentHash,
    );
  }

  static Future<Uint8List> _buildZipBytes(
    String csv,
    Map<String, String> mediaAliasByPath,
  ) async {
    final archive = Archive();
    final csvBytes = Uint8List.fromList(utf8.encode(csv));
    archive.addFile(ArchiveFile(_csvEntryName, csvBytes.length, csvBytes));

    final sortedEntries = mediaAliasByPath.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));

    for (final entry in sortedEntries) {
      final file = File(entry.key);
      if (!file.existsSync()) continue;
      final bytes = file.readAsBytesSync();
      archive.addFile(ArchiveFile(entry.value, bytes.length, bytes));
    }

    final zipBytes = ZipEncoder().encode(archive);
    if (zipBytes == null) {
      throw Exception('Failed to create ZIP backup');
    }
    return Uint8List.fromList(zipBytes);
  }

  static Future<String> _saveBytesToDirectory({
    required Uint8List bytes,
    required String directoryPath,
    required String baseName,
    required String extension,
  }) async {
    final directory = Directory(directoryPath);
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }

    final targetFile = File('${directory.path}/$baseName.$extension');
    await targetFile.writeAsBytes(bytes, flush: true);
    return targetFile.path;
  }

  static int _normalizeAutoBackupFileCount(int? count) {
    final value = count ?? _defaultAutoBackupFiles;
    if (value < _minAutoBackupFiles) return _minAutoBackupFiles;
    if (value > _maxAutoBackupFiles) return _maxAutoBackupFiles;
    return value;
  }

  static Future<void> pruneAutoBackupsNow({
    required String directoryPath,
  }) async {
    final settings = await getAutoBackupSettings();
    await _enforceAutoBackupRetention(
      directoryPath,
      settings.maxAutoBackupFiles,
    );
  }

  static Future<void> _enforceAutoBackupRetention(
    String directoryPath,
    int maxFiles,
  ) async {
    final normalizedMax = _normalizeAutoBackupFileCount(maxFiles);
    final directory = Directory(directoryPath);
    if (!directory.existsSync()) return;

    final files = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.isNotEmpty
          ? entity.uri.pathSegments.last
          : entity.path.split(Platform.pathSeparator).last;
      if (_isManagedBackupFileName(name)) {
        files.add(entity);
      }
    }

    if (files.length <= normalizedMax) return;

    final fileWithModified = await Future.wait(
      files.map((file) async {
        DateTime modified;
        try {
          modified = await file.lastModified();
        } catch (_) {
          modified = DateTime.fromMillisecondsSinceEpoch(0);
        }
        return (file: file, modified: modified);
      }),
    );

    fileWithModified.sort((a, b) {
      final cmp = a.modified.compareTo(b.modified);
      if (cmp != 0) return cmp;
      return a.file.path.compareTo(b.file.path);
    });

    final deleteCount = fileWithModified.length - normalizedMax;
    for (var index = 0; index < deleteCount; index++) {
      try {
        await fileWithModified[index].file.delete();
      } catch (_) {}
    }
  }

  static bool _isManagedBackupFileName(String fileName) {
    final lower = fileName.trim().toLowerCase();
    final isCsv = lower.endsWith('.csv');
    final isZip = lower.endsWith('.zip');
    if (!isCsv && !isZip) return false;

    final startsWithCsvPrefix = lower.startsWith(_filePrefix);
    final startsWithZipPrefix = lower.startsWith(_zipPrefix);
    return startsWithCsvPrefix || startsWithZipPrefix;
  }

  static String _fingerprintCsvAndMedia(
    String csv,
    Map<String, String> mediaAliasByPath,
  ) {
    var hash = 0xcbf29ce484222325;
    const prime = 0x100000001b3;

    void addBytes(List<int> bytes) {
      for (final byte in bytes) {
        hash ^= byte;
        hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF;
      }
    }

    void addString(String value) {
      addBytes(utf8.encode(value));
      addBytes(const [0]);
    }

    addString('csv');
    addBytes(utf8.encode(csv));
    addBytes(const [255]);

    final sortedEntries = mediaAliasByPath.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));

    for (final entry in sortedEntries) {
      final file = File(entry.key);
      if (!file.existsSync()) continue;
      addString(entry.value);
      addBytes(file.readAsBytesSync());
      addBytes(const [254]);
    }

    return hash.toRadixString(16).padLeft(16, '0');
  }

}

class _ZipPayload {
  final String csv;
  final Map<String, String> mediaPathMap;

  const _ZipPayload({required this.csv, required this.mediaPathMap});
}

class _BackupPayload {
  final BackupFileType type;
  final Uint8List bytes;
  final String extension;
  final String mimeType;
  final String contentHash;

  const _BackupPayload({
    required this.type,
    required this.bytes,
    required this.extension,
    required this.mimeType,
    required this.contentHash,
  });
}

class CsvImportDiff {
  final int currentProfiles;
  final int currentCustomers;
  final int currentTransactions;
  final int currentMetadata;
  final int currentPreferences;

  final int csvProfiles;
  final int csvCustomers;
  final int csvTransactions;
  final int csvMetadata;
  final int csvPreferences;

  const CsvImportDiff({
    required this.currentProfiles,
    required this.currentCustomers,
    required this.currentTransactions,
    required this.currentMetadata,
    required this.currentPreferences,
    required this.csvProfiles,
    required this.csvCustomers,
    required this.csvTransactions,
    required this.csvMetadata,
    required this.csvPreferences,
  });
}

class ProfileCustomerImportResult {
  final int customersImported;
  final int transactionsImported;

  const ProfileCustomerImportResult({
    required this.customersImported,
    required this.transactionsImported,
  });
}

class CustomerImportConflict {
  final String importKey;
  final String incomingName;
  final int existingCustomerId;
  final String existingName;
  final CustomerImportConflictType type;

  const CustomerImportConflict({
    required this.importKey,
    required this.incomingName,
    required this.existingCustomerId,
    required this.existingName,
    required this.type,
  });
}

enum CustomerImportConflictType {
  sameNameDifferentCustomer,
  sameCustomer,
}

class _ImportCustomerEntry {
  final String key;
  final String name;
  final String? sourceCustomerUuid;
  final Set<String> transactionUuids;

  const _ImportCustomerEntry({
    required this.key,
    required this.name,
    this.sourceCustomerUuid,
    this.transactionUuids = const <String>{},
  });
}

class _ImportCustomerEntryBuilder {
  final String key;
  String name = '';
  String? sourceCustomerUuid;
  final Set<String> transactionUuids = <String>{};

  _ImportCustomerEntryBuilder({required this.key});

  void addTransactionUuid(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return;
    transactionUuids.add(normalized);
  }

  _ImportCustomerEntry build() {
    return _ImportCustomerEntry(
      key: key,
      name: name,
      sourceCustomerUuid: sourceCustomerUuid,
      transactionUuids: transactionUuids,
    );
  }
}
