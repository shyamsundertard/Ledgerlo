import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar/isar.dart';
import 'package:local_auth/local_auth.dart';

import 'backup_restore_options_page.dart';
import 'core/backup/csv_backup_service.dart';
import 'core/profile/profile_repository.dart';
import 'customer_ledger/snackbar_manager.dart';
import 'data/models/business_profile.dart';
import 'data/models/customer.dart';
import 'providers/settings_provider.dart';
import 'providers/security_provider.dart';

class SettingsPage extends ConsumerWidget {
  final Isar isar;
  SettingsPage({super.key, required this.isar});

  final List<OverlayEntry> _overlayEntries = [];
  final List<Timer> _overlayTimers = [];

  void _showTopToast(BuildContext context, String message) {
    SnackBarManager.showTopSnackBar(
      context,
      message,
      const Color(0xFFDC2626),
      Icons.error_outline,
      _overlayEntries,
      _overlayTimers,
    );
  }

  Future<bool> _verifyBeforeSecurityToggle(
    BuildContext context, {
    required bool enabling,
  }) async {
    final localAuth = LocalAuthentication();

    try {
      final isSupported = await localAuth.isDeviceSupported();
      final canCheckBiometrics = await localAuth.canCheckBiometrics;

      if (!isSupported && !canCheckBiometrics) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Device authentication is not available on this device.',
              ),
            ),
          );
        }
        return false;
      }

      final didAuthenticate = await localAuth.authenticate(
        localizedReason: enabling
            ? 'Authenticate to enable Secure App Access'
            : 'Authenticate to disable Secure App Access',
        biometricOnly: false,
      );

      if (!didAuthenticate && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Authentication was canceled.')),
        );
      }

      return didAuthenticate;
    } on PlatformException catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message ?? 'Authentication failed.')),
        );
      }
      return false;
    } catch (_) {
      if (context.mounted) {
        _showTopToast(context, 'Authentication failed. Please try again.');
      }
      return false;
    }
  }

  String _normalizeCustomerName(String input) {
    return input.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  }

  Future<void> _importCustomersIntoChosenProfile(BuildContext context) async {
    final profiles = await ProfileRepository.getProfiles(isar);
    if (!context.mounted) return;

    if (profiles.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('No Profiles Found'),
          content: const Text('Create a profile before importing customers.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    BusinessProfile? selectedProfile = profiles.first;
    final profilePicked = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final theme = Theme.of(ctx);
          return AlertDialog(
            title: const Text('Choose Profile'),
            content: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Select the profile where customers should be imported.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: selectedProfile?.id,
                    isExpanded: true,
                    menuMaxHeight: 320,
                    borderRadius: BorderRadius.circular(12),
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                    decoration: InputDecoration(
                      labelText: 'Profile',
                      prefixIcon: const Icon(Icons.business_outlined),
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerHighest
                          .withAlpha((0.35 * 255).round()),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    items: profiles
                        .map(
                          (profile) => DropdownMenuItem<int>(
                            value: profile.id,
                            child: Text(
                              profile.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (selectedId) {
                      final profile = profiles
                          .where((item) => item.id == selectedId)
                          .firstOrNull;
                      setDialogState(() {
                        selectedProfile = profile;
                      });
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Continue'),
              ),
            ],
          );
        },
      ),
    );

    if (!context.mounted) return;
    if (profilePicked != true || selectedProfile == null) return;
    final chosenProfile = selectedProfile!;

    final file = await CsvBackupService.pickRestoreBackupFromPicker();
    if (!context.mounted) return;
    if (file == null) return;

    final conflicts = await CsvBackupService.getCustomerImportConflicts(
      isar,
      targetProfileId: chosenProfile.id,
      file: file,
    );
    if (!context.mounted) return;

    final replaceConflictKeys = <String>{};
    final skipConflictKeys = <String>{};
    final renameByImportKey = <String, String>{};

    if (conflicts.isNotEmpty) {
      final sameNameOnlyConflicts = conflicts
          .where(
            (conflict) =>
                conflict.type ==
                CustomerImportConflictType.sameNameDifferentCustomer,
          )
          .toList();
      final sameCustomerConflicts = conflicts
          .where(
            (conflict) =>
                conflict.type == CustomerImportConflictType.sameCustomer,
          )
          .toList();
      final conflictSummaryLines = <String>[];
      if (sameNameOnlyConflicts.isNotEmpty) {
        conflictSummaryLines.add(
          '- ${sameNameOnlyConflicts.length} conflict(s): same name but different customer (you will rename imported customer).',
        );
      }
      if (sameCustomerConflicts.isNotEmpty) {
        conflictSummaryLines.add(
          '- ${sameCustomerConflicts.length} conflict(s): same customer already exists (you will choose replace or skip).',
        );
      }

      final acknowledged = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Conflicts Found'),
          content: Text(
            'In ${chosenProfile.name}:\n${conflictSummaryLines.join('\n')}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );

      if (!context.mounted) return;
      if (acknowledged != true) return;

      if (sameCustomerConflicts.isNotEmpty) {
        for (final conflict in sameCustomerConflicts) {
          final action = await showDialog<String>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              title: const Text('Same Customer Exists'),
              content: Text(
                'Imported customer "${conflict.incomingName}" matches an existing customer in ${chosenProfile.name}.\n\nChoose an action for this customer.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'cancel'),
                  child: const Text('Cancel Import'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'skip'),
                  child: const Text('Skip Imported'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, 'replace'),
                  child: const Text('Replace Existing'),
                ),
              ],
            ),
          );

          if (!context.mounted) return;
          if (action == null || action == 'cancel') return;

          if (action == 'replace') {
            replaceConflictKeys.add(conflict.importKey);
          } else {
            skipConflictKeys.add(conflict.importKey);
          }
        }
      }

      if (sameNameOnlyConflicts.isNotEmpty) {
        final existingCustomers = await isar.customers
            .filter()
            .profileIdEqualTo(chosenProfile.id)
            .findAll();
        if (!context.mounted) return;
        final takenNames = <String>{
          ...existingCustomers
              .map((customer) => _normalizeCustomerName(customer.name))
              .where((name) => name.isNotEmpty),
        };

        for (final conflict in sameNameOnlyConflicts) {
          final acknowledgedRename = await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              title: const Text('Same Name, Different Customer'),
              content: Text(
                'Another customer with name "${conflict.existingName}" already exists in ${chosenProfile.name}.\n\nPlease rename the imported customer.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel Import'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Rename'),
                ),
              ],
            ),
          );

          if (!context.mounted) return;
          if (acknowledgedRename != true) return;

          final initialText = '${conflict.incomingName} (Imported)';
          var draftName = initialText;

          final resolvedName = await showDialog<String>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) {
              String? errorText;
              return StatefulBuilder(
                builder: (ctx, setDialogState) => AlertDialog(
                  title: const Text('Rename Conflicting Customer'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Imported: ${conflict.incomingName}\nExisting: ${conflict.existingName}',
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        initialValue: initialText,
                        autofocus: true,
                        decoration: InputDecoration(
                          labelText: 'New name',
                          errorText: errorText,
                        ),
                        onChanged: (value) {
                          draftName = value;
                          if (errorText != null) {
                            setDialogState(() => errorText = null);
                          }
                        },
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel Import'),
                    ),
                    FilledButton(
                      onPressed: () {
                        final proposedName = draftName.trim();
                        final normalized = _normalizeCustomerName(proposedName);
                        if (normalized.isEmpty) {
                          setDialogState(() {
                            errorText = 'Name is required';
                          });
                          return;
                        }
                        if (takenNames.contains(normalized)) {
                          setDialogState(() {
                            errorText =
                                'This name already exists in selected profile';
                          });
                          return;
                        }
                        Navigator.pop(ctx, proposedName);
                      },
                      child: const Text('Use Name'),
                    ),
                  ],
                ),
              );
            },
          );

          if (!context.mounted) return;
          if (resolvedName == null) return;

          renameByImportKey[conflict.importKey] = resolvedName;
          takenNames.add(_normalizeCustomerName(resolvedName));
        }
      }
    }

    final fileType = file.type == BackupFileType.zip ? 'ZIP' : 'CSV';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import Customers?'),
        content: Text(
          'Target profile: ${chosenProfile.name}\nFile type: $fileType\n\nThis will add customers and transactions into this profile.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Import'),
          ),
        ],
      ),
    );

    if (!context.mounted) return;
    if (confirmed != true) return;

    try {
      final result =
          await CsvBackupService.importCustomersIntoProfileFromBackup(
            isar,
            targetProfileId: chosenProfile.id,
            file: file,
            replaceConflictKeys: replaceConflictKeys,
            skipConflictKeys: skipConflictKeys,
            renameByImportKey: renameByImportKey,
          );
      if (!context.mounted) return;

      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Import Complete'),
          content: Text(
            'Imported ${result.customersImported} customers and ${result.transactionsImported} transactions into ${chosenProfile.name}.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Import Failed'),
          content: Text('Could not import customers.\n$error'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final labelStyle = ref.watch(settingsProvider);
    final security = ref.watch(securityProvider);

    return Scaffold(
      appBar: AppBar(title: const Text("Settings")),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.label),
            title: const Text("Transaction Labels"),
            subtitle: Text(
              labelStyle == TransactionLabelStyle.creditDebit
                  ? "Credit / Debit"
                  : "Given / Received",
            ),
            onTap: () async {
              await showDialog<TransactionLabelStyle>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Transaction Labels'),
                  contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                        ),
                        title: const Text('Credit / Debit'),
                        subtitle: const Text('Common accounting labels'),
                        trailing:
                            labelStyle == TransactionLabelStyle.creditDebit
                            ? Icon(
                                Icons.check_circle,
                                color: Theme.of(context).colorScheme.primary,
                              )
                            : const Icon(Icons.radio_button_unchecked),
                        onTap: () {
                          Navigator.pop(ctx, TransactionLabelStyle.creditDebit);
                        },
                      ),
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                        ),
                        title: const Text('Given / Received'),
                        subtitle: const Text('Everyday ledger labels'),
                        trailing:
                            labelStyle == TransactionLabelStyle.givenReceived
                            ? Icon(
                                Icons.check_circle,
                                color: Theme.of(context).colorScheme.primary,
                              )
                            : const Icon(Icons.radio_button_unchecked),
                        onTap: () {
                          Navigator.pop(
                            ctx,
                            TransactionLabelStyle.givenReceived,
                          );
                        },
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ).then((selected) async {
                if (selected != null) {
                  await ref
                      .read(settingsProvider.notifier)
                      .setLabelStyle(selected);
                }
              });
            },
          ),
          const Divider(height: 1, indent: 60, endIndent: 12),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('Secure App Access'),
            subtitle: Text(
              security.appLockEnabled
                  ? 'Enabled · Authentication required on app open'
                  : 'Disabled · App opens without authentication',
            ),
            trailing: Transform.scale(
              scale: 1.08,
              child: Switch(
                value: security.appLockEnabled,
                thumbIcon: WidgetStateProperty.resolveWith<Icon?>(
                  (states) => Icon(
                    states.contains(WidgetState.selected)
                        ? Icons.lock
                        : Icons.lock_open,
                    size: 14,
                  ),
                ),
                activeThumbColor: Theme.of(context).colorScheme.onPrimary,
                activeTrackColor: Theme.of(context).colorScheme.primary,
                inactiveThumbColor: Theme.of(context).colorScheme.surface,
                inactiveTrackColor: Theme.of(
                  context,
                ).colorScheme.outlineVariant.withAlpha((0.55 * 255).round()),
                trackOutlineColor: const WidgetStatePropertyAll(
                  Colors.transparent,
                ),
                onChanged: (enabled) async {
                  final isVerified = await _verifyBeforeSecurityToggle(
                    context,
                    enabling: enabled,
                  );
                  if (!isVerified) return;

                  await ref
                      .read(securityProvider.notifier)
                      .setAppLockEnabled(enabled);
                },
              ),
            ),
          ),
          const Divider(height: 1, indent: 60, endIndent: 12),
          ListTile(
            leading: const Icon(Icons.backup_outlined),
            title: const Text('Backup/Restore Options'),
            subtitle: const Text('Smart backup/import (CSV or ZIP)'),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => BackupRestoreOptionsPage(isar: isar),
                ),
              );
            },
          ),
          const Divider(height: 1, indent: 60, endIndent: 12),
          ListTile(
            leading: const Icon(Icons.upload_file_outlined),
            title: const Text('Import Customers (CSV/ZIP)'),
            subtitle: const Text('Choose profile, then import customer data'),
            onTap: () async {
              await _importCustomersIntoChosenProfile(context);
            },
          ),
          const Divider(height: 1, indent: 60, endIndent: 12),
        ],
      ),
    );
  }
}
