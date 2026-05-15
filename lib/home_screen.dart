import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:isar/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:io';

import 'analytics_screen.dart';
import 'menu_screen.dart';
import 'core/enums/transaction_type.dart';
import 'core/profile/profile_repository.dart';
import 'core/widgets/app_logo.dart';
import 'data/models/business_profile.dart';
import 'data/models/customer.dart';
import 'data/models/transaction.dart' as txn_model;
import 'providers/currency_provider.dart';
import 'customer_ledger/snackbar_manager.dart';
import 'customer_ledger/transaction_detail_screen.dart';
import 'customer_ledger_screen.dart';
import 'core/backup/csv_backup_service.dart';
import 'core/backup/backup_notification_service.dart';

enum _CustomerSortOption {
  latestTransactionDesc,
  latestTransactionAsc,
  nameAsc,
  nameDesc,
  balanceDesc,
  balanceAsc,
}

extension on _CustomerSortOption {
  String get label {
    switch (this) {
      case _CustomerSortOption.latestTransactionDesc:
        return 'Latest activity';
      case _CustomerSortOption.latestTransactionAsc:
        return 'Oldest activity';
      case _CustomerSortOption.nameAsc:
        return 'Name A-Z';
      case _CustomerSortOption.nameDesc:
        return 'Name Z-A';
      case _CustomerSortOption.balanceDesc:
        return 'Balance high to low';
      case _CustomerSortOption.balanceAsc:
        return 'Balance low to high';
    }
  }

  String get storageValue {
    switch (this) {
      case _CustomerSortOption.latestTransactionDesc:
        return 'latest_desc';
      case _CustomerSortOption.latestTransactionAsc:
        return 'latest_asc';
      case _CustomerSortOption.nameAsc:
        return 'name_asc';
      case _CustomerSortOption.nameDesc:
        return 'name_desc';
      case _CustomerSortOption.balanceDesc:
        return 'balance_desc';
      case _CustomerSortOption.balanceAsc:
        return 'balance_asc';
    }
  }
}

_CustomerSortOption _customerSortOptionFromStorage(String? value) {
  for (final option in _CustomerSortOption.values) {
    if (option.storageValue == value) return option;
  }
  return _CustomerSortOption.latestTransactionDesc;
}

List<Customer> _sortCustomers(
  Iterable<Customer> customers,
  Iterable<txn_model.Transaction> transactions, {
  required _CustomerSortOption sortOption,
  Map<int, double> balances = const {},
}) {
  final sortedCustomers = customers.toList();
  final latestTransactionByCustomer = <int, DateTime>{};

  for (final tx in transactions) {
    final currentLatest = latestTransactionByCustomer[tx.customerId];
    if (currentLatest == null || tx.date.isAfter(currentLatest)) {
      latestTransactionByCustomer[tx.customerId] = tx.date;
    }
  }

  sortedCustomers.sort((a, b) {
    final latestA = latestTransactionByCustomer[a.id];
    final latestB = latestTransactionByCustomer[b.id];
    final balanceA = balances[a.id] ?? 0;
    final balanceB = balances[b.id] ?? 0;
    final lowerNameA = a.name.toLowerCase();
    final lowerNameB = b.name.toLowerCase();

    int compareLatestDesc() {
      if (latestA != null && latestB != null) {
        final dateComparison = latestB.compareTo(latestA);
        if (dateComparison != 0) return dateComparison;
      } else if (latestA != null) {
        return -1;
      } else if (latestB != null) {
        return 1;
      }
      return 0;
    }

    int compareLatestAsc() {
      if (latestA != null && latestB != null) {
        final dateComparison = latestA.compareTo(latestB);
        if (dateComparison != 0) return dateComparison;
      } else if (latestA != null) {
        return -1;
      } else if (latestB != null) {
        return 1;
      }
      return 0;
    }

    int compareNamesAsc() => lowerNameA.compareTo(lowerNameB);
    int compareNamesDesc() => lowerNameB.compareTo(lowerNameA);

    switch (sortOption) {
      case _CustomerSortOption.latestTransactionDesc:
        final latestComparison = compareLatestDesc();
        if (latestComparison != 0) return latestComparison;
        return compareNamesAsc();
      case _CustomerSortOption.latestTransactionAsc:
        final latestComparison = compareLatestAsc();
        if (latestComparison != 0) return latestComparison;
        return compareNamesAsc();
      case _CustomerSortOption.nameAsc:
        final nameComparison = compareNamesAsc();
        if (nameComparison != 0) return nameComparison;
        return compareLatestDesc();
      case _CustomerSortOption.nameDesc:
        final nameComparison = compareNamesDesc();
        if (nameComparison != 0) return nameComparison;
        return compareLatestDesc();
      case _CustomerSortOption.balanceDesc:
        final balanceComparison = balanceB.compareTo(balanceA);
        if (balanceComparison != 0) return balanceComparison;
        final latestComparison = compareLatestDesc();
        if (latestComparison != 0) return latestComparison;
        return compareNamesAsc();
      case _CustomerSortOption.balanceAsc:
        final balanceComparison = balanceA.compareTo(balanceB);
        if (balanceComparison != 0) return balanceComparison;
        final latestComparison = compareLatestDesc();
        if (latestComparison != 0) return latestComparison;
        return compareNamesAsc();
    }
  });

  return sortedCustomers;
}

Map<int, double> _computeCustomerBalances(
  Iterable<Customer> customers,
  Iterable<txn_model.Transaction> transactions,
) {
  final customerIds = customers.map((customer) => customer.id).toSet();
  final balances = <int, double>{for (final id in customerIds) id: 0};

  for (final tx in transactions) {
    if (!customerIds.contains(tx.customerId)) continue;

    final amount = tx.amount;
    if (tx.type == TransactionType.credit) {
      balances[tx.customerId] = (balances[tx.customerId] ?? 0) + amount;
    } else {
      balances[tx.customerId] = (balances[tx.customerId] ?? 0) - amount;
    }
  }

  return balances;
}

class HomeScreen extends StatefulWidget {
  final Isar isar;
  const HomeScreen({super.key, required this.isar});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const _customerSortPreferenceKey = 'home_customer_sort_option';

  Future<List<Customer>> _customersFuture = Future.value(const []);
  Map<int, double> _customerBalances = const {};
  Map<int, String> _customerPhotoPaths = const {};
  List<BusinessProfile> _profiles = [];
  int? _activeProfileId;
  _CustomerSortOption _customerSortOption =
      _CustomerSortOption.latestTransactionDesc;
  bool _isProfileLoading = true;
  bool _isProfileFlowBusy = false;
  Timer? _autoBackupCheckTimer;
  bool _autoBackupCheckInProgress = false;
  double _homeAppBarSwipeDx = 0;
  bool _homeAppBarSwipeTriggered = false;
  final List<OverlayEntry> _overlayEntries = [];
  final List<Timer> _overlayTimers = [];

  void _showTopToast(
    String message, {
    required Color color,
    required IconData icon,
  }) {
    if (!mounted) return;
    SnackBarManager.showTopSnackBar(
      context,
      message,
      color,
      icon,
      _overlayEntries,
      _overlayTimers,
    );
  }

  void _setStateAfterFrame(VoidCallback fn) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(fn);
    });
  }

  BusinessProfile? _findProfileById(int profileId) {
    for (final profile in _profiles) {
      if (profile.id == profileId) return profile;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeProfilesAndCustomers();
    unawaited(_runScheduledBackupSilently());
    _autoBackupCheckTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(_runScheduledBackupSilently());
    });
  }

  Future<void> _runScheduledBackupSilently() async {
    if (_autoBackupCheckInProgress) return;
    _autoBackupCheckInProgress = true;
    try {
      final result = await CsvBackupService.runScheduledBackupWithResult(
        widget.isar,
      );
      await BackupNotificationService.showAutoBackupStatus(result);
    } catch (_) {}
    _autoBackupCheckInProgress = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_runScheduledBackupSilently());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoBackupCheckTimer?.cancel();

    for (final timer in _overlayTimers) {
      try {
        timer.cancel();
      } catch (_) {}
    }
    _overlayTimers.clear();

    for (final entry in _overlayEntries) {
      try {
        if (entry.mounted) {
          entry.remove();
        }
      } catch (_) {}
    }
    _overlayEntries.clear();
    super.dispose();
  }

  BusinessProfile? get _activeProfile {
    final profileId = _activeProfileId;
    if (profileId == null) return null;
    for (final profile in _profiles) {
      if (profile.id == profileId) return profile;
    }
    return null;
  }

  Future<void> _initializeProfilesAndCustomers() async {
    final prefs = await SharedPreferences.getInstance();
    _customerSortOption = _customerSortOptionFromStorage(
      prefs.getString(_customerSortPreferenceKey),
    );

    final activeProfileId = await ProfileRepository.ensureInitialized(
      widget.isar,
    );
    final profiles = await ProfileRepository.getProfiles(widget.isar);

    if (!mounted) return;
    setState(() {
      _activeProfileId = activeProfileId;
      _profiles = profiles;
      _customersFuture = _fetchCustomersForProfile(activeProfileId);
      _isProfileLoading = false;
    });
  }

  Future<List<Customer>> _fetchCustomersForProfile(int profileId) async {
    final customers = await widget.isar.customers
        .filter()
        .profileIdEqualTo(profileId)
        .findAll();

    final transactions = await widget.isar.transactions
        .filter()
        .profileIdEqualTo(profileId)
        .isDeletedEqualTo(false)
        .findAll();

    final balances = _computeBalances(customers, transactions);

    final sortedCustomers = _sortCustomers(
      customers,
      transactions,
      sortOption: _customerSortOption,
      balances: balances,
    );
    final photoPaths = await _loadCustomerPhotoPaths(profileId, customers);
    if (mounted && _activeProfileId == profileId) {
      _setStateAfterFrame(() {
        _customerBalances = balances;
        _customerPhotoPaths = photoPaths;
      });
    }

    return sortedCustomers;
  }

  String _customerPhotoKey(int profileId, int customerId) =>
      'customer_profile_photo_${profileId}_$customerId';

  Future<Map<int, String>> _loadCustomerPhotoPaths(
    int profileId,
    List<Customer> customers,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final result = <int, String>{};
    for (final customer in customers) {
      final path = prefs.getString(_customerPhotoKey(profileId, customer.id));
      if (path != null && path.trim().isNotEmpty) {
        result[customer.id] = path;
      }
    }
    return result;
  }

  Map<int, double> _computeBalances(
    List<Customer> customers,
    List<txn_model.Transaction> transactions,
  ) {
    if (customers.isEmpty) {
      return const {};
    }
    return _computeCustomerBalances(customers, transactions);
  }

  Future<void> _refreshCustomers() async {
    final profileId = _activeProfileId;
    if (profileId == null) return;
    final refreshed = await _fetchCustomersForProfile(profileId);
    if (!mounted) return;
    setState(() {
      _customersFuture = Future.value(refreshed);
    });
  }

  Future<void> _updateCustomerSortOption(_CustomerSortOption option) async {
    if (_customerSortOption == option) return;

    final profileId = _activeProfileId;
    setState(() {
      _customerSortOption = option;
      if (profileId != null) {
        _customersFuture = _fetchCustomersForProfile(profileId);
      }
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_customerSortPreferenceKey, option.storageValue);
  }

  Future<void> _showCustomerSortSheet() async {
    final selectedOption = await showModalBottomSheet<_CustomerSortOption>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Sort customers',
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Choose how customer cards are ordered.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  for (final option in _CustomerSortOption.values)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      leading: Icon(
                        option == _customerSortOption
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        color: option == _customerSortOption
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      title: Text(option.label),
                      onTap: () => Navigator.pop(sheetContext, option),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (selectedOption != null) {
      await _updateCustomerSortOption(selectedOption);
    }
  }

  Future<void> _deleteCustomer(Customer customer) async {
    final profilePhotoPrefKey =
        'customer_profile_photo_${customer.profileId}_${customer.id}';
    await widget.isar.writeTxn(() async {
      final txs = await widget.isar.transactions
          .filter()
          .profileIdEqualTo(customer.profileId)
          .customerIdEqualTo(customer.id)
          .findAll();
      if (txs.isNotEmpty) {
        await widget.isar.transactions.deleteAll(
          txs.map((tx) => tx.id).toList(),
        );
      }
      await widget.isar.customers.delete(customer.id);
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(profilePhotoPrefKey);
    await _refreshCustomers();
  }

  Future<bool> _confirmDeleteCustomer(Customer customer) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Delete customer'),
            content: Text('Are you sure you want to delete ${customer.name}?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<bool> _confirmEditCustomer(Customer customer) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Edit customer details'),
            content: Text('Do you want to edit details of ${customer.name}?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Edit'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _showEditCustomerDialog(Customer customer) async {
    final nameController = TextEditingController(text: customer.name);
    final phoneController = TextEditingController(text: customer.phone ?? '');
    String? nameError;
    bool isCheckingName = false;
    int validationRequestId = 0;

    final result = await showModalBottomSheet<_EditCustomerSheetAction>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          Future<void> validateName({bool showRequiredError = false}) async {
            final normalizedName = _normalizeCustomerName(nameController.text);

            if (normalizedName.isEmpty) {
              setSheetState(() {
                isCheckingName = false;
                nameError = showRequiredError
                    ? 'Customer name is required'
                    : null;
              });
              return;
            }

            final requestId = ++validationRequestId;
            setSheetState(() {
              isCheckingName = true;
              nameError = null;
            });

            final duplicateExists = await _isDuplicateCustomerName(
              profileId: customer.profileId,
              name: normalizedName,
              excludeCustomerId: customer.id,
            );

            if (!sheetContext.mounted || requestId != validationRequestId) {
              return;
            }

            setSheetState(() {
              isCheckingName = false;
              nameError = duplicateExists
                  ? 'Customer name already exists in this profile'
                  : null;
            });
          }

          final bottomInset = MediaQuery.of(sheetContext).viewInsets.bottom;
          final canSave =
              _normalizeCustomerName(nameController.text).isNotEmpty &&
              !isCheckingName &&
              nameError == null;
          final sheetTheme = Theme.of(sheetContext);

          return GestureDetector(
            onTap: () => FocusScope.of(sheetContext).unfocus(),
            child: AnimatedPadding(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              padding: EdgeInsets.only(bottom: bottomInset),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Edit customer details',
                        style: sheetTheme.textTheme.titleLarge,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: nameController,
                        autofocus: true,
                        decoration: InputDecoration(
                          labelText: 'Customer name',
                          errorText: nameError,
                          suffixIcon: isCheckingName
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: Padding(
                                    padding: EdgeInsets.all(12),
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : null,
                        ),
                        onChanged: (_) {
                          setSheetState(() {});
                          unawaited(validateName());
                        },
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: phoneController,
                        decoration: const InputDecoration(
                          labelText: 'Phone number',
                        ),
                        keyboardType: TextInputType.phone,
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: TextButton(
                              onPressed: () =>
                                  Navigator.pop(
                                    sheetContext,
                                    _EditCustomerSheetAction.cancel,
                                  ),
                              child: const Text('Cancel'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton(
                              onPressed: canSave
                                  ? () async {
                                      await validateName(
                                        showRequiredError: true,
                                      );
                                      if (!sheetContext.mounted) return;
                                      if (nameError != null || isCheckingName) {
                                        return;
                                      }
                                      Navigator.pop(
                                        sheetContext,
                                        _EditCustomerSheetAction.save,
                                      );
                                    }
                                  : null,
                              child: const Text('Save'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );

    final updatedName = nameController.text.trim();
    final updatedPhone = phoneController.text.trim();
    Future.delayed(const Duration(milliseconds: 350), () {
      try {
        nameController.dispose();
        phoneController.dispose();
      } catch (_) {}
    });

    if (result == null || result == _EditCustomerSheetAction.cancel) return;

    if (updatedName.isEmpty) return;

    await widget.isar.writeTxn(() async {
      customer.name = _normalizeCustomerName(updatedName);
      customer.phone = updatedPhone.isEmpty ? null : updatedPhone;
      customer.updatedAt = DateTime.now();
      await widget.isar.customers.put(customer);
    });

    await _refreshCustomers();
  }

  Future<void> _showAddCustomerDialog(int profileId) async {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    String? nameError;
    bool isCheckingName = false;
    int validationRequestId = 0;

    final didSave = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          Future<void> validateName({bool showRequiredError = false}) async {
            final normalizedName = _normalizeCustomerName(nameController.text);

            if (normalizedName.isEmpty) {
              setSheetState(() {
                isCheckingName = false;
                nameError = showRequiredError
                    ? 'Customer name is required'
                    : null;
              });
              return;
            }

            final requestId = ++validationRequestId;
            setSheetState(() {
              isCheckingName = true;
              nameError = null;
            });

            final duplicateExists = await _isDuplicateCustomerName(
              profileId: profileId,
              name: normalizedName,
            );

            if (!sheetContext.mounted || requestId != validationRequestId) {
              return;
            }

            setSheetState(() {
              isCheckingName = false;
              nameError = duplicateExists
                  ? 'Customer name already exists in this profile'
                  : null;
            });
          }

          final bottomInset = MediaQuery.of(sheetContext).viewInsets.bottom;
          final canSave =
              _normalizeCustomerName(nameController.text).isNotEmpty &&
              !isCheckingName &&
              nameError == null;
          final sheetTheme = Theme.of(sheetContext);

          return GestureDetector(
            onTap: () => FocusScope.of(sheetContext).unfocus(),
            child: AnimatedPadding(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              padding: EdgeInsets.only(bottom: bottomInset),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Add new customer',
                        style: sheetTheme.textTheme.titleLarge,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: nameController,
                        autofocus: true,
                        decoration: InputDecoration(
                          labelText: 'Customer name',
                          errorText: nameError,
                          suffixIcon: isCheckingName
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: Padding(
                                    padding: EdgeInsets.all(12),
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : null,
                        ),
                        onChanged: (_) {
                          setSheetState(() {});
                          unawaited(validateName());
                        },
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: phoneController,
                        decoration: const InputDecoration(
                          labelText: 'Phone number',
                        ),
                        keyboardType: TextInputType.phone,
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: TextButton(
                              onPressed: () =>
                                  Navigator.pop(sheetContext, false),
                              child: const Text('Cancel'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton(
                              onPressed: canSave
                                  ? () async {
                                      await validateName(
                                        showRequiredError: true,
                                      );
                                      if (!sheetContext.mounted) return;
                                      if (nameError != null || isCheckingName) {
                                        return;
                                      }
                                      Navigator.pop(sheetContext, true);
                                    }
                                  : null,
                              child: const Text('Save'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );

    final name = nameController.text.trim();
    final phone = phoneController.text.trim();
    Future.delayed(const Duration(milliseconds: 350), () {
      try {
        nameController.dispose();
        phoneController.dispose();
      } catch (_) {}
    });

    if (didSave != true || name.isEmpty) return;

    final customer = Customer()
      ..profileId = profileId
      ..name = _normalizeCustomerName(name)
      ..phone = phone.isEmpty ? null : phone
      ..uuid = DateTime.now().toIso8601String();

    await widget.isar.writeTxn(() async {
      await widget.isar.customers.put(customer);
    });

    if (!mounted) return;
    await _refreshCustomers();
  }

  String _normalizeCustomerName(String input) {
    return input.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  Future<bool> _isDuplicateCustomerName({
    required int profileId,
    required String name,
    int? excludeCustomerId,
  }) async {
    final normalized = _normalizeCustomerName(name).toLowerCase();
    if (normalized.isEmpty) return false;

    final customers = await widget.isar.customers
        .filter()
        .profileIdEqualTo(profileId)
        .findAll();

    for (final customer in customers) {
      if (excludeCustomerId != null && customer.id == excludeCustomerId) {
        continue;
      }
      final existing = _normalizeCustomerName(customer.name).toLowerCase();
      if (existing == normalized) {
        return true;
      }
    }

    return false;
  }

  Future<void> _switchProfile(int profileId) async {
    await ProfileRepository.setActiveProfile(widget.isar, profileId);
    if (!mounted) return;
    setState(() {
      _activeProfileId = profileId;
      _customersFuture = _fetchCustomersForProfile(profileId);
    });
  }

  Future<void> _switchAdjacentProfile({required bool next}) async {
    if (_isProfileLoading || _isProfileFlowBusy) return;
    if (_profiles.isEmpty) return;

    final activeProfileId = _activeProfileId;
    if (activeProfileId == null) return;

    final currentIndex = _profiles.indexWhere(
      (profile) => profile.id == activeProfileId,
    );
    if (currentIndex < 0) return;

    final targetIndex = next ? currentIndex + 1 : currentIndex - 1;
    if (targetIndex < 0) {
      _showTopToast(
        'You are already viewing the first profile.',
        color: const Color(0xFF2563EB),
        icon: Icons.info_outline,
      );
      return;
    }
    if (targetIndex >= _profiles.length) {
      _showTopToast(
        'You are already viewing the last profile.',
        color: const Color(0xFF2563EB),
        icon: Icons.info_outline,
      );
      return;
    }

    final targetProfileId = _profiles[targetIndex].id;
    await _switchProfile(targetProfileId);
  }

  void _onHomeAppBarHorizontalSwipe(DragEndDetails details) {
    if (_homeAppBarSwipeTriggered) {
      _homeAppBarSwipeDx = 0;
      _homeAppBarSwipeTriggered = false;
      return;
    }

    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() >= 150) {
      if (velocity < 0) {
        _switchAdjacentProfile(next: true);
      } else {
        _switchAdjacentProfile(next: false);
      }
    }

    _homeAppBarSwipeDx = 0;
    _homeAppBarSwipeTriggered = false;
  }

  void _onHomeAppBarHorizontalSwipeStart(DragStartDetails details) {
    _homeAppBarSwipeDx = 0;
    _homeAppBarSwipeTriggered = false;
  }

  void _onHomeAppBarHorizontalSwipeUpdate(DragUpdateDetails details) {
    if (_homeAppBarSwipeTriggered) return;

    _homeAppBarSwipeDx += details.primaryDelta ?? 0;
    if (_homeAppBarSwipeDx.abs() < 28) return;

    _homeAppBarSwipeTriggered = true;
    if (_homeAppBarSwipeDx < 0) {
      _switchAdjacentProfile(next: true);
    } else {
      _switchAdjacentProfile(next: false);
    }
  }

  void _onHomeAppBarHorizontalSwipeCancel() {
    _homeAppBarSwipeDx = 0;
    _homeAppBarSwipeTriggered = false;
  }

  Future<BusinessProfile?> _createProfile(
    String profileName, {
    bool setActive = true,
  }) async {
    if (profileName.trim().isEmpty) return null;

    try {
      final profile = await ProfileRepository.createProfile(
        widget.isar,
        profileName,
        setActive: setActive,
      );
      final profiles = await ProfileRepository.getProfiles(widget.isar);

      if (!mounted) return null;
      _setStateAfterFrame(() {
        _profiles = profiles;
        if (setActive) {
          _activeProfileId = profile.id;
          _customersFuture = _fetchCustomersForProfile(profile.id);
        }
      });
      return profile;
    } on StateError catch (error) {
      if (!mounted) return null;
      _showTopToast(
        error.message.isNotEmpty
            ? error.message
            : 'Could not create profile.',
        color: const Color(0xFFDC2626),
        icon: Icons.warning_amber_rounded,
      );
    }
    return null;
  }

  Future<String?> _promptForProfileName({
    required String title,
    required String actionLabel,
  }) async {
    final controller = TextEditingController();
    String? errorText;

    final profileName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Business name',
              errorText: errorText,
            ),
            onChanged: (_) {
              if (errorText != null) {
                setDialogState(() => errorText = null);
              }
            },
            onSubmitted: (value) {
              final name = value.trim();
              if (name.isEmpty) {
                setDialogState(() => errorText = 'Business name is required');
                return;
              }
              Navigator.pop(dialogContext, name);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final name = controller.text.trim();
                if (name.isEmpty) {
                  setDialogState(
                    () => errorText = 'Business name is required',
                  );
                  return;
                }
                Navigator.pop(dialogContext, name);
              },
              child: Text(actionLabel),
            ),
          ],
        ),
      ),
    );

    Future.delayed(const Duration(milliseconds: 350), () {
      try {
        controller.dispose();
      } catch (_) {}
    });

    return profileName;
  }

  Future<String?> _resolveCustomerMoveName({
    required String initialName,
    required BusinessProfile targetProfile,
  }) async {
    var proposedName = _normalizeCustomerName(initialName);
    if (proposedName.isEmpty) return null;

    final hasDuplicate = await _isDuplicateCustomerName(
      profileId: targetProfile.id,
      name: proposedName,
    );
    if (!hasDuplicate) {
      return proposedName;
    }

    if (!mounted) return null;

    final controller = TextEditingController(text: '$proposedName (${targetProfile.name})');
    String? errorText;

    final resolvedName = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Customer name already exists'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'A customer with this name already exists in ${targetProfile.name}. Enter a different name to move this customer.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Customer name',
                  errorText: errorText,
                ),
                onChanged: (_) {
                  if (errorText != null) {
                    setDialogState(() => errorText = null);
                  }
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final nextName = _normalizeCustomerName(controller.text);
                if (nextName.isEmpty) {
                  setDialogState(() => errorText = 'Customer name is required');
                  return;
                }

                final duplicate = await _isDuplicateCustomerName(
                  profileId: targetProfile.id,
                  name: nextName,
                );
                if (!dialogContext.mounted) return;
                if (duplicate) {
                  setDialogState(
                    () => errorText = 'This name already exists in the selected profile',
                  );
                  return;
                }

                Navigator.pop(dialogContext, nextName);
              },
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );

    Future.delayed(const Duration(milliseconds: 350), () {
      try {
        controller.dispose();
      } catch (_) {}
    });

    return resolvedName;
  }

  Future<BusinessProfile?> _pickTargetProfileForCustomerMove(
    Customer customer,
  ) async {
    final profiles = await ProfileRepository.getProfiles(widget.isar);
    final availableProfiles = profiles
        .where((profile) => profile.id != customer.profileId)
        .toList();

    if (!mounted) return null;

    if (availableProfiles.isEmpty) {
      final shouldCreate = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('No other profile found'),
          content: const Text(
            'Create a new business profile to move this customer.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Create profile'),
            ),
          ],
        ),
      );

      if (shouldCreate != true) return null;

      final name = await _promptForProfileName(
        title: 'Create profile',
        actionLabel: 'Create',
      );
      if (name == null || name.trim().isEmpty) return null;
      return _createProfile(name, setActive: false);
    }

    final selection = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final profile in availableProfiles)
              ListTile(
                leading: const Icon(Icons.business_outlined),
                title: Text(profile.name),
                onTap: () => Navigator.pop(
                  sheetContext,
                  profile.id.toString(),
                ),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.add_circle_outline_rounded),
              title: const Text('Create new profile'),
              onTap: () => Navigator.pop(sheetContext, 'create'),
            ),
          ],
        ),
      ),
    );

    if (!mounted || selection == null) return null;
    if (selection == 'create') {
      final name = await _promptForProfileName(
        title: 'Create profile',
        actionLabel: 'Create',
      );
      if (name == null || name.trim().isEmpty) return null;
      return _createProfile(name, setActive: false);
    }

    final selectedId = int.tryParse(selection);
    if (selectedId == null) return null;
    return profiles.where((profile) => profile.id == selectedId).firstOrNull;
  }

  Future<void> _moveCustomerToDifferentProfile(
    Customer customer, {
    required String draftName,
    required String draftPhone,
  }) async {
    final targetProfile = await _pickTargetProfileForCustomerMove(customer);
    if (!mounted || targetProfile == null) return;

    final resolvedName = await _resolveCustomerMoveName(
      initialName: draftName,
      targetProfile: targetProfile,
    );
    if (!mounted || resolvedName == null) return;

    final shouldMove = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Move customer'),
        content: Text(
          'Move "$resolvedName" to ${targetProfile.name}? All transactions will move with this customer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Move'),
          ),
        ],
      ),
    );

    if (shouldMove != true) return;

    final oldProfileId = customer.profileId;
    final photoPath = _customerPhotoPaths[customer.id];
    final relatedTransactions = await widget.isar.transactions
        .filter()
        .profileIdEqualTo(customer.profileId)
        .customerIdEqualTo(customer.id)
        .findAll();
    final now = DateTime.now();

    await widget.isar.writeTxn(() async {
      customer.profileId = targetProfile.id;
      customer.name = resolvedName;
      customer.phone = draftPhone.trim().isEmpty ? null : draftPhone.trim();
      customer.updatedAt = now;
      await widget.isar.customers.put(customer);

      for (final transaction in relatedTransactions) {
        transaction.profileId = targetProfile.id;
        transaction.updatedAt = now;
      }
      if (relatedTransactions.isNotEmpty) {
        await widget.isar.transactions.putAll(relatedTransactions);
      }
    });

    final prefs = await SharedPreferences.getInstance();
    final oldPhotoKey = _customerPhotoKey(oldProfileId, customer.id);
    final newPhotoKey = _customerPhotoKey(targetProfile.id, customer.id);
    if (photoPath != null && photoPath.trim().isNotEmpty) {
      await prefs.setString(newPhotoKey, photoPath);
      if (oldPhotoKey != newPhotoKey) {
        await prefs.remove(oldPhotoKey);
      }
    }

    if (!mounted) return;
    _showTopToast(
      'Moved ${customer.name} to ${targetProfile.name}',
      color: const Color(0xFF16A34A),
      icon: Icons.move_down_rounded,
    );
    await _refreshCustomers();
  }

  Future<void> _showCustomerQuickActions(Customer customer) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit customer'),
              onTap: () => Navigator.pop(sheetContext, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('Move to another profile'),
              onTap: () => Navigator.pop(sheetContext, 'move'),
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(sheetContext).colorScheme.error,
              ),
              title: Text(
                'Delete customer',
                style: TextStyle(
                  color: Theme.of(sheetContext).colorScheme.error,
                ),
              ),
              onTap: () => Navigator.pop(sheetContext, 'delete'),
            ),
          ],
        ),
      ),
    );

    if (!mounted || action == null) return;

    switch (action) {
      case 'edit':
        await _showEditCustomerDialog(customer);
        break;
      case 'move':
        await _moveCustomerToDifferentProfile(
          customer,
          draftName: customer.name,
          draftPhone: customer.phone ?? '',
        );
        break;
      case 'delete':
        final shouldDelete = await _confirmDeleteCustomer(customer);
        if (shouldDelete) {
          await _deleteCustomer(customer);
        }
        break;
    }
  }

  Future<void> _showRenameProfileDialog(BusinessProfile profile) async {
    final controller = TextEditingController(text: profile.name);

    final profileName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename profile'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Business name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    Future.delayed(const Duration(milliseconds: 350), () {
      try {
        controller.dispose();
      } catch (_) {}
    });
    if (profileName == null || profileName.trim().isEmpty) return;

    try {
      await ProfileRepository.renameProfile(
        widget.isar,
        profile.id,
        profileName,
      );
      final profiles = await ProfileRepository.getProfiles(widget.isar);

      if (!mounted) return;
      _setStateAfterFrame(() => _profiles = profiles);
    } on StateError {
      if (!mounted) return;
      _showTopToast(
        'Cannot delete the last profile',
        color: const Color(0xFFDC2626),
        icon: Icons.warning_amber_rounded,
      );
    }
  }

  Future<void> _deleteProfile(BusinessProfile profile) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete profile'),
        content: Text(
          'Delete "${profile.name}" and all its customers and transactions?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (shouldDelete != true) return;

    try {
      await ProfileRepository.deleteProfile(widget.isar, profile.id);
      final activeProfileId = await ProfileRepository.ensureInitialized(
        widget.isar,
      );
      final profiles = await ProfileRepository.getProfiles(widget.isar);

      if (!mounted) return;
      _setStateAfterFrame(() {
        _activeProfileId = activeProfileId;
        _profiles = profiles;
        _customersFuture = _fetchCustomersForProfile(activeProfileId);
      });
    } on StateError {
      if (!mounted) return;
      _showTopToast(
        'Cannot delete the last profile',
        color: const Color(0xFFDC2626),
        icon: Icons.warning_amber_rounded,
      );
    }
  }

  Future<void> _showProfileActions(BusinessProfile profile) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename profile'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete profile'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );

    if (action == 'rename') {
      await _showRenameProfileDialog(profile);
    } else if (action == 'delete') {
      await _deleteProfile(profile);
    }
  }

  Future<void> _openProfileSheet() async {
    if (_isProfileFlowBusy) return;
    _isProfileFlowBusy = true;

    final profiles = await ProfileRepository.getProfiles(widget.isar);
    if (!mounted) return;

    setState(() => _profiles = profiles);

    final createNameController = TextEditingController();
    bool showCreateInput = false;

    final action = await showModalBottomSheet<_ProfileSheetAction>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            final bottomInset = MediaQuery.of(sheetContext).viewInsets.bottom;
            final theme = Theme.of(sheetContext);
            final colorScheme = theme.colorScheme;
            final dividerColor = colorScheme.outlineVariant.withAlpha(140);

            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => FocusScope.of(sheetContext).unfocus(),
              child: AnimatedPadding(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                padding: EdgeInsets.only(bottom: bottomInset),
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(
                          child: Container(
                            width: 42,
                            height: 4,
                            decoration: BoxDecoration(
                              color: colorScheme.outlineVariant,
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Business Profiles',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Switch, create, rename, or delete profiles.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Container(
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: dividerColor),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final entry in _profiles.asMap().entries) ...[
                                Builder(
                                  builder: (_) {
                                    final profile = entry.value;
                                    final isActive =
                                        profile.id == _activeProfileId;
                                    final tileColor = isActive
                                        ? colorScheme.primaryContainer
                                        : Colors.transparent;
                                    final titleColor = isActive
                                        ? colorScheme.onPrimaryContainer
                                        : colorScheme.onSurface;
                                    final subtitleColor = isActive
                                        ? colorScheme.onPrimaryContainer
                                              .withAlpha(190)
                                        : colorScheme.onSurfaceVariant;

                                    return Material(
                                      color: tileColor,
                                      borderRadius: BorderRadius.circular(16),
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(16),
                                        onTap: () {
                                          Navigator.pop(
                                            sheetContext,
                                            _ProfileSheetAction(
                                              type: _ProfileSheetActionType
                                                  .switchProfile,
                                              profileId: profile.id,
                                            ),
                                          );
                                        },
                                        child: Padding(
                                          padding: const EdgeInsets.fromLTRB(
                                            14,
                                            10,
                                            10,
                                            10,
                                          ),
                                          child: Row(
                                            children: [
                                              Container(
                                                width: 34,
                                                height: 34,
                                                decoration: BoxDecoration(
                                                  color: isActive
                                                      ? colorScheme.primary
                                                            .withAlpha(32)
                                                      : colorScheme
                                                            .surfaceContainerHighest,
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                ),
                                                alignment: Alignment.center,
                                                child: Icon(
                                                  Icons.business_rounded,
                                                  size: 18,
                                                  color: isActive
                                                      ? colorScheme.primary
                                                      : colorScheme
                                                            .onSurfaceVariant,
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Text(
                                                      profile.name,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: theme
                                                          .textTheme
                                                          .bodyLarge
                                                          ?.copyWith(
                                                            color: titleColor,
                                                            fontWeight:
                                                                FontWeight.w700,
                                                          ),
                                                    ),
                                                    Text(
                                                      isActive
                                                          ? 'Active profile'
                                                          : 'Tap to switch',
                                                      style: theme
                                                          .textTheme
                                                          .bodySmall
                                                          ?.copyWith(
                                                            color:
                                                                subtitleColor,
                                                          ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              if (isActive)
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        right: 2,
                                                      ),
                                                  child: Icon(
                                                    Icons.check_circle_rounded,
                                                    size: 18,
                                                    color:
                                                        colorScheme.primary,
                                                  ),
                                                ),
                                              IconButton(
                                                style: IconButton.styleFrom(
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  padding: EdgeInsets.zero,
                                                  minimumSize: const Size(
                                                    34,
                                                    34,
                                                  ),
                                                  backgroundColor: isActive
                                                      ? colorScheme.surface
                                                            .withAlpha(120)
                                                      : colorScheme
                                                            .surfaceContainerHighest,
                                                ),
                                                icon: const Icon(
                                                  Icons.more_horiz_rounded,
                                                  size: 18,
                                                ),
                                                onPressed: () {
                                                  Navigator.pop(
                                                    sheetContext,
                                                    _ProfileSheetAction(
                                                      type:
                                                          _ProfileSheetActionType
                                                              .profileActions,
                                                      profileId: profile.id,
                                                    ),
                                                  );
                                                },
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                                if (entry.key != _profiles.length - 1)
                                  Divider(height: 1, color: dividerColor),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        if (!showCreateInput)
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: () {
                                setSheetState(() => showCreateInput = true);
                              },
                              icon: const Icon(
                                Icons.add_circle_outline_rounded,
                              ),
                              label: const Text('Create new profile'),
                            ),
                          )
                        else
                          Container(
                            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                            decoration: BoxDecoration(
                              color: colorScheme.surfaceContainerLow,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: dividerColor),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Create business profile',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: createNameController,
                                  autofocus: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Business name',
                                  ),
                                  onSubmitted: (value) {
                                    final name = value.trim();
                                    if (name.isEmpty) return;
                                    FocusScope.of(sheetContext).unfocus();
                                    Navigator.pop(
                                      sheetContext,
                                      _ProfileSheetAction(
                                        type:
                                            _ProfileSheetActionType.createProfile,
                                        profileName: name,
                                      ),
                                    );
                                  },
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton(
                                        onPressed: () {
                                          FocusScope.of(sheetContext)
                                              .unfocus();
                                          createNameController.clear();
                                          setSheetState(
                                            () => showCreateInput = false,
                                          );
                                        },
                                        child: const Text('Cancel'),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: FilledButton(
                                        onPressed: () {
                                          final name = createNameController.text
                                              .trim();
                                          if (name.isEmpty) return;
                                          FocusScope.of(sheetContext)
                                              .unfocus();
                                          Navigator.pop(
                                            sheetContext,
                                            _ProfileSheetAction(
                                              type: _ProfileSheetActionType
                                                  .createProfile,
                                              profileName: name,
                                            ),
                                          );
                                        },
                                        child: const Text('Create'),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    FocusManager.instance.primaryFocus?.unfocus();
    Future.delayed(const Duration(milliseconds: 450), () {
      try {
        createNameController.dispose();
      } catch (_) {}
    });

    try {
      if (!mounted || action == null) return;

      switch (action.type) {
        case _ProfileSheetActionType.switchProfile:
          final profileId = action.profileId;
          if (profileId != null) {
            await _switchProfile(profileId);
          }
          break;
        case _ProfileSheetActionType.createProfile:
          final profileName = action.profileName;
          if (profileName != null) {
            await _createProfile(profileName);
          }
          break;
        case _ProfileSheetActionType.profileActions:
          final profileId = action.profileId;
          if (profileId != null) {
            final profile = _findProfileById(profileId);
            if (profile != null) {
              await _showProfileActions(profile);
            }
          }
          break;
      }
    } finally {
      _isProfileFlowBusy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final profileName = _activeProfile?.name;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: _onHomeAppBarHorizontalSwipeStart,
          onHorizontalDragUpdate: _onHomeAppBarHorizontalSwipeUpdate,
          onHorizontalDragEnd: _onHomeAppBarHorizontalSwipe,
          onHorizontalDragCancel: _onHomeAppBarHorizontalSwipeCancel,
          child: AppBar(
            centerTitle: false,
            title: Row(
              children: [
                const AppLogo(height: 24),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'My Ledger',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (profileName != null)
                        InkWell(
                          onTap: _isProfileLoading ? null : _openProfileSheet,
                          child: Row(
                            mainAxisSize: MainAxisSize.max,
                            children: [
                              Flexible(
                                child: Text(
                                  profileName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                ),
                              ),
                              const SizedBox(width: 2),
                              Icon(
                                Icons.arrow_drop_down,
                                size: 18,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.search),
                onPressed: () async {
                  final profileId = _activeProfileId;
                  if (profileId == null) return;
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => _HomeCustomerSearchPage(
                        isar: widget.isar,
                        profileId: profileId,
                        profileName: profileName,
                        sortOption: _customerSortOption,
                      ),
                    ),
                  );
                  if (!mounted) return;
                  await _refreshCustomers();
                },
              ),
              IconButton(
                icon: const Icon(Icons.bar_chart),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => AnalyticsScreen(isar: widget.isar),
                    ),
                  );
                },
              ),
              IconButton(
                icon: const Icon(Icons.menu),
                onPressed: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => MenuScreen(isar: widget.isar),
                    ),
                  );
                  if (!mounted) return;
                  await _initializeProfilesAndCustomers();
                },
              ),
            ],
          ),
        ),
      ),
      body: _isProfileLoading
          ? const Center(child: CircularProgressIndicator())
          : FutureBuilder<List<Customer>>(
              future: _customersFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (snapshot.hasError) {
                  return Center(child: Text('Error: ${snapshot.error}'));
                }

                final customers = snapshot.data ?? [];

                if (customers.isEmpty) {
                  return const Center(
                    child: Text("No customers yet. Tap + to add one."),
                  );
                }

                return RefreshIndicator(
                  onRefresh: _refreshCustomers,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(6, 2, 6, 0),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: OutlinedButton.icon(
                            onPressed: _showCustomerSortSheet,
                            icon: const Icon(Icons.sort, size: 18),
                            label: Text(_customerSortOption.label),
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          padding: const EdgeInsets.fromLTRB(
                            6,
                            0,
                            6,
                            8,
                          ),
                          itemCount: customers.length,
                          itemBuilder: (context, index) {
                            final customer = customers[index];
                            final balance = _customerBalances[customer.id] ?? 0;
                            final absBalance = balance.abs();
                            final balanceText = absBalance == absBalance.toInt()
                                ? absBalance.toInt().toString()
                                : absBalance.toStringAsFixed(2);
                            final initials = customer.name.trim().isEmpty
                                ? '?'
                                : customer.name
                                      .trim()
                                      .split(' ')
                                      .map((e) => e.isNotEmpty ? e[0] : '')
                                      .take(2)
                                      .join();

                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Dismissible(
                                  key: ValueKey(
                                    '${customer.id}-${customer.updatedAt.millisecondsSinceEpoch}',
                                  ),
                                  direction: DismissDirection.horizontal,
                                  background: Container(
                                    decoration: BoxDecoration(
                                      color: Colors.blue.shade700,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    alignment: Alignment.centerLeft,
                                    padding: const EdgeInsets.only(left: 20),
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.edit_outlined,
                                          color: Colors.white,
                                        ),
                                        SizedBox(width: 8),
                                        Text(
                                          'Edit',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  secondaryBackground: Container(
                                    decoration: BoxDecoration(
                                      color: Theme.of(context).colorScheme.error,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    alignment: Alignment.centerRight,
                                    padding: const EdgeInsets.only(right: 20),
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          'Delete',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        SizedBox(width: 8),
                                        Icon(
                                          Icons.delete_outline,
                                          color: Colors.white,
                                        ),
                                      ],
                                    ),
                                  ),
                                  confirmDismiss: (direction) async {
                                    if (direction == DismissDirection.startToEnd) {
                                      final shouldEdit = await _confirmEditCustomer(
                                        customer,
                                      );
                                      if (shouldEdit) {
                                        Future.microtask(() async {
                                          if (!mounted) return;
                                          await _showEditCustomerDialog(customer);
                                        });
                                      }
                                      return false;
                                    }
                                    return _confirmDeleteCustomer(customer);
                                  },
                                  onDismissed: (direction) async {
                                    if (direction != DismissDirection.endToStart) {
                                      return;
                                    }
                                    await _deleteCustomer(customer);
                                    if (!mounted) return;
                                  },
                                  child: Card(
                                    elevation: 0,
                                    color: Colors.transparent,
                                    surfaceTintColor: Colors.transparent,
                                    clipBehavior: Clip.antiAlias,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(14),
                                      onTap: () async {
                                        final seedTxs = await widget.isar.transactions
                                            .filter()
                                            .profileIdEqualTo(customer.profileId)
                                            .customerIdEqualTo(customer.id)
                                            .findAll();
                                        seedTxs.sort(
                                          (a, b) => a.date.compareTo(b.date),
                                        );
                                        if (!context.mounted) return;

                                        Navigator.push(
                                          context,
                                          PageRouteBuilder(
                                            transitionDuration: Duration.zero,
                                            reverseTransitionDuration: Duration.zero,
                                            pageBuilder: (_, _, _) =>
                                                CustomerLedgerScreen(
                                                  isar: widget.isar,
                                                  customerId: customer.id,
                                                  customerName: customer.name,
                                                  profileId: customer.profileId,
                                                  customerPhotoPath:
                                                      _customerPhotoPaths[customer.id],
                                                  initialTransactions: seedTxs,
                                                ),
                                            transitionsBuilder:
                                                (
                                                  context,
                                                  animation,
                                                  secondaryAnimation,
                                                  child,
                                                ) => child,
                                          ),
                                        ).then((_) async {
                                          if (!mounted) return;
                                          await _refreshCustomers();
                                        });
                                      },
                                      child: Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          12,
                                          9,
                                          12,
                                          9,
                                        ),
                                        child: Consumer(
                                          builder: (context, ref, _) {
                                            final theme = Theme.of(context);
                                            final colorScheme = theme.colorScheme;
                                            final currencyCode = ref.watch(
                                              currencyProvider,
                                            );
                                            final currencySymbol =
                                                NumberFormat.simpleCurrency(
                                                  name: currencyCode,
                                                ).currencySymbol;
                                            final balanceColor = balance > 0
                                                ? (theme.brightness ==
                                                          Brightness.light
                                                      ? Colors.green.shade700
                                                      : Colors.green.shade400)
                                                : balance < 0
                                                ? colorScheme.error
                                                : colorScheme.onSurfaceVariant;
                                            final balanceState = balance > 0
                                                ? 'Advance'
                                                : balance < 0
                                                ? 'Due'
                                                : 'Settled';
                                            final customerPhotoPath =
                                                _customerPhotoPaths[customer.id];

                                            return Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.center,
                                        children: [
                                          Container(
                                            width: 44,
                                            height: 44,
                                            decoration: BoxDecoration(
                                              color:
                                                  colorScheme.primaryContainer,
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                            alignment: Alignment.center,
                                            clipBehavior: Clip.antiAlias,
                                            child: customerPhotoPath != null
                                                ? Image.file(
                                                    File(customerPhotoPath),
                                                    fit: BoxFit.cover,
                                                    width: 44,
                                                    height: 44,
                                                    errorBuilder:
                                                        (
                                                          context,
                                                          error,
                                                          stackTrace,
                                                        ) => Text(
                                                          initials
                                                              .toUpperCase(),
                                                          style: theme
                                                              .textTheme
                                                              .titleMedium
                                                              ?.copyWith(
                                                                color: colorScheme
                                                                    .onPrimaryContainer,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w800,
                                                              ),
                                                        ),
                                                  )
                                                : Text(
                                                    initials.toUpperCase(),
                                                    style: theme
                                                        .textTheme
                                                        .titleMedium
                                                        ?.copyWith(
                                                          color: colorScheme
                                                              .onPrimaryContainer,
                                                          fontWeight:
                                                              FontWeight.w800,
                                                        ),
                                                  ),
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Row(
                                                  children: [
                                                    Expanded(
                                                      child: Text(
                                                        customer.name,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: theme
                                                            .textTheme
                                                            .titleMedium
                                                            ?.copyWith(
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w700,
                                                              height: 1.1,
                                                            ),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 8),
                                                    ConstrainedBox(
                                                      constraints: BoxConstraints(
                                                        maxWidth:
                                                            MediaQuery.sizeOf(
                                                              context,
                                                            ).width *
                                                            0.44,
                                                      ),
                                                      child: Row(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          Flexible(
                                                            child: Container(
                                                              padding:
                                                                  const EdgeInsets.symmetric(
                                                                    horizontal: 8,
                                                                    vertical: 4,
                                                                  ),
                                                              decoration: BoxDecoration(
                                                                color: balanceColor
                                                                    .withAlpha(24),
                                                                borderRadius:
                                                                    BorderRadius.circular(
                                                                      12,
                                                                    ),
                                                              ),
                                                              child: Text(
                                                                '$balanceState • $currencySymbol $balanceText',
                                                                maxLines: 1,
                                                                overflow:
                                                                    TextOverflow
                                                                        .ellipsis,
                                                                style: theme
                                                                    .textTheme
                                                                    .labelSmall
                                                                    ?.copyWith(
                                                                      color:
                                                                          balanceColor,
                                                                      fontWeight:
                                                                          FontWeight
                                                                              .w700,
                                                                    ),
                                                              ),
                                                            ),
                                                          ),
                                                          const SizedBox(
                                                            width: 2,
                                                          ),
                                                          IconButton(
                                                            tooltip:
                                                                'Customer actions',
                                                            onPressed: () =>
                                                                _showCustomerQuickActions(
                                                                  customer,
                                                                ),
                                                            visualDensity:
                                                                VisualDensity.compact,
                                                            padding:
                                                                EdgeInsets.zero,
                                                            constraints:
                                                                const BoxConstraints(
                                                                  minWidth: 28,
                                                                  minHeight: 28,
                                                                ),
                                                            icon: Icon(
                                                              Icons
                                                                  .more_vert_rounded,
                                                              size: 20,
                                                              color: colorScheme
                                                                  .onSurfaceVariant,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                            );
                                          },
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(72, 0, 4, 0),
                                  child: Container(
                                    height: 1,
                                    decoration: BoxDecoration(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.outlineVariant.withAlpha(160),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final profileId = _activeProfileId;
          if (profileId == null) return;

          await _showAddCustomerDialog(profileId);
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _HomeCustomerSearchPage extends StatefulWidget {
  final Isar isar;
  final int profileId;
  final String? profileName;
  final _CustomerSortOption sortOption;

  const _HomeCustomerSearchPage({
    required this.isar,
    required this.profileId,
    this.profileName,
    required this.sortOption,
  });

  @override
  State<_HomeCustomerSearchPage> createState() =>
      _HomeCustomerSearchPageState();
}

class _HomeCustomerSearchPageState extends State<_HomeCustomerSearchPage> {
  final TextEditingController _controller = TextEditingController();
  List<Customer> _customers = const [];
  List<txn_model.Transaction> _transactions = const [];
  Map<int, Customer> _customerById = const {};
  Map<int, String> _photoPaths = const {};
  String _currencyCode = 'INR';
  bool _useGivenReceivedLabels = false;
  _SearchTimeFilter _timeFilter = _SearchTimeFilter.allTime;
  _TransactionMatchFilter _transactionMatchFilter = _TransactionMatchFilter.all;
  DateTimeRange? _customRange;
  late DateTime _selectedMonth;
  late int _selectedYear;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedMonth = DateTime(now.year, now.month, 1);
    _selectedYear = now.year;
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final customers = await widget.isar.customers
        .filter()
        .profileIdEqualTo(widget.profileId)
        .findAll();

    final txs = await widget.isar.transactions
        .filter()
        .profileIdEqualTo(widget.profileId)
        .isDeletedEqualTo(false)
        .findAll();

    final balances = _computeCustomerBalances(customers, txs);
    final sortedCustomers = _sortCustomers(
      customers,
      txs,
      sortOption: widget.sortOption,
      balances: balances,
    );

    final customerById = <int, Customer>{
      for (final customer in sortedCustomers) customer.id: customer,
    };

    final prefs = await SharedPreferences.getInstance();
    final currencyCode = prefs.getString('currencyCode') ?? 'INR';
    final savedLabelStyle = prefs.getString('transactionLabelStyle');
    final useGivenReceivedLabels = savedLabelStyle == 'givenReceived';
    final photos = <int, String>{};
    for (final customer in customers) {
      final key = 'customer_profile_photo_${widget.profileId}_${customer.id}';
      final path = prefs.getString(key);
      if (path != null && path.trim().isNotEmpty) {
        photos[customer.id] = path;
      }
    }

    if (!mounted) return;
    setState(() {
      _customers = sortedCustomers;
      _transactions = txs;
      _customerById = customerById;
      _photoPaths = photos;
      _currencyCode = currencyCode;
      _useGivenReceivedLabels = useGivenReceivedLabels;
      _loading = false;
    });
  }

  List<Customer> get _customerNameMatches {
    final query = _controller.text.trim().toLowerCase();
    if (query.isEmpty) return const [];
    final customerIdsInRange = _customerIdsInSelectedTimeRange;

    return _customers.where((customer) {
      final nameMatch = customer.name.toLowerCase().contains(query);
      final phoneMatch = (customer.phone ?? '').toLowerCase().contains(query);
      final queryMatch = nameMatch || phoneMatch;
      if (!queryMatch) return false;
      if (_timeFilter == _SearchTimeFilter.allTime) return true;
      return customerIdsInRange.contains(customer.id);
    }).toList();
  }

  List<txn_model.Transaction> get _transactionMatches {
    final query = _controller.text.trim().toLowerCase();
    if (query.isEmpty) return const [];

    return _transactions.where((tx) {
      if (!_isInSelectedTimeRange(tx.date)) {
        return false;
      }
      final description = (tx.note?.trim().isNotEmpty ?? false)
          ? tx.note!.trim().toLowerCase()
          : '';
      final amount = tx.amount.toString();
      final amountFixed = tx.amount.toStringAsFixed(2);

      return description.contains(query) ||
          amount.contains(query) ||
          amountFixed.contains(query);
    }).toList()..sort((a, b) => b.date.compareTo(a.date));
  }

  List<Customer> get _customerNameMatchesBase {
    final query = _controller.text.trim().toLowerCase();
    if (query.isEmpty) return const [];
    return _customers.where((customer) {
      final nameMatch = customer.name.toLowerCase().contains(query);
      final phoneMatch = (customer.phone ?? '').toLowerCase().contains(query);
      return nameMatch || phoneMatch;
    }).toList();
  }

  List<txn_model.Transaction> get _transactionMatchesBase {
    final query = _controller.text.trim().toLowerCase();
    if (query.isEmpty) return const [];

    return _transactions.where((tx) {
      final description = (tx.note?.trim().isNotEmpty ?? false)
          ? tx.note!.trim().toLowerCase()
          : '';
      final amount = tx.amount.toString();
      final amountFixed = tx.amount.toStringAsFixed(2);

      return description.contains(query) ||
          amount.contains(query) ||
          amountFixed.contains(query);
    }).toList();
  }

  List<int> get _availableYearsForQuery {
    final query = _controller.text.trim();
    if (query.isEmpty) return const [];

    final years = <int>{};
    final matchingCustomerIds = _customerNameMatchesBase
        .map((customer) => customer.id)
        .toSet();

    for (final tx in _transactionMatchesBase) {
      years.add(tx.date.toLocal().year);
    }

    for (final tx in _transactions) {
      if (matchingCustomerIds.contains(tx.customerId)) {
        years.add(tx.date.toLocal().year);
      }
    }

    final sortedYears = years.toList()..sort((a, b) => b.compareTo(a));
    return sortedYears;
  }

  List<txn_model.Transaction> _filterTransactionMatchesByType(
    List<txn_model.Transaction> matches,
  ) {
    switch (_transactionMatchFilter) {
      case _TransactionMatchFilter.all:
        return matches;
      case _TransactionMatchFilter.creditReceived:
        return matches
            .where((tx) => tx.type == TransactionType.credit)
            .toList();
      case _TransactionMatchFilter.debitGiven:
        return matches
            .where((tx) => tx.type != TransactionType.credit)
            .toList();
    }
  }

  Set<int> get _customerIdsInSelectedTimeRange {
    if (_timeFilter == _SearchTimeFilter.allTime) {
      return _customers.map((customer) => customer.id).toSet();
    }
    return _transactions
        .where((tx) => _isInSelectedTimeRange(tx.date))
        .map((tx) => tx.customerId)
        .toSet();
  }

  bool _isInSelectedTimeRange(DateTime date) {
    final local = date.toLocal();

    switch (_timeFilter) {
      case _SearchTimeFilter.allTime:
        return true;
      case _SearchTimeFilter.month:
        return local.year == _selectedMonth.year &&
            local.month == _selectedMonth.month;
      case _SearchTimeFilter.year:
        return local.year == _selectedYear;
      case _SearchTimeFilter.customRange:
        final range = _customRange;
        if (range == null) return true;
        final start = DateTime(
          range.start.year,
          range.start.month,
          range.start.day,
        );
        final end = DateTime(
          range.end.year,
          range.end.month,
          range.end.day,
          23,
          59,
          59,
          999,
        );
        return !local.isBefore(start) && !local.isAfter(end);
    }
  }

  Future<void> _selectTimeFilter(_SearchTimeFilter filter) async {
    if (filter == _SearchTimeFilter.month) {
      int dialogYear = _selectedMonth.year;
      int selectedMonthNumber = _selectedMonth.month;
      final pickedMonth = await showDialog<int>(
        context: context,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx, setDialogState) {
              final monthNames = const [
                'January',
                'February',
                'March',
                'April',
                'May',
                'June',
                'July',
                'August',
                'September',
                'October',
                'November',
                'December',
              ];
              final monthHeaderAccentColor = Colors.blue.shade600;

              return Dialog(
                insetPadding: const EdgeInsets.symmetric(horizontal: 12),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${monthNames[selectedMonthNumber - 1]} $dialogYear',
                        style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            onPressed: () {
                              if (dialogYear <= 2000) return;
                              setDialogState(() => dialogYear--);
                            },
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 28,
                              minHeight: 28,
                            ),
                            icon: Icon(
                              Icons.chevron_left,
                              color: monthHeaderAccentColor,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '$dialogYear',
                            style: Theme.of(ctx).textTheme.titleMedium
                                ?.copyWith(color: monthHeaderAccentColor),
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            onPressed: () {
                              if (dialogYear >= 2100) return;
                              setDialogState(() => dialogYear++);
                            },
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 28,
                              minHeight: 28,
                            ),
                            icon: Icon(
                              Icons.chevron_right,
                              color: monthHeaderAccentColor,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: 12,
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 3,
                                mainAxisSpacing: 4,
                                crossAxisSpacing: 4,
                                childAspectRatio: 2.3,
                              ),
                          itemBuilder: (context, index) {
                            final monthNumber = index + 1;
                            final isSelected =
                                monthNumber == selectedMonthNumber;
                            final givenAccentColor = Colors.blue.shade600;
                            return TextButton(
                              onPressed: () {
                                setDialogState(() {
                                  selectedMonthNumber = monthNumber;
                                });
                              },
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 6,
                                ),
                                backgroundColor: isSelected
                                    ? givenAccentColor
                                    : Colors.transparent,
                                foregroundColor: isSelected
                                    ? Colors.white
                                    : Theme.of(ctx).colorScheme.onSurface,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(999),
                                  side: const BorderSide(
                                    color: Colors.transparent,
                                  ),
                                ),
                              ),
                              child: Text(
                                monthNames[index],
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: isSelected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: monthHeaderAccentColor,
                            ),
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Cancel'),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: monthHeaderAccentColor,
                            ),
                            onPressed: () =>
                                Navigator.pop(ctx, selectedMonthNumber),
                            child: const Text('OK'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
      if (pickedMonth == null || !mounted) return;
      setState(() {
        _selectedMonth = DateTime(dialogYear, pickedMonth, 1);
        _timeFilter = _SearchTimeFilter.month;
      });
      return;
    }

    if (filter == _SearchTimeFilter.year) {
      final availableYears = _availableYearsForQuery;
      if (availableYears.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No data available by year.')),
        );
        return;
      }

      final initialSelection = availableYears.contains(_selectedYear)
          ? _selectedYear
          : availableYears.first;
      int dialogSelectedYear = initialSelection;

      final selectedYear = await showDialog<int>(
        context: context,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx, setDialogState) {
              final givenAccentColor = Colors.blue.shade600;
              return Dialog(
                insetPadding: const EdgeInsets.symmetric(horizontal: 16),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '$dialogSelectedYear',
                        style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: 280,
                          maxHeight: 320,
                        ),
                        child: SingleChildScrollView(
                          child: Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 8,
                            runSpacing: 8,
                            children: availableYears.map((year) {
                              final isSelected = year == dialogSelectedYear;
                              return TextButton(
                                onPressed: () {
                                  setDialogState(() {
                                    dialogSelectedYear = year;
                                  });
                                },
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 10,
                                  ),
                                  minimumSize: const Size(78, 38),
                                  backgroundColor: isSelected
                                      ? givenAccentColor
                                      : Colors.transparent,
                                  foregroundColor: isSelected
                                      ? Colors.white
                                      : Theme.of(ctx).colorScheme.onSurface,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(999),
                                    side: const BorderSide(
                                      color: Colors.transparent,
                                    ),
                                  ),
                                ),
                                child: Text(
                                  '$year',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontWeight: isSelected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: givenAccentColor,
                            ),
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Cancel'),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: givenAccentColor,
                            ),
                            onPressed: () =>
                                Navigator.pop(ctx, dialogSelectedYear),
                            child: const Text('OK'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
      if (selectedYear == null || !mounted) return;
      setState(() {
        _selectedYear = selectedYear;
        _timeFilter = _SearchTimeFilter.year;
      });
      return;
    }

    if (filter == _SearchTimeFilter.customRange) {
      final now = DateTime.now();
      final initial =
          _customRange ??
          DateTimeRange(start: DateTime(now.year, now.month, 1), end: now);
      final picked = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2000),
        lastDate: DateTime(2100),
        initialDateRange: initial,
      );
      if (picked == null) return;
      if (!mounted) return;
      setState(() {
        _customRange = picked;
        _timeFilter = _SearchTimeFilter.customRange;
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _timeFilter = filter;
    });
  }

  void _stepMonth(int delta) {
    setState(() {
      _selectedMonth = DateTime(
        _selectedMonth.year,
        _selectedMonth.month + delta,
        1,
      );
      _timeFilter = _SearchTimeFilter.month;
    });
  }

  void _stepYear(int delta) {
    setState(() {
      _timeFilter = _SearchTimeFilter.year;
      final nextYear = _selectedYear + delta;
      if (nextYear < 2000 || nextYear > 2100) return;
      _selectedYear = nextYear;
    });
  }

  Future<void> _openCustomer(Customer customer) async {
    final seedTxs = await widget.isar.transactions
        .filter()
        .profileIdEqualTo(customer.profileId)
        .customerIdEqualTo(customer.id)
        .findAll();
    seedTxs.sort((a, b) => a.date.compareTo(b.date));
    if (!mounted) return;

    await Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => CustomerLedgerScreen(
          isar: widget.isar,
          customerId: customer.id,
          customerName: customer.name,
          profileId: customer.profileId,
          customerPhotoPath: _photoPaths[customer.id],
          initialTransactions: seedTxs,
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            child,
      ),
    );

    await _load();
  }

  Future<void> _openTransaction(txn_model.Transaction tx) async {
    final prefs = await SharedPreferences.getInstance();
    final currencyCode = prefs.getString('currencyCode') ?? 'INR';

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => TransactionDetailScreen(
          isar: widget.isar,
          transactionId: tx.id,
          currencyCode: currencyCode,
        ),
      ),
    );

    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final query = _controller.text.trim();
    final hasBaseResults =
        query.isNotEmpty &&
        (_customerNameMatchesBase.isNotEmpty ||
            _transactionMatchesBase.isNotEmpty);
    final customerMatches = _customerNameMatches;
    final transactionMatches = _transactionMatches;
    final filteredTransactionMatches = _filterTransactionMatchesByType(
      transactionMatches,
    );
    final hasAnyResults =
        customerMatches.isNotEmpty || filteredTransactionMatches.isNotEmpty;

    final monthLabel = DateFormat('MMM yyyy').format(_selectedMonth);
    final yearLabel = _selectedYear.toString();
    final customRangeLabel = _customRange == null
        ? 'Custom Range'
        : 'Custom: ${DateFormat('dd MMM').format(_customRange!.start)} - ${DateFormat('dd MMM').format(_customRange!.end)}';
    final creditOrReceivedLabel = _useGivenReceivedLabels
        ? 'Received'
        : 'Credit';
    final debitOrGivenLabel = _useGivenReceivedLabels ? 'Given' : 'Debit';
    final chipTheme = ChipTheme.of(context);
    final givenAccentColor = Colors.blue.shade600;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.profileName == null
              ? 'Search Customers'
              : 'Search • ${widget.profileName}',
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                  child: TextField(
                    controller: _controller,
                    autofocus: true,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: 'Search by customer or transaction',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _controller.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                _controller.clear();
                                setState(() {});
                              },
                            ),
                    ),
                  ),
                ),
                if (hasBaseResults)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          ChoiceChip(
                            label: Text(
                              'All time',
                              style: TextStyle(
                                color: _timeFilter == _SearchTimeFilter.allTime
                                    ? Colors.white
                                    : Theme.of(context).colorScheme.onSurface,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            showCheckmark: false,
                            shape: StadiumBorder(
                              side: BorderSide(
                                color: _timeFilter == _SearchTimeFilter.allTime
                                    ? Colors.transparent
                                    : Theme.of(
                                        context,
                                      ).colorScheme.outlineVariant,
                              ),
                            ),
                            selectedColor: givenAccentColor,
                            backgroundColor: chipTheme.backgroundColor,
                            selected: _timeFilter == _SearchTimeFilter.allTime,
                            onSelected: (_) =>
                                _selectTimeFilter(_SearchTimeFilter.allTime),
                          ),
                          const SizedBox(width: 8),
                          DecoratedBox(
                            decoration: ShapeDecoration(
                              color: _timeFilter == _SearchTimeFilter.month
                                  ? givenAccentColor
                                  : chipTheme.backgroundColor,
                              shape: StadiumBorder(
                                side: BorderSide(
                                  color: _timeFilter == _SearchTimeFilter.month
                                      ? Colors.transparent
                                      : Theme.of(
                                          context,
                                        ).colorScheme.outlineVariant,
                                ),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  onPressed: () => _stepMonth(-1),
                                  icon: Icon(
                                    Icons.chevron_left,
                                    size: 18,
                                    color:
                                        _timeFilter == _SearchTimeFilter.month
                                        ? Colors.white
                                        : Theme.of(
                                            context,
                                          ).colorScheme.onSurface,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                ),
                                InkWell(
                                  borderRadius: BorderRadius.circular(999),
                                  onTap: () => _selectTimeFilter(
                                    _SearchTimeFilter.month,
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 2,
                                      vertical: 8,
                                    ),
                                    child: Text(
                                      monthLabel,
                                      style: TextStyle(
                                        color:
                                            _timeFilter ==
                                                _SearchTimeFilter.month
                                            ? Colors.white
                                            : Theme.of(
                                                context,
                                              ).colorScheme.onSurface,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ),
                                IconButton(
                                  onPressed: () => _stepMonth(1),
                                  icon: Icon(
                                    Icons.chevron_right,
                                    size: 18,
                                    color:
                                        _timeFilter == _SearchTimeFilter.month
                                        ? Colors.white
                                        : Theme.of(
                                            context,
                                          ).colorScheme.onSurface,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          DecoratedBox(
                            decoration: ShapeDecoration(
                              color: _timeFilter == _SearchTimeFilter.year
                                  ? givenAccentColor
                                  : chipTheme.backgroundColor,
                              shape: StadiumBorder(
                                side: BorderSide(
                                  color: _timeFilter == _SearchTimeFilter.year
                                      ? Colors.transparent
                                      : Theme.of(
                                          context,
                                        ).colorScheme.outlineVariant,
                                ),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  onPressed: () => _stepYear(-1),
                                  icon: Icon(
                                    Icons.chevron_left,
                                    size: 18,
                                    color: _timeFilter == _SearchTimeFilter.year
                                        ? Colors.white
                                        : Theme.of(
                                            context,
                                          ).colorScheme.onSurface,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                ),
                                InkWell(
                                  borderRadius: BorderRadius.circular(999),
                                  onTap: () =>
                                      _selectTimeFilter(_SearchTimeFilter.year),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 2,
                                      vertical: 8,
                                    ),
                                    child: Text(
                                      yearLabel,
                                      style: TextStyle(
                                        color:
                                            _timeFilter ==
                                                _SearchTimeFilter.year
                                            ? Colors.white
                                            : Theme.of(
                                                context,
                                              ).colorScheme.onSurface,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ),
                                IconButton(
                                  onPressed: () => _stepYear(1),
                                  icon: Icon(
                                    Icons.chevron_right,
                                    size: 18,
                                    color: _timeFilter == _SearchTimeFilter.year
                                        ? Colors.white
                                        : Theme.of(
                                            context,
                                          ).colorScheme.onSurface,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: Text(
                              customRangeLabel,
                              style: TextStyle(
                                color:
                                    _timeFilter == _SearchTimeFilter.customRange
                                    ? Colors.white
                                    : Theme.of(context).colorScheme.onSurface,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            showCheckmark: false,
                            shape: StadiumBorder(
                              side: BorderSide(
                                color:
                                    _timeFilter == _SearchTimeFilter.customRange
                                    ? Colors.transparent
                                    : Theme.of(
                                        context,
                                      ).colorScheme.outlineVariant,
                              ),
                            ),
                            selectedColor: givenAccentColor,
                            backgroundColor: chipTheme.backgroundColor,
                            selected:
                                _timeFilter == _SearchTimeFilter.customRange,
                            onSelected: (_) => _selectTimeFilter(
                              _SearchTimeFilter.customRange,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                Expanded(
                  child: query.isEmpty
                      ? const Center(child: Text('Type something to Search'))
                      : !hasBaseResults
                      ? const Center(child: Text('No matching results found.'))
                      : !hasAnyResults
                      ? const Center(
                          child: Text('No matching results for selected time.'),
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                          children: [
                            if (customerMatches.isNotEmpty) ...[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
                                child: Text(
                                  'Customer Name Matches',
                                  style: Theme.of(context).textTheme.titleSmall
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                              ),
                              ...customerMatches.map((customer) {
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: ListTile(
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      side: BorderSide(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.outlineVariant,
                                      ),
                                    ),
                                    tileColor: Theme.of(context)
                                        .colorScheme
                                        .surfaceContainerHighest
                                        .withAlpha((0.3 * 255).round()),
                                    leading: CircleAvatar(
                                      backgroundColor: Theme.of(
                                        context,
                                      ).colorScheme.primaryContainer,
                                      backgroundImage:
                                          _photoPaths[customer.id] != null
                                          ? FileImage(
                                              File(_photoPaths[customer.id]!),
                                            )
                                          : null,
                                      child: _photoPaths[customer.id] == null
                                          ? Text(
                                              customer.name.isEmpty
                                                  ? '?'
                                                  : customer.name
                                                        .trim()[0]
                                                        .toUpperCase(),
                                            )
                                          : null,
                                    ),
                                    title: Text(customer.name),
                                    subtitle:
                                        (customer.phone?.trim().isNotEmpty ??
                                            false)
                                        ? Text(customer.phone!.trim())
                                        : null,
                                    onTap: () => _openCustomer(customer),
                                  ),
                                );
                              }),
                              const SizedBox(height: 8),
                            ],
                            if (transactionMatches.isNotEmpty) ...[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
                                child: Text(
                                  'Transaction Matches',
                                  style: Theme.of(context).textTheme.titleSmall
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Row(
                                    children: [
                                      ChoiceChip(
                                        label: Text(
                                          'All',
                                          style: TextStyle(
                                            color:
                                                _transactionMatchFilter ==
                                                    _TransactionMatchFilter.all
                                                ? Colors.white
                                                : Theme.of(
                                                    context,
                                                  ).colorScheme.onSurface,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                        showCheckmark: false,
                                        shape: StadiumBorder(
                                          side: BorderSide(
                                            color:
                                                _transactionMatchFilter ==
                                                    _TransactionMatchFilter.all
                                                ? Colors.transparent
                                                : Theme.of(
                                                    context,
                                                  ).colorScheme.outlineVariant,
                                          ),
                                        ),
                                        selectedColor: givenAccentColor,
                                        backgroundColor:
                                            chipTheme.backgroundColor,
                                        selected:
                                            _transactionMatchFilter ==
                                            _TransactionMatchFilter.all,
                                        onSelected: (_) {
                                          setState(() {
                                            _transactionMatchFilter =
                                                _TransactionMatchFilter.all;
                                          });
                                        },
                                      ),
                                      const SizedBox(width: 8),
                                      ChoiceChip(
                                        label: Text(
                                          creditOrReceivedLabel,
                                          style: TextStyle(
                                            color:
                                                _transactionMatchFilter ==
                                                    _TransactionMatchFilter
                                                        .creditReceived
                                                ? Colors.white
                                                : Theme.of(
                                                    context,
                                                  ).colorScheme.onSurface,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                        showCheckmark: false,
                                        shape: StadiumBorder(
                                          side: BorderSide(
                                            color:
                                                _transactionMatchFilter ==
                                                    _TransactionMatchFilter
                                                        .creditReceived
                                                ? Colors.transparent
                                                : Theme.of(
                                                    context,
                                                  ).colorScheme.outlineVariant,
                                          ),
                                        ),
                                        selectedColor: givenAccentColor,
                                        backgroundColor:
                                            chipTheme.backgroundColor,
                                        selected:
                                            _transactionMatchFilter ==
                                            _TransactionMatchFilter
                                                .creditReceived,
                                        onSelected: (_) {
                                          setState(() {
                                            _transactionMatchFilter =
                                                _TransactionMatchFilter
                                                    .creditReceived;
                                          });
                                        },
                                      ),
                                      const SizedBox(width: 8),
                                      ChoiceChip(
                                        label: Text(
                                          debitOrGivenLabel,
                                          style: TextStyle(
                                            color:
                                                _transactionMatchFilter ==
                                                    _TransactionMatchFilter
                                                        .debitGiven
                                                ? Colors.white
                                                : Theme.of(
                                                    context,
                                                  ).colorScheme.onSurface,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                        showCheckmark: false,
                                        shape: StadiumBorder(
                                          side: BorderSide(
                                            color:
                                                _transactionMatchFilter ==
                                                    _TransactionMatchFilter
                                                        .debitGiven
                                                ? Colors.transparent
                                                : Theme.of(
                                                    context,
                                                  ).colorScheme.outlineVariant,
                                          ),
                                        ),
                                        selectedColor: givenAccentColor,
                                        backgroundColor:
                                            chipTheme.backgroundColor,
                                        selected:
                                            _transactionMatchFilter ==
                                            _TransactionMatchFilter.debitGiven,
                                        onSelected: (_) {
                                          setState(() {
                                            _transactionMatchFilter =
                                                _TransactionMatchFilter
                                                    .debitGiven;
                                          });
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (filteredTransactionMatches.isEmpty)
                                const Padding(
                                  padding: EdgeInsets.fromLTRB(8, 0, 8, 8),
                                  child: Text(
                                    'No transaction matches for selected option.',
                                  ),
                                ),
                              ...filteredTransactionMatches.map((tx) {
                                final customer = _customerById[tx.customerId];
                                final amountColor =
                                    tx.type == TransactionType.credit
                                    ? Colors.green
                                    : Theme.of(context).colorScheme.error;
                                final amountText =
                                    tx.amount == tx.amount.truncateToDouble()
                                    ? tx.amount.toInt().toString()
                                    : tx.amount.toStringAsFixed(2);
                                final description =
                                    (tx.note?.trim().isNotEmpty ?? false)
                                    ? tx.note!.trim()
                                    : '';

                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: ListTile(
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      side: BorderSide(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.outlineVariant,
                                      ),
                                    ),
                                    tileColor: Theme.of(context)
                                        .colorScheme
                                        .surfaceContainerHighest
                                        .withAlpha((0.3 * 255).round()),
                                    title: Text(
                                      description,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text(
                                      '${customer?.name ?? 'Unknown Customer'} • ${DateFormat('dd MMM yyyy').format(tx.date)}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing: Text(
                                      '$_currencyCode $amountText',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                        color: amountColor,
                                      ),
                                    ),
                                    onTap: () => _openTransaction(tx),
                                  ),
                                );
                              }),
                            ],
                          ],
                        ),
                ),
              ],
            ),
    );
  }
}

enum _ProfileSheetActionType { switchProfile, createProfile, profileActions }

enum _EditCustomerSheetAction { cancel, save }

enum _SearchTimeFilter { allTime, month, year, customRange }

enum _TransactionMatchFilter { all, creditReceived, debitGiven }

class _ProfileSheetAction {
  final _ProfileSheetActionType type;
  final int? profileId;
  final String? profileName;

  const _ProfileSheetAction({
    required this.type,
    this.profileId,
    this.profileName,
  });
}
