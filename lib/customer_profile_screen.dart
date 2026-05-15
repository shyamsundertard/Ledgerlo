import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:isar/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';

import 'core/enums/transaction_type.dart';
import 'data/models/customer.dart';
import 'data/models/transaction.dart' as txn_model;
import 'providers/settings_provider.dart';
import 'utils/transaction_labels.dart';

class CustomerProfileScreen extends StatefulWidget {
  final Isar isar;
  final int customerId;
  final int profileId;
  final String customerName;
  final String currencyCode;

  const CustomerProfileScreen({
    super.key,
    required this.isar,
    required this.customerId,
    required this.profileId,
    required this.customerName,
    required this.currencyCode,
  });

  @override
  State<CustomerProfileScreen> createState() => _CustomerProfileScreenState();
}

class _CustomerProfileScreenState extends State<CustomerProfileScreen> {
  late Future<_CustomerProfileData> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadData();
  }

  Future<_CustomerProfileData> _loadData() async {
    final customer = await widget.isar.customers.get(widget.customerId);
    final prefs = await SharedPreferences.getInstance();
    final profilePhotoPath = prefs.getString(_photoStorageKey);
    final savedLabelStyle = prefs.getString('transactionLabelStyle');
    final labelStyle = savedLabelStyle == 'givenReceived'
      ? TransactionLabelStyle.givenReceived
      : TransactionLabelStyle.creditDebit;
    final transactions = await widget.isar.transactions
        .filter()
        .profileIdEqualTo(widget.profileId)
        .customerIdEqualTo(widget.customerId)
        .isDeletedEqualTo(false)
        .findAll();

    double balance = 0;
    int creditCount = 0;
    int debitCount = 0;
    double creditedAmount = 0;
    double debitedAmount = 0;

    for (final tx in transactions) {
      if (tx.type == TransactionType.credit) {
        creditCount++;
        creditedAmount += tx.amount;
        balance += tx.amount;
      } else {
        debitCount++;
        debitedAmount += tx.amount;
        balance -= tx.amount;
      }
    }

    DateTime? lastTxnDate;
    if (transactions.isNotEmpty) {
      transactions.sort((a, b) => b.date.compareTo(a.date));
      lastTxnDate = transactions.first.date;
    }

    return _CustomerProfileData(
      customer: customer,
      profilePhotoPath: profilePhotoPath,
      balance: balance,
      creditCount: creditCount,
      debitCount: debitCount,
      creditedAmount: creditedAmount,
      debitedAmount: debitedAmount,
      totalTransactions: transactions.length,
      lastTransactionDate: lastTxnDate,
      labelStyle: labelStyle,
    );
  }

  String get _photoStorageKey =>
      'customer_profile_photo_${widget.profileId}_${widget.customerId}';

  Future<void> _pickProfilePhoto() async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 80,
        maxWidth: 1600,
      );
      if (picked == null || picked.path.trim().isEmpty) return;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_photoStorageKey, picked.path);
      if (!mounted) return;
      setState(() {
        _future = _loadData();
      });
    } catch (_) {}
  }

  Future<void> _removeProfilePhoto() async {
    final shouldRemove =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Remove profile photo?'),
            content: const Text('This will remove the customer profile photo.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Remove'),
              ),
            ],
          ),
        ) ??
        false;

    if (!shouldRemove) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_photoStorageKey);
    if (!mounted) return;
    setState(() {
      _future = _loadData();
    });
  }

  Future<void> _showEditCustomerDialog(Customer customer) async {
    final nameController = TextEditingController(text: customer.name);
    final phoneController = TextEditingController(text: customer.phone ?? '');

    final didSave = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          final bottomInset = MediaQuery.of(sheetContext).viewInsets.bottom;
          final canSave = nameController.text.trim().isNotEmpty;
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
                        'Edit customer',
                        style: sheetTheme.textTheme.titleLarge,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: nameController,
                        autofocus: true,
                        decoration: const InputDecoration(
                          labelText: 'Customer name',
                        ),
                        onChanged: (_) => setSheetState(() {}),
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
                              onPressed: () => Navigator.pop(sheetContext, false),
                              child: const Text('Cancel'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton(
                              onPressed: canSave
                                  ? () => Navigator.pop(sheetContext, true)
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

    if (didSave != true || updatedName.isEmpty) return;

    await widget.isar.writeTxn(() async {
      customer.name = updatedName;
      customer.phone = updatedPhone.isEmpty ? null : updatedPhone;
      customer.updatedAt = DateTime.now();
      await widget.isar.customers.put(customer);
    });

    if (!mounted) return;
    setState(() {
      _future = _loadData();
    });
  }

  String _formatAmount(double amount) {
    final formatter = NumberFormat.simpleCurrency(name: widget.currencyCode);
    final intFormatter = NumberFormat.simpleCurrency(
      name: widget.currencyCode,
      decimalDigits: 0,
    );
    if (amount == amount.toInt()) {
      return intFormatter.format(amount);
    }
    return formatter.format(amount);
  }

  String _formatDateTime(DateTime dateTime) {
    final raw = DateFormat("MMM d, y 'at' h:mm a").format(dateTime);
    return raw.replaceAll('AM', 'am').replaceAll('PM', 'pm');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: const Text('Customer Profile'),
      ),
      body: FutureBuilder<_CustomerProfileData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          final data = snapshot.data;
          if (data == null || data.customer == null) {
            return const Center(child: Text('Customer not found.'));
          }

          final customer = data.customer!;
          final colorScheme = Theme.of(context).colorScheme;
          final balanceColor = data.balance >= 0
              ? (Theme.of(context).brightness == Brightness.light
                    ? Colors.green.shade700
                    : Colors.green.shade400)
              : colorScheme.error;

          return ListView(
            padding: const EdgeInsets.all(14),
            children: [
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(
                    color: colorScheme.outlineVariant.withAlpha(180),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          CircleAvatar(
                            radius: 28,
                            backgroundImage: data.profilePhotoPath != null
                                ? FileImage(File(data.profilePhotoPath!))
                                : null,
                            child: data.profilePhotoPath == null
                                ? Text(
                                    customer.name.trim().isEmpty
                                        ? '?'
                                        : customer.name
                                              .trim()
                                              .split(' ')
                                              .map(
                                                (e) => e.isNotEmpty ? e[0] : '',
                                              )
                                              .take(2)
                                              .join()
                                              .toUpperCase(),
                                  )
                                : null,
                          ),
                          Positioned(
                            right: -4,
                            bottom: -4,
                            child: Material(
                              color: colorScheme.primary,
                              shape: const CircleBorder(),
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap: _pickProfilePhoto,
                                child: const Padding(
                                  padding: EdgeInsets.all(5),
                                  child: Icon(
                                    Icons.camera_alt_rounded,
                                    size: 14,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    customer.name,
                                    style: Theme.of(context).textTheme.titleLarge,
                                  ),
                                ),
                                IconButton(
                                  onPressed: () => _showEditCustomerDialog(customer),
                                  icon: const Icon(Icons.edit_outlined),
                                  tooltip: 'Edit details',
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              customer.phone?.trim().isNotEmpty == true
                                  ? customer.phone!.trim()
                                  : 'No phone number',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 8,
                              children: [
                                FilledButton.tonalIcon(
                                  onPressed: _pickProfilePhoto,
                                  icon: const Icon(Icons.photo_library_outlined),
                                  label: Text(
                                    data.profilePhotoPath == null
                                        ? 'Add Photo'
                                        : 'Change Photo',
                                  ),
                                ),
                                if (data.profilePhotoPath != null)
                                  IconButton(
                                    onPressed: _removeProfilePhoto,
                                    icon: const Icon(Icons.delete_outline),
                                    tooltip: 'Remove photo',
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
              const SizedBox(height: 10),
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(
                    color: colorScheme.outlineVariant.withAlpha(180),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Current Balance',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _formatAmount(data.balance.abs()),
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              color: balanceColor,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        data.balance >= 0 ? 'Advance' : 'Due',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: balanceColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(
                    color: colorScheme.outlineVariant.withAlpha(180),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Customer Analytics',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: _profileMetricTile(
                              context: context,
                              icon: Icons.receipt_long_outlined,
                              title: 'Transactions',
                              value: '${data.totalTransactions}',
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _profileMetricTile(
                              context: context,
                              icon: Icons.schedule_outlined,
                              title: 'Last Txn',
                              value: data.lastTransactionDate == null
                                  ? 'N/A'
                                  : DateFormat('dd MMM').format(
                                      data.lastTransactionDate!,
                                    ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: _profileMetricTile(
                              context: context,
                              icon: Icons.arrow_downward,
                              title: getTransactionLabel(data.labelStyle, true),
                              value: _formatAmount(data.creditedAmount),
                              subtitle: '${data.creditCount} entries',
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _profileMetricTile(
                              context: context,
                              icon: Icons.arrow_upward,
                              title: getTransactionLabel(data.labelStyle, false),
                              value: _formatAmount(data.debitedAmount),
                              subtitle: '${data.debitCount} entries',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _inlineStat(
                        context,
                        label: 'Last transaction date/time',
                        value: data.lastTransactionDate == null
                            ? 'N/A'
                            : _formatDateTime(data.lastTransactionDate!),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _profileMetricTile({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String value,
    String? subtitle,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withAlpha(150),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(height: 6),
          Text(title, style: theme.textTheme.labelSmall),
          const SizedBox(height: 2),
          Text(
            value,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }

  Widget _inlineStat(
    BuildContext context, {
    required String label,
    required String value,
  }) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withAlpha(120),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelSmall),
          const SizedBox(height: 2),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _CustomerProfileData {
  final Customer? customer;
  final String? profilePhotoPath;
  final double balance;
  final int creditCount;
  final int debitCount;
  final double creditedAmount;
  final double debitedAmount;
  final int totalTransactions;
  final DateTime? lastTransactionDate;
  final TransactionLabelStyle labelStyle;

  const _CustomerProfileData({
    required this.customer,
    required this.profilePhotoPath,
    required this.balance,
    required this.creditCount,
    required this.debitCount,
    required this.creditedAmount,
    required this.debitedAmount,
    required this.totalTransactions,
    required this.lastTransactionDate,
    required this.labelStyle,
  });
}
