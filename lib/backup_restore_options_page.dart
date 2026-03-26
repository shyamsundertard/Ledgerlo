import 'package:file_picker/file_picker.dart';
import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:isar/isar.dart';
import 'package:permission_handler/permission_handler.dart';

import 'core/backup/csv_backup_service.dart';

class BackupRestoreOptionsPage extends StatefulWidget {
  final Isar isar;
  const BackupRestoreOptionsPage({super.key, required this.isar});

  @override
  State<BackupRestoreOptionsPage> createState() =>
      _BackupRestoreOptionsPageState();
}

class _BackupRestoreOptionsPageState extends State<BackupRestoreOptionsPage> {
  String? _autoBackupDirectory;
  AutoBackupFrequency _autoBackupFrequency = AutoBackupFrequency.manual;
  int _maxAutoBackupFiles = 7;
  int _backupHour = 2;
  int _backupMinute = 0;
  DateTime? _lastAutoBackupAt;
  String? _lastAutoBackupStatus;
  DateTime? _lastAutoBackupStatusAt;
  bool _isConfigLoading = true;
  StreamSubscription<void>? _autoBackupStateSubscription;

  @override
  void initState() {
    super.initState();
    _autoBackupStateSubscription = CsvBackupService.autoBackupStateStream
        .listen((_) {
          _loadAutoBackupSettings();
        });
    _loadAutoBackupSettings();
  }

  @override
  void dispose() {
    _autoBackupStateSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadAutoBackupSettings() async {
    final settings = await CsvBackupService.getAutoBackupSettings();
    if (!mounted) return;
    setState(() {
      _autoBackupDirectory = settings.directoryPath;
      _autoBackupFrequency = settings.frequency;
      _maxAutoBackupFiles = settings.maxAutoBackupFiles;
      _backupHour = settings.backupHour;
      _backupMinute = settings.backupMinute;
      _lastAutoBackupAt = settings.lastBackupAt;
      _lastAutoBackupStatus = settings.lastStatus;
      _lastAutoBackupStatusAt = settings.lastStatusAt;
      _isConfigLoading = false;
    });
  }

  bool get _isAutoBackupEnabled =>
      _autoBackupFrequency != AutoBackupFrequency.manual;

  TimeOfDay get _backupTime =>
      TimeOfDay(hour: _backupHour, minute: _backupMinute);

  String _backupTimeLabel(BuildContext context) => _backupTime.format(context);

  String _lastBackupLabel() {
    final last = _lastAutoBackupAt;
    if (last == null) return 'Never';
    return DateFormat('dd MMM yyyy, hh:mm a').format(last);
  }

  String _lastAutoStateLabel() {
    final status = _lastAutoBackupStatus;
    if (status == null || status.trim().isEmpty) {
      return _lastBackupLabel();
    }

    final statusAt = _lastAutoBackupStatusAt;
    if (statusAt == null) return status;
    final formattedAt = DateFormat('dd MMM yyyy, hh:mm a').format(statusAt);
    return '$status at $formattedAt';
  }

  String get _directorySubtitle {
    final path = _autoBackupDirectory;
    if (path == null || path.trim().isEmpty) {
      return 'No folder selected';
    }
    return path;
  }

  bool get _hasDirectory {
    final path = _autoBackupDirectory;
    return path != null && path.trim().isNotEmpty;
  }

  Future<void> _chooseAutoBackupDirectory() async {
    final selected = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose backup folder',
    );
    if (selected == null || selected.trim().isEmpty) return;

    if (!await _ensureAndroidStoragePermissionForPath(selected)) {
      if (!mounted) return;
      await _showMessageDialog(
        context,
        title: 'Storage Access Required',
        message:
            'To use this folder for automatic backup, please grant "All files access" for this app in Android settings and then select the folder again.',
      );
      return;
    }

    try {
      await CsvBackupService.validateAutoBackupDirectoryWritable(selected);
    } catch (error) {
      if (!mounted) return;
      await _showMessageDialog(
        context,
        title: 'Folder Not Supported',
        message:
            'Selected folder cannot be used for automatic backup on this device.\n$error',
      );
      return;
    }

    await CsvBackupService.setAutoBackupDirectory(selected);
    if (!mounted) return;
    setState(() {
      _autoBackupDirectory = selected;
    });
  }

  Future<bool> _ensureAndroidStoragePermissionForPath(String path) async {
    if (Theme.of(context).platform != TargetPlatform.android) {
      return true;
    }

    final normalized = path.trim();
    if (!normalized.startsWith('/storage/')) {
      return true;
    }

    final status = await Permission.manageExternalStorage.status;
    if (status.isGranted) {
      return true;
    }

    final requested = await Permission.manageExternalStorage.request();
    return requested.isGranted;
  }

  Future<void> _setAutoBackupEnabled(bool enabled) async {
    if (enabled && !_hasDirectory) {
      await _showMessageDialog(
        context,
        title: 'Select Backup Folder',
        message: 'Choose a backup folder first, then enable automatic backup.',
      );
      return;
    }

    if (enabled && !await _ensureNotificationPermissionForAutoBackup()) {
      if (!mounted) return;
      await _showMessageDialog(
        context,
        title: 'Notification Access Recommended',
        message:
            'Automatic backup is enabled, but notification permission is denied. Backup status notifications may not appear until permission is granted in system settings.',
      );
    }

    final next = enabled
        ? AutoBackupFrequency.daily
        : AutoBackupFrequency.manual;
    await CsvBackupService.setAutoBackupFrequency(next);
    if (!mounted) return;
    setState(() {
      _autoBackupFrequency = next;
    });
  }

  Future<void> _pickBackupTime() async {
    final now = DateTime.now();
    var selectedDateTime = DateTime(
      now.year,
      now.month,
      now.day,
      _backupHour,
      _backupMinute,
    );

    final picked = await showModalBottomSheet<DateTime>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: SizedBox(
            height: 320,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Cancel'),
                      ),
                      const Text('Select Time'),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, selectedDateTime),
                        child: const Text('Done'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: CupertinoDatePicker(
                    mode: CupertinoDatePickerMode.time,
                    use24hFormat: false,
                    initialDateTime: selectedDateTime,
                    onDateTimeChanged: (value) {
                      selectedDateTime = value;
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (picked == null) return;

    await CsvBackupService.setAutoBackupTime(
      hour: picked.hour,
      minute: picked.minute,
    );
    if (!mounted) return;
    setState(() {
      _backupHour = picked.hour;
      _backupMinute = picked.minute;
    });
  }

  Future<void> _setAutoBackupMaxFiles(int value) async {
    final normalized = value < 3 ? 3 : value;
    await CsvBackupService.setAutoBackupMaxFiles(normalized);

    final directory = _autoBackupDirectory;
    if (directory != null && directory.trim().isNotEmpty) {
      try {
        await CsvBackupService.pruneAutoBackupsNow(directoryPath: directory);
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      _maxAutoBackupFiles = normalized;
    });
  }

  Future<bool> _ensureNotificationPermissionForAutoBackup() async {
    final platform = Theme.of(context).platform;
    if (platform != TargetPlatform.android && platform != TargetPlatform.iOS) {
      return true;
    }

    final status = await Permission.notification.status;
    if (status.isGranted) {
      return true;
    }

    final requested = await Permission.notification.request();
    return requested.isGranted;
  }

  Future<void> _showMessageDialog(
    BuildContext context, {
    required String title,
    required String message,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportSmartBackup() async {
    final pageContext = context;
    if (!_hasDirectory) {
      if (!pageContext.mounted) return;
      await _showMessageDialog(
        pageContext,
        title: 'Select Backup Folder',
        message: 'Please select a backup folder before creating a backup.',
      );
      await _chooseAutoBackupDirectory();
      if (!pageContext.mounted) return;
      if (!_hasDirectory) {
        return;
      }
    }

    if (!pageContext.mounted) return;
    final confirmed =
        await showDialog<bool>(
          context: pageContext,
          builder: (ctx) => AlertDialog(
            title: const Text('Create Backup?'),
            content: const Text(
              'Backup will be saved in your selected backup folder as a ZIP file. Continue?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Backup'),
              ),
            ],
          ),
        ) ??
        false;

    if (!pageContext.mounted) return;
    if (!confirmed) return;

    try {
      final result =
          await CsvBackupService.exportSmartBackupToSelectedFolderIfChanged(
            widget.isar,
          );
      if (!pageContext.mounted) return;

      if (result.outcome == ManualBackupOutcome.missingFolder) {
        if (!pageContext.mounted) return;
        await _showMessageDialog(
          pageContext,
          title: 'Backup Folder Required',
          message: 'Please select a backup folder to continue.',
        );
        return;
      }

      if (result.outcome == ManualBackupOutcome.skippedNoChanges) {
        if (!pageContext.mounted) return;
        await _showMessageDialog(
          pageContext,
          title: 'No Changes Detected',
          message:
              'Backup was not created because there are no changes since the last backup.',
        );
        return;
      }

      final format = 'ZIP';
      final savedPath = result.savedPath ?? '';
      if (!pageContext.mounted) return;
      await _showMessageDialog(
        pageContext,
        title: 'Backup Complete',
        message: savedPath.isEmpty
            ? '$format backup exported successfully.'
            : '$format backup exported successfully:\n$savedPath',
      );
      await _loadAutoBackupSettings();
    } catch (e) {
      if (!pageContext.mounted) return;
      await _showMessageDialog(
        pageContext,
        title: 'Backup Failed',
        message: 'Could not create backup.\n$e',
      );
    }
  }

  Future<void> _restoreBackup(BuildContext context) async {
    try {
      final file = await CsvBackupService.pickRestoreBackupFromPicker(
        initialDirectory: _autoBackupDirectory,
      );
      if (file == null) {
        if (!context.mounted) return;
        await _showMessageDialog(
          context,
          title: 'Restore Canceled',
          message: 'No backup file selected.',
        );
        return;
      }

      final diff = await CsvBackupService.buildRestoreDiffFromBackup(
        widget.isar,
        file,
      );
      if (!context.mounted) return;

      final format = file.type == BackupFileType.zip ? 'ZIP' : 'CSV';

      final confirmed =
          await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Replace Existing Data?'),
              content: SingleChildScrollView(
                child: Text(
                  'Current data:\n'
                  '• Profiles: ${diff.currentProfiles}\n'
                  '• Customers: ${diff.currentCustomers}\n'
                  '• Transactions: ${diff.currentTransactions}\n'
                  '• Metadata: ${diff.currentMetadata}\n'
                  '• Preferences: ${diff.currentPreferences}\n\n'
                  'Backup file data:\n'
                  '• Profiles: ${diff.csvProfiles}\n'
                  '• Customers: ${diff.csvCustomers}\n'
                  '• Transactions: ${diff.csvTransactions}\n'
                  '• Metadata: ${diff.csvMetadata}\n'
                  '• Preferences: ${diff.csvPreferences}\n\n'
                  'This will delete all existing app data and replace it with $format backup data.',
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.error,
                    foregroundColor: Theme.of(ctx).colorScheme.onError,
                  ),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Replace Data'),
                ),
              ],
            ),
          ) ??
          false;

      if (!confirmed) {
        return;
      }
      if (!context.mounted) return;

      final finalConfirmed =
          await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Final Confirmation'),
              content: Text(
                'This will permanently delete current app data and replace it with $format backup data. This action cannot be undone. Continue?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Back'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.error,
                    foregroundColor: Theme.of(ctx).colorScheme.onError,
                  ),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Yes, Replace'),
                ),
              ],
            ),
          ) ??
          false;

      if (!finalConfirmed) {
        return;
      }

      final imported = await CsvBackupService.restoreAllDataFromBackup(
        widget.isar,
        file,
      );
      if (!context.mounted) return;

      if (imported == 0) {
        await _showMessageDialog(
          context,
          title: 'Restore Complete',
          message: '$format backup was processed but no rows were imported.',
        );
        return;
      }

      await _showMessageDialog(
        context,
        title: 'Restore Complete',
        message:
            'Imported $imported records from $format backup. Existing data was replaced successfully.',
      );
      await _loadAutoBackupSettings();
    } catch (e) {
      if (!context.mounted) return;
      await _showMessageDialog(
        context,
        title: 'Restore Failed',
        message: 'Could not import backup file.\n$e',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isConfigLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Backup & Restore')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Backup & Restore')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text('Automatic Backup', style: theme.textTheme.titleSmall),
          ),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.autorenew_outlined),
                  title: const Text('Automatic Backup'),
                  subtitle: _isAutoBackupEnabled
                      ? InkWell(
                          onTap: _pickBackupTime,
                          borderRadius: BorderRadius.circular(6),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('Daily at ${_backupTimeLabel(context)}'),
                                const SizedBox(width: 4),
                                const Icon(Icons.edit_outlined, size: 14),
                              ],
                            ),
                          ),
                        )
                      : const Text('Disabled'),
                  trailing: Switch(
                    value: _isAutoBackupEnabled,
                    onChanged: (enabled) async {
                      await _setAutoBackupEnabled(enabled);
                    },
                  ),
                ),
                const Divider(height: 1, indent: 56, endIndent: 12),
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: const Text('Backup Folder'),
                  subtitle: Text(
                    _directorySubtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: _chooseAutoBackupDirectory,
                ),
                if (_isAutoBackupEnabled) ...[
                  const Divider(height: 1, indent: 56, endIndent: 12),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Keep latest automatic backups: $_maxAutoBackupFiles',
                          style: theme.textTheme.bodyMedium,
                        ),
                        Slider(
                          min: 3,
                          max: 30,
                          divisions: 27,
                          value: _maxAutoBackupFiles.toDouble(),
                          label: _maxAutoBackupFiles.toString(),
                          onChanged: (value) {
                            setState(() {
                              _maxAutoBackupFiles = value.round();
                            });
                          },
                          onChangeEnd: (value) async {
                            await _setAutoBackupMaxFiles(value.round());
                          },
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, indent: 56, endIndent: 12),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: Text(
                      'Last automatic backup: ${_lastAutoStateLabel()}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text('Manual Actions', style: theme.textTheme.titleSmall),
          ),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.backup_outlined),
                  title: const Text('Backup Now'),
                  subtitle: const Text('Creates a ZIP file.'),
                  onTap: () async {
                    await _exportSmartBackup();
                  },
                ),
                const Divider(height: 1, indent: 56, endIndent: 12),
                ListTile(
                  leading: const Icon(Icons.restore_outlined),
                  title: const Text('Restore Backup'),
                  subtitle: const Text('Supports both CSV and ZIP files.'),
                  onTap: () async {
                    await _restoreBackup(context);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
