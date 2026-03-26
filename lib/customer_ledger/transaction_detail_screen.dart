import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:isar/isar.dart';
import 'package:ledger_app/core/enums/transaction_type.dart';
import 'package:ledger_app/customer_ledger/edit_transaction_dialog.dart';
import 'package:ledger_app/data/models/transaction.dart' as txn_model;
import 'package:ledger_app/providers/settings_provider.dart';
import 'package:ledger_app/utils/transaction_labels.dart';

enum _DeleteAction { soft, hard }

class TransactionDetailScreen extends ConsumerStatefulWidget {
  final Isar isar;
  final int transactionId;
  final String currencyCode;

  const TransactionDetailScreen({
    super.key,
    required this.isar,
    required this.transactionId,
    required this.currencyCode,
  });

  @override
  ConsumerState<TransactionDetailScreen> createState() =>
      _TransactionDetailScreenState();
}

class _TransactionDetailScreenState
    extends ConsumerState<TransactionDetailScreen> {
  txn_model.Transaction? _transaction;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadTransaction();
  }

  Future<void> _loadTransaction() async {
    final transaction = await widget.isar.transactions.get(
      widget.transactionId,
    );
    if (!mounted) return;
    setState(() {
      _transaction = transaction;
      _isLoading = false;
    });
  }

  List<String> _photoPaths(txn_model.Transaction transaction) {
    if (transaction.photoPaths.isNotEmpty) {
      return transaction.photoPaths
          .where((path) => path.trim().isNotEmpty)
          .take(3)
          .toList();
    }
    final legacyPath = transaction.photoPath;
    if (legacyPath == null || legacyPath.trim().isEmpty) {
      return const [];
    }
    return [legacyPath];
  }

  Future<ImageSource?> _pickImageSource(BuildContext context) {
    return showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose bill from gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Capture bill'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
          ],
        ),
      ),
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;
  }

  Future<List<String>> _pickPhotos({required int remainingSlots}) async {
    if (remainingSlots <= 0) return const [];

    final source = await _pickImageSource(context);
    if (source == null) return const [];

    try {
      final picker = ImagePicker();
      if (source == ImageSource.gallery) {
        final images = await picker.pickMultiImage(
          imageQuality: 80,
          maxWidth: 1800,
        );
        if (images.isEmpty) return const [];

        final pickedPaths = images
            .map((image) => image.path)
            .where((path) => path.trim().isNotEmpty)
            .toList();

        if (pickedPaths.length > remainingSlots) {
          _showMessage('You can add only $remainingSlots more bill(s).');
        }

        return pickedPaths.take(remainingSlots).toList();
      }

      final image = await picker.pickImage(
        source: source,
        imageQuality: 80,
        maxWidth: 1800,
      );
      if (image == null || image.path.trim().isEmpty) return const [];
      return [image.path];
    } catch (_) {
      _showMessage('Could not pick bill. Please try again.');
      return const [];
    }
  }

  Future<void> _savePhotoPaths(List<String> photoPaths) async {
    final transaction = _transaction;
    if (transaction == null) return;

    await widget.isar.writeTxn(() async {
      transaction.photoPaths = List<String>.from(photoPaths);
      transaction.photoPath = photoPaths.isEmpty ? null : photoPaths.first;
      transaction.isEdited = true;
      transaction.updatedAt = DateTime.now();
      await widget.isar.transactions.put(transaction);
    });

    await _loadTransaction();
  }

  Future<void> _addPhotos() async {
    final transaction = _transaction;
    if (transaction == null) return;

    final existing = _photoPaths(transaction);
    final picked = await _pickPhotos(remainingSlots: 3 - existing.length);
    if (picked.isEmpty) {
      _showMessage('No bill selected.');
      return;
    }

    final uniqueNew = picked.where((path) => !existing.contains(path)).toList();
    if (uniqueNew.isEmpty) {
      _showMessage('This bill is already attached.');
      return;
    }

    if (uniqueNew.length < picked.length) {
      _showMessage('Some selected bills were already attached.');
    }

    await _savePhotoPaths([...existing, ...uniqueNew]);
  }

  Future<void> _removePhotoAt(int index) async {
    final transaction = _transaction;
    if (transaction == null) return;

    final shouldRemove =
        await showDialog<bool>(
          context: context,
          builder: (confirmCtx) => AlertDialog(
            title: const Text('Remove bill?'),
            content: const Text('Do you want to remove this attached bill?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(confirmCtx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(confirmCtx, true),
                child: const Text('Remove'),
              ),
            ],
          ),
        ) ??
        false;
    if (!shouldRemove) return;

    final existing = _photoPaths(transaction);
    if (index < 0 || index >= existing.length) return;

    existing.removeAt(index);
    await _savePhotoPaths(existing);
  }

  void _showEditDialogSnackBar(
    BuildContext context,
    String message,
    Color backgroundColor,
    IconData icon,
  ) {
    if (!mounted) return;
  }

  Future<void> _openEditTransaction() async {
    final transaction = _transaction;
    if (transaction == null) return;

    await EditTransactionDialog.show(
      context: context,
      ref: ref,
      transaction: transaction,
      isar: widget.isar,
      onTransactionUpdated: (_) async {
        await _loadTransaction();
      },
      onShowSnackBar: _showEditDialogSnackBar,
    );
  }

  Future<bool> _confirmDelete({
    required String title,
    required String content,
    required String confirmLabel,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(title),
            content: Text(content),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(confirmLabel),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _softDeleteTransaction() async {
    final transaction = _transaction;
    if (transaction == null) return;

    await widget.isar.writeTxn(() async {
      transaction.isDeleted = true;
      transaction.isEdited = true;
      transaction.updatedAt = DateTime.now();
      await widget.isar.transactions.put(transaction);
    });
  }

  Future<void> _hardDeleteTransaction() async {
    final transaction = _transaction;
    if (transaction == null) return;

    await widget.isar.writeTxn(() async {
      await widget.isar.transactions.delete(transaction.id);
    });
  }

  Future<void> _showDeleteOptions() async {
    final transaction = _transaction;
    if (transaction == null) return;

    final action = await showModalBottomSheet<_DeleteAction>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Soft delete transaction'),
              subtitle: const Text('Move it to deleted transactions'),
              enabled: !transaction.isDeleted,
              onTap: () => Navigator.pop(ctx, _DeleteAction.soft),
            ),
            ListTile(
              leading: Icon(
                Icons.delete_forever_outlined,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                'Delete permanently',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              subtitle: const Text('This action cannot be undone'),
              onTap: () => Navigator.pop(ctx, _DeleteAction.hard),
            ),
          ],
        ),
      ),
    );

    if (action == null || !mounted) return;

    if (action == _DeleteAction.soft) {
      final confirmed = await _confirmDelete(
        title: 'Soft delete transaction',
        content: 'Move this transaction to deleted transactions?',
        confirmLabel: 'Delete',
      );
      if (!confirmed) return;

      await _softDeleteTransaction();
      if (!mounted) return;
      Navigator.pop(context, true);
      return;
    }

    final confirmed = await _confirmDelete(
      title: 'Delete permanently',
      content: 'Permanently delete this transaction? This cannot be undone.',
      confirmLabel: 'Delete permanently',
    );
    if (!confirmed) return;

    await _hardDeleteTransaction();
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  void _openPhoto(Uint8List imageBytes) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
          ),
          body: Center(
            child: InteractiveViewer(
              minScale: 0.8,
              maxScale: 4,
              child: Image.memory(imageBytes, fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }

  String _formatAmount(double amount) {
    final intFormatter = NumberFormat.simpleCurrency(
      name: widget.currencyCode,
      decimalDigits: 0,
    );
    final formatter = NumberFormat.simpleCurrency(name: widget.currencyCode);
    if (amount == amount.toInt()) {
      return intFormatter.format(amount);
    }
    return formatter.format(amount);
  }

  String _formatDateTime(DateTime dateTime) {
    final raw = DateFormat("MMM d, y 'at' h:mm a").format(dateTime);
    return raw.replaceAll('AM', 'am').replaceAll('PM', 'pm');
  }

  Widget _notebookLine(BuildContext context, String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final transaction = _transaction;
    if (transaction == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Transaction details')),
        body: const Center(child: Text('Transaction not found.')),
      );
    }

    final photoPaths = _photoPaths(transaction);

    final typeIsCredit = transaction.type == TransactionType.credit;
    final labelStyle = ref.watch(settingsProvider);
    final typeLabel = getTransactionLabel(labelStyle, typeIsCredit);
    final typeChipBg = typeIsCredit
        ? (Theme.of(context).brightness == Brightness.light
              ? Colors.green.shade100
              : Colors.green.shade900)
        : (Theme.of(context).brightness == Brightness.light
              ? Colors.red.shade100
              : Colors.red.shade900);
    final typeChipFg = typeIsCredit
        ? (Theme.of(context).brightness == Brightness.light
              ? Colors.green.shade900
              : Colors.green.shade100)
        : (Theme.of(context).brightness == Brightness.light
              ? Colors.red.shade900
              : Colors.red.shade100);
    final ledgerTint = Theme.of(
      context,
    ).colorScheme.primary.withAlpha((0.18 * 255).round());
    final appBarTint =
        Theme.of(context).appBarTheme.backgroundColor ??
        Theme.of(context).colorScheme.primaryContainer;

    return Scaffold(
      appBar: AppBar(title: const Text('Transaction details')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 110),
        children: [
          Card(
            color: ledgerTint,
            surfaceTintColor: ledgerTint,
            elevation: 0,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _formatAmount(transaction.amount),
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: typeChipBg,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          typeLabel,
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(
                                color: typeChipFg,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _notebookLine(
                    context,
                    'Billed on ${_formatDateTime(transaction.date)}',
                  ),
                  _notebookLine(
                    context,
                    'Added on ${_formatDateTime(transaction.createdAt)}',
                  ),
                  _notebookLine(
                    context,
                    'Edited on ${_formatDateTime(transaction.updatedAt)}',
                  ),
                  if ((transaction.note ?? '').trim().isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Note: ',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        Expanded(
                          child: Text(
                            transaction.note!.trim(),
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _openEditTransaction,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Edit Transaction'),
                  style: FilledButton.styleFrom(
                    backgroundColor: appBarTint,
                  ),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _showDeleteOptions,
                  icon: Icon(
                    Icons.delete_outline,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  label: Text(
                    'Delete',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            color: ledgerTint,
            surfaceTintColor: ledgerTint,
            elevation: 0,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Bills',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const Spacer(),
                      Text(
                        '${photoPaths.length}/3',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(width: 10),
                      FilledButton.tonalIcon(
                        onPressed: photoPaths.length >= 3 ? null : _addPhotos,
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        label: const Text('Attach'),
                        style: FilledButton.styleFrom(
                          backgroundColor: appBarTint,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (photoPaths.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 14,
                      ),
                      // child: const Text('No photos attached.'),
                      child: const Text('No bills attached.'),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: List.generate(photoPaths.length, (index) {
                        final path = photoPaths[index];
                        return Stack(
                          clipBehavior: Clip.none,
                          children: [
                            FutureBuilder<Uint8List>(
                              future: XFile(path).readAsBytes(),
                              builder: (context, snapshot) {
                                if (snapshot.connectionState ==
                                    ConnectionState.waiting) {
                                  return Container(
                                    width: 64,
                                    height: 64,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(8),
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.surfaceContainerHighest,
                                    ),
                                    child: const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  );
                                }

                                if (!snapshot.hasData ||
                                    snapshot.data!.isEmpty) {
                                  return Container(
                                    width: 64,
                                    height: 64,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(8),
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.surfaceContainerHighest,
                                    ),
                                    child: const Icon(
                                      Icons.broken_image_outlined,
                                    ),
                                  );
                                }

                                final bytes = snapshot.data!;
                                return GestureDetector(
                                  onTap: () => _openPhoto(bytes),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.memory(
                                      bytes,
                                      width: 64,
                                      height: 64,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                );
                              },
                            ),
                            Positioned(
                              top: -6,
                              right: -6,
                              child: Material(
                                color: Theme.of(context).colorScheme.surface,
                                shape: const CircleBorder(),
                                child: InkWell(
                                  customBorder: const CircleBorder(),
                                  onTap: () => _removePhotoAt(index),
                                  child: const Padding(
                                    padding: EdgeInsets.all(3),
                                    child: Icon(Icons.close, size: 14),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      }),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
