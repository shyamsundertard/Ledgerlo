// ignore_for_file: use_build_context_synchronously
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar/isar.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:permission_handler/permission_handler.dart';
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/models/customer.dart';
import 'data/models/transaction.dart' as txn_model;
import 'core/enums/transaction_type.dart';
import 'providers/currency_provider.dart';
import 'providers/settings_provider.dart';
import 'utils/transaction_labels.dart';

// Import split modules
import 'customer_ledger/transaction_utils.dart';
import 'customer_ledger/snackbar_manager.dart';
import 'customer_ledger/transaction_tile_builder.dart';
import 'customer_ledger/edit_transaction_dialog.dart';
import 'customer_ledger/add_transaction_dialog.dart';
import 'customer_ledger/transaction_detail_screen.dart';
import 'customer_profile_screen.dart';

class CustomerLedgerScreen extends ConsumerStatefulWidget {
  final Isar isar;
  final int customerId;
  final String customerName;
  final int profileId;
  final String? customerPhotoPath;
  final List<txn_model.Transaction>? initialTransactions;
  const CustomerLedgerScreen({
    super.key,
    required this.isar,
    required this.customerId,
    required this.customerName,
    required this.profileId,
    this.customerPhotoPath,
    this.initialTransactions,
  });

  @override
  ConsumerState<CustomerLedgerScreen> createState() =>
      _CustomerLedgerScreenState();
}

enum _ExportRangePreset {
  all,
  afterLatestZeroBalance,
  last7Days,
  last30Days,
  thisMonth,
  custom,
}

enum _ExportAction { download, share }

class _ExportSelection {
  final List<txn_model.Transaction> transactions;
  final String label;
  final _ExportAction action;

  const _ExportSelection({
    required this.transactions,
    required this.label,
    required this.action,
  });
}

class _CustomerLedgerScreenState extends ConsumerState<CustomerLedgerScreen> {
  static const MethodChannel _fileOpsChannel = MethodChannel(
    'com.ledgerlo.app/file_ops',
  );
  static const MethodChannel _legacyFileOpsChannel = MethodChannel(
    'com.ledgerlo.app/files_ops',
  );

  List<txn_model.Transaction> _transactions = [];
  final TextEditingController _searchController = TextEditingController();
  bool _showSearchBar = false;
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _currentTransactionsAnchorKey = GlobalKey();
  bool _autoScrollToBottom = false;
  double? _pendingScrollOffset;
  bool _scrollAdjustmentScheduled = false;
  bool _showOldTransactions = false;
  final List<OverlayEntry> _overlayEntries = [];
  final List<Timer> _overlayTimers = [];
  bool _isDebitButtonAnimating = false;
  bool _isCreditButtonAnimating = false;
  bool _isAddTransactionActionRunning = false;

  @override
  void initState() {
    super.initState();
    final seed = widget.initialTransactions;
    if (seed != null) {
      final initial = [...seed];
      initial.sort((a, b) => a.date.compareTo(b.date));
      _transactions = initial;
    }
    _loadTransactions();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _scrollController.dispose();
    for (final t in _overlayTimers) {
      try {
        t.cancel();
      } catch (_) {}
    }
    _overlayTimers.clear();
    for (final e in _overlayEntries) {
      try {
        if (e.mounted) e.remove();
      } catch (_) {}
    }
    _overlayEntries.clear();
    super.dispose();
  }

  void _loadTransactions() async {
    final txs = await widget.isar.transactions
        .filter()
        .profileIdEqualTo(widget.profileId)
        .customerIdEqualTo(widget.customerId)
        .findAll();
    txs.sort((a, b) => a.date.compareTo(b.date));

    if (!mounted) return;

    _applyLoadedTransactions(txs);
  }

  Future<void> _openAdjacentCustomer({required bool next}) async {
    final customers = await widget.isar.customers
        .filter()
        .profileIdEqualTo(widget.profileId)
        .sortByName()
        .findAll();

    if (!mounted) return;

    final currentIndex = customers.indexWhere(
      (customer) => customer.id == widget.customerId,
    );

    if (currentIndex < 0) {
      _showTopSnackBar(
        context,
        'Current customer not found',
        const Color(0xFFDC2626),
        Icons.error_outline,
      );
      return;
    }

    final targetIndex = next ? currentIndex + 1 : currentIndex - 1;
    if (targetIndex < 0) {
      _showTopSnackBar(
        context,
        'You are already viewing the first customer.',
        const Color(0xFF2563EB),
        Icons.info_outline,
      );
      return;
    }
    if (targetIndex >= customers.length) {
      _showTopSnackBar(
        context,
        'You are already viewing the last customer.',
        const Color(0xFF2563EB),
        Icons.info_outline,
      );
      return;
    }

    final targetCustomer = customers[targetIndex];
    final prefs = await SharedPreferences.getInstance();
    final photoPath = prefs.getString(
      'customer_profile_photo_${widget.profileId}_${targetCustomer.id}',
    );

    if (!mounted) return;

    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => CustomerLedgerScreen(
          isar: widget.isar,
          customerId: targetCustomer.id,
          customerName: targetCustomer.name,
          profileId: widget.profileId,
          customerPhotoPath: photoPath,
        ),
      ),
    );
  }

  void _onAppBarHorizontalSwipe(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 150) return;
    if (velocity < 0) {
      _openAdjacentCustomer(next: true);
    } else {
      _openAdjacentCustomer(next: false);
    }
  }

  void _applyLoadedTransactions(List<txn_model.Transaction> txs) {
    if (!mounted) return;

    setState(() {
      _transactions = txs;
    });
    _scheduleScrollAdjustment();
  }

  void _scheduleScrollAdjustment() {
    if (_scrollAdjustmentScheduled || !mounted) return;
    _scrollAdjustmentScheduled = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollAdjustmentScheduled = false;
      if (!mounted) return;
      if (!_scrollController.hasClients) {
        _scheduleScrollAdjustment();
        return;
      }

      if (_pendingScrollOffset != null) {
        try {
          final min = _scrollController.position.minScrollExtent;
          final max = _scrollController.position.maxScrollExtent;
          final target = _pendingScrollOffset!.clamp(min, max).toDouble();
          _scrollController.jumpTo(target);
        } catch (_) {}
        _pendingScrollOffset = null;
        return;
      }

      if (_autoScrollToBottom) {
        try {
          _scrollController.jumpTo(_scrollController.position.minScrollExtent);
        } catch (_) {}
        _autoScrollToBottom = false;
      }
    });
  }

  void _showTopSnackBar(
    BuildContext context,
    String message,
    Color backgroundColor,
    IconData icon,
  ) {
    SnackBarManager.showTopSnackBar(
      context,
      message,
      backgroundColor,
      icon,
      _overlayEntries,
      _overlayTimers,
    );
  }

  void _refreshTransactionsPreserveScroll() async {
    _autoScrollToBottom = false;
    final offset = _scrollController.hasClients
        ? _scrollController.offset
        : null;
    _pendingScrollOffset = offset;

    final txs = await widget.isar.transactions
        .filter()
        .profileIdEqualTo(widget.profileId)
        .customerIdEqualTo(widget.customerId)
        .findAll();
    txs.sort((a, b) => a.date.compareTo(b.date));

    _applyLoadedTransactions(txs);
  }

  Future<void> _softDelete(txn_model.Transaction t) async {
    await widget.isar.writeTxn(() async {
      t.isDeleted = true;
      t.updatedAt = DateTime.now();
      await widget.isar.transactions.put(t);
    });
    _refreshTransactionsPreserveScroll();
  }

  Future<void> _hardDelete(txn_model.Transaction t) async {
    await widget.isar.writeTxn(() async {
      await widget.isar.transactions.delete(t.id);
    });
    _refreshTransactionsPreserveScroll();
  }

  Future<void> _undoDelete(txn_model.Transaction t) async {
    await widget.isar.writeTxn(() async {
      t.isDeleted = false;
      t.updatedAt = DateTime.now();
      await widget.isar.transactions.put(t);
    });
    _refreshTransactionsPreserveScroll();
  }

  Future<void> _editTransaction(txn_model.Transaction t) async {
    await EditTransactionDialog.show(
      context: context,
      ref: ref,
      transaction: t,
      isar: widget.isar,
      onTransactionUpdated: (updatedTransaction) {
        _autoScrollToBottom = true;
        _loadTransactions();
        setState(() {});
      },
      onShowSnackBar: _showTopSnackBar,
    );
  }

  Future<void> _openTransactionDetails(txn_model.Transaction t) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TransactionDetailScreen(
          isar: widget.isar,
          transactionId: t.id,
          currencyCode: ref.read(currencyProvider),
        ),
      ),
    );
    _refreshTransactionsPreserveScroll();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _showAddTransactionDialog(TransactionType type) async {
    await AddTransactionDialog.show(
      context: context,
      ref: ref,
      type: type,
      customerId: widget.customerId,
      profileId: widget.profileId,
      isar: widget.isar,
      onTransactionAdded: () {
        _autoScrollToBottom = true;
        _loadTransactions();
        setState(() {});
      },
      onShowSnackBar: _showTopSnackBar,
    );
  }

  Future<void> _animateAndShowAddTransactionDialog(TransactionType type) async {
    if (_isAddTransactionActionRunning) return;
    _isAddTransactionActionRunning = true;

    if (mounted) {
      setState(() {
        if (type == TransactionType.debit) {
          _isDebitButtonAnimating = true;
        } else {
          _isCreditButtonAnimating = true;
        }
      });
    }

    await Future.delayed(const Duration(milliseconds: 110));

    if (mounted) {
      setState(() {
        _isDebitButtonAnimating = false;
        _isCreditButtonAnimating = false;
      });
    }

    await _showAddTransactionDialog(type);
    _isAddTransactionActionRunning = false;
  }

  Future<_ExportSelection?> _pickExportSelection(
    List<txn_model.Transaction> sortedTxs,
  ) async {
    if (sortedTxs.isEmpty) return null;
    final currencyCode = ref.read(currencyProvider);
    final labelStyle = ref.read(settingsProvider);

    return Navigator.of(context).push<_ExportSelection>(
      MaterialPageRoute(
        builder: (_) => _PdfRangePreviewPage(
          transactions: sortedTxs,
          currencyCode: currencyCode,
          labelStyle: labelStyle,
        ),
      ),
    );
  }

  Future<String> _savePdfToDownloads(Uint8List bytes, String filename) async {
    final safeName = filename.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    if (Platform.isAndroid) {
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/$safeName');
      await tempFile.writeAsBytes(bytes, flush: true);

      String? savedUri;
      try {
        savedUri = await _fileOpsChannel.invokeMethod<String>(
          'savePdfToDownloads',
          {'sourceFilePath': tempFile.path, 'fileName': safeName},
        );
      } on MissingPluginException {
        savedUri = await _legacyFileOpsChannel.invokeMethod<String>(
          'savePdfToDownloads',
          {'sourceFilePath': tempFile.path, 'fileName': safeName},
        );
      }

      try {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      } catch (_) {}

      if (savedUri == null || savedUri.isEmpty) {
        throw Exception('Could not save PDF to Downloads');
      }
      return savedUri;
    }

    final dotIndex = safeName.lastIndexOf('.');
    final baseName = dotIndex > 0 ? safeName.substring(0, dotIndex) : safeName;

    return FileSaver.instance.saveFile(
      name: baseName,
      bytes: bytes,
      fileExtension: 'pdf',
      mimeType: MimeType.pdf,
    );
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

  Future<String?> _pickZipExportDirectory() async {
    final selected = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose folder to save customer ZIP',
    );

    if (selected == null || selected.trim().isEmpty) {
      return null;
    }

    final hasPermission = await _ensureAndroidStoragePermissionForPath(selected);
    if (!hasPermission) {
      if (!mounted) return null;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Storage Access Required'),
          content: const Text(
            'Please grant "All files access" for this app in Android settings and choose the folder again.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return null;
    }

    final trimmed = selected.trim();
    if (trimmed == Platform.pathSeparator) {
      if (!mounted) return null;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Invalid Folder'),
          content: const Text(
            'The selected location is not writable. Please choose a specific folder (for example, Downloads or Documents).',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return null;
    }

    if (trimmed.startsWith('content://')) {
      if (!mounted) return null;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Folder Not Supported'),
          content: const Text(
            'This folder path is not directly writable on this device. Please choose a standard local folder path.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return null;
    }

    final dir = Directory(trimmed);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final testFile = File(
      '${dir.path}/.ledgerlo_zip_export_test_${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await testFile.writeAsString('ok', flush: true);
    } on FileSystemException catch (error) {
      if (!mounted) return null;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Folder Not Writable'),
          content: Text(
            'The selected folder cannot be written on this device. Please choose another folder.\n\n$error',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return null;
    } finally {
      try {
        if (await testFile.exists()) {
          await testFile.delete();
        }
      } catch (_) {}
    }

    return trimmed;
  }

  String _csvRow(List<String> fields) {
    return fields.map(_escapeCsv).join(',');
  }

  String _escapeCsv(String value) {
    final escaped = value.replaceAll('"', '""');
    return '"$escaped"';
  }

  Future<void> _exportCustomerDetailsZip() async {
    final exportDirectory = await _pickZipExportDirectory();
    if (exportDirectory == null) {
      return;
    }

    final txs = _transactions.where((t) => !t.isDeleted).toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    final prefs = await SharedPreferences.getInstance();
    final profilePhotoPath =
        prefs.getString('customer_profile_photo_${widget.profileId}_${widget.customerId}') ??
        '';

    final mediaAliasByPath = <String, String>{};
    var mediaCounter = 1;

    void collectMediaPath(String? rawPath) {
      if (rawPath == null || rawPath.trim().isEmpty) return;
      final source = rawPath.trim();
      if (mediaAliasByPath.containsKey(source)) return;

      final file = File(source);
      if (!file.existsSync()) return;

      final fileName = source.split(Platform.pathSeparator).last;
      final safeName = fileName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      mediaAliasByPath[source] = 'media/${mediaCounter}_$safeName';
      mediaCounter++;
    }

    for (final tx in txs) {
      collectMediaPath(tx.photoPath);
      for (final path in tx.photoPaths) {
        collectMediaPath(path);
      }
    }

    final lines = <String>[
      'section,customer_id,profile_id,customer_name,profile_photo_path,transaction_id,transaction_uuid,date,type,amount,note,bill_primary,bill_list_json,created_at,updated_at',
      _csvRow([
        'customer',
        widget.customerId.toString(),
        widget.profileId.toString(),
        widget.customerName,
        profilePhotoPath,
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
      ]),
    ];

    for (final tx in txs) {
      final primaryBill = tx.photoPath == null
          ? ''
          : (mediaAliasByPath[tx.photoPath!.trim()] ?? '');
      final billList = tx.photoPaths
          .map((path) => mediaAliasByPath[path.trim()])
          .whereType<String>()
          .toList();

      lines.add(
        _csvRow([
          'transaction',
          widget.customerId.toString(),
          widget.profileId.toString(),
          widget.customerName,
          profilePhotoPath,
          tx.id.toString(),
          tx.uuid,
          tx.date.toIso8601String(),
          tx.type.name,
          tx.amount.toString(),
          tx.note ?? '',
          primaryBill,
          jsonEncode(billList),
          tx.createdAt.toIso8601String(),
          tx.updatedAt.toIso8601String(),
        ]),
      );
    }

    final csvContent = lines.join('\n');
    final csvBytes = Uint8List.fromList(utf8.encode(csvContent));
    final archive = Archive();
    archive.addFile(ArchiveFile('customer_details.csv', csvBytes.length, csvBytes));

    final sortedEntries = mediaAliasByPath.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    for (final entry in sortedEntries) {
      final file = File(entry.key);
      if (!file.existsSync()) continue;
      final bytes = await file.readAsBytes();
      archive.addFile(ArchiveFile(entry.value, bytes.length, bytes));
    }

    final zipBytes = ZipEncoder().encode(archive);
    if (zipBytes == null) {
      throw Exception('Could not create customer ZIP export.');
    }

    final safeCustomer = widget.customerName
        .trim()
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final fileName =
        'customer_${safeCustomer.isEmpty ? 'details' : safeCustomer}_$timestamp.zip';

    final outFile = File('$exportDirectory/$fileName');
    await outFile.writeAsBytes(Uint8List.fromList(zipBytes), flush: true);

    if (!mounted) return;
    _showTopSnackBar(
      context,
      'Customer ZIP exported successfully',
      const Color(0xFF059669),
      Icons.download_done_rounded,
    );
  }

  Future<void> _showExportOptions() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (ctx) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.picture_as_pdf_outlined),
              title: const Text('Export PDF'),
              subtitle: const Text('Share or download statement PDF.'),
              onTap: () => Navigator.pop(ctx, 'pdf'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_zip_outlined),
              title: const Text('Export ZIP'),
              subtitle: const Text('Customer CSV with bills media files.'),
              onTap: () => Navigator.pop(ctx, 'zip'),
            ),
            const SizedBox(height: 8),
          ],
        );
      },
    );

    if (choice == 'pdf') {
      final allTxs = _transactions.where((t) => !t.isDeleted).toList();
      if (allTxs.isEmpty) {
        _showTopSnackBar(
          context,
          'No transactions to export as PDF',
          const Color(0xFFDC2626),
          Icons.error_outline,
        );
        return;
      }
      await _exportCustomerTransactionsPdf();
      return;
    }

    if (choice == 'zip') {
      try {
        await _exportCustomerDetailsZip();
      } catch (error) {
        if (!mounted) return;
        _showTopSnackBar(
          context,
          'Failed to export customer ZIP: $error',
          const Color(0xFFDC2626),
          Icons.error_outline,
        );
      }
    }
  }

  Future<void> _exportCustomerTransactionsPdf() async {
    final allTxs = _transactions.where((t) => !t.isDeleted).toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    if (allTxs.isEmpty) {
      return;
    }

    final exportSelection = await _pickExportSelection(allTxs);
    if (exportSelection == null) {
      return;
    }

    final txs = exportSelection.transactions;
    if (txs.isEmpty) {
      return;
    }

    final currencyCode = ref.read(currencyProvider);
    final labelStyle = ref.read(settingsProvider);
    final prefs = await SharedPreferences.getInstance();
    final fallbackPhotoPath = prefs.getString(
      'customer_profile_photo_${widget.profileId}_${widget.customerId}',
    );
    final photoPath =
        (widget.customerPhotoPath != null &&
            widget.customerPhotoPath!.trim().isNotEmpty)
        ? widget.customerPhotoPath
        : fallbackPhotoPath;
    final amountFormatter = NumberFormat('#,##0.00');
    final amountIntFormatter = NumberFormat('#,##0');
    final dateFormatter = DateFormat('dd/MM/yyyy');
    final timeFormatter = DateFormat('h:mm a');

    String formatAmount(double value) {
      if (value == value.toInt()) {
        return '$currencyCode ${amountIntFormatter.format(value)}';
      }
      return '$currencyCode ${amountFormatter.format(value)}';
    }

    final baseFont = await PdfGoogleFonts.notoSansRegular();
    final boldFont = await PdfGoogleFonts.notoSansBold();
    pw.MemoryImage? customerPhoto;
    if (photoPath != null && photoPath.trim().isNotEmpty) {
      try {
        final file = File(photoPath);
        if (await file.exists()) {
          customerPhoto = pw.MemoryImage(await file.readAsBytes());
        }
      } catch (_) {}
    }

    final totalCredit = txs
        .where((t) => t.type == TransactionType.credit)
        .fold<double>(0, (sum, t) => sum + t.amount);
    final totalDebit = txs
        .where((t) => t.type == TransactionType.debit)
        .fold<double>(0, (sum, t) => sum + t.amount);
    final netBalance = totalCredit - totalDebit;
    final balanceState = netBalance > 0
        ? 'Advance'
        : netBalance < 0
        ? 'Due'
        : 'Settled';
    final creditLabel = getTransactionLabel(labelStyle, true);
    final debitLabel = getTransactionLabel(labelStyle, false);

    pw.Widget summaryTile(String title, String value) {
      return pw.Container(
        padding: const pw.EdgeInsets.all(8),
        decoration: pw.BoxDecoration(
          color: PdfColors.grey100,
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(title, style: const pw.TextStyle(fontSize: 9)),
            pw.SizedBox(height: 2),
            pw.Text(value, style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          ],
        ),
      );
    }

    final doc = pw.Document();
    final generatedAt = DateFormat('MMM d, y - h:mm a').format(DateTime.now());

    final rows = txs.asMap().entries.map((entry) {
      final index = entry.key;
      final tx = entry.value;
      final label = getTransactionLabel(
        labelStyle,
        tx.type == TransactionType.credit,
      );
      return <String>[
        '${index + 1}',
        dateFormatter.format(tx.date),
        timeFormatter.format(tx.date),
        label,
        formatAmount(tx.amount),
        (tx.note ?? '').trim().isEmpty ? '-' : tx.note!.trim(),
      ];
    }).toList();

    doc.addPage(
      pw.MultiPage(
        theme: pw.ThemeData.withFont(base: baseFont, bold: boldFont),
        build: (context) => [
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(
              color: PdfColors.grey200,
              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
            ),
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                if (customerPhoto != null)
                  pw.Container(
                    width: 54,
                    height: 54,
                    margin: const pw.EdgeInsets.only(right: 10),
                    decoration: pw.BoxDecoration(
                      borderRadius: const pw.BorderRadius.all(
                        pw.Radius.circular(27),
                      ),
                    ),
                    child: pw.ClipRRect(
                      horizontalRadius: 27,
                      verticalRadius: 27,
                      child: pw.Image(customerPhoto, fit: pw.BoxFit.cover),
                    ),
                  ),
                pw.Expanded(
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        'Transactions Statement',
                        style: pw.TextStyle(
                          fontSize: 18,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      pw.SizedBox(height: 4),
                      pw.Text('Name: ${widget.customerName}'),
                      pw.Text('Generated on: $generatedAt'),
                    ],
                  ),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 10),
          pw.Row(
            children: [
              pw.Expanded(
                child: summaryTile(
                  'Final Balance',
                  '${formatAmount(netBalance.abs())} ($balanceState)',
                ),
              ),
              pw.SizedBox(width: 8),
              pw.Expanded(
                child: summaryTile(
                  'Total $creditLabel',
                  formatAmount(totalCredit),
                ),
              ),
              pw.SizedBox(width: 8),
              pw.Expanded(
                child: summaryTile(
                  'Total $debitLabel',
                  formatAmount(totalDebit),
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 12),
          pw.Center(
            child: pw.SizedBox(
              width: 460,
              child: pw.TableHelper.fromTextArray(
                headers: const [
                  'S.No',
                  'Txn Date',
                  'Txn Time',
                  'Type',
                  'Amount',
                  'Note',
                ],
                data: rows,
                headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                headerDecoration: const pw.BoxDecoration(
                  color: PdfColors.grey300,
                ),
                oddRowDecoration: const pw.BoxDecoration(
                  color: PdfColors.grey100,
                ),
                border: pw.TableBorder(
                  horizontalInside: const pw.BorderSide(
                    color: PdfColors.grey400,
                    width: 0.4,
                  ),
                  verticalInside: const pw.BorderSide(
                    color: PdfColors.grey400,
                    width: 0.4,
                  ),
                  top: const pw.BorderSide(
                    color: PdfColors.grey500,
                    width: 0.6,
                  ),
                  bottom: const pw.BorderSide(
                    color: PdfColors.grey500,
                    width: 0.6,
                  ),
                ),
                cellPadding: const pw.EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 5,
                ),
                headerAlignments: {
                  0: pw.Alignment.center,
                  1: pw.Alignment.centerLeft,
                  2: pw.Alignment.centerLeft,
                  3: pw.Alignment.centerLeft,
                  4: pw.Alignment.centerLeft,
                  5: pw.Alignment.centerLeft,
                },
                cellAlignments: {
                  0: pw.Alignment.center,
                  1: pw.Alignment.centerLeft,
                  2: pw.Alignment.centerLeft,
                  3: pw.Alignment.centerLeft,
                  4: pw.Alignment.centerLeft,
                  5: pw.Alignment.centerLeft,
                },
                columnWidths: {
                  0: const pw.FlexColumnWidth(0.7),
                  1: const pw.FlexColumnWidth(1.6),
                  2: const pw.FlexColumnWidth(1.2),
                  3: const pw.FlexColumnWidth(1.1),
                  4: const pw.FlexColumnWidth(1.4),
                  5: const pw.FlexColumnWidth(1.7),
                },
              ),
            ),
          ),
        ],
      ),
    );

    final fileSafeCustomer = widget.customerName
        .trim()
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final filename =
        'ledger_${fileSafeCustomer.isEmpty ? 'customer' : fileSafeCustomer}_$timestamp.pdf';

    try {
      final bytes = await doc.save();
      if (exportSelection.action == _ExportAction.share) {
        await Printing.sharePdf(bytes: bytes, filename: filename);
      } else {
        await _savePdfToDownloads(bytes, filename);
        if (!mounted) return;
        _showTopSnackBar(
          context,
          'PDF downloaded successfully to Downloads',
          const Color(0xFF059669),
          Icons.download_done_rounded,
        );
      }
    } catch (e) {
      if (!mounted) return;
      _showTopSnackBar(
        context,
        'Failed to export PDF',
        const Color(0xFFDC2626),
        Icons.error_outline,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Calculate balance for AppBar display
    final currency = ref.watch(currencyProvider);
    final formatter = NumberFormat.simpleCurrency(name: currency);
    final intFormatter = NumberFormat.simpleCurrency(
      name: currency,
      decimalDigits: 0,
    );

    String formatAmount(double amount) {
      if (amount == amount.toInt()) {
        return intFormatter.format(amount);
      } else {
        return formatter.format(amount);
      }
    }

    final nonDeletedTxs = _transactions.where((t) => !t.isDeleted).toList();
    final balance = TransactionUtils.computeBalance(nonDeletedTxs);

    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        titleSpacing: 0,
        flexibleSpace: _showSearchBar
            ? null
            : GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragEnd: _onAppBarHorizontalSwipe,
                child: const SizedBox.expand(),
              ),
        title: _showSearchBar
            ? SizedBox(
                height: 40,
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  decoration: InputDecoration(
                    hintText: 'Search',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor:
                        Theme.of(context).inputDecorationTheme.fillColor ??
                        Theme.of(context).colorScheme.surface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      vertical: 0,
                      horizontal: 12,
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              )
            : GestureDetector(
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => CustomerProfileScreen(
                        isar: widget.isar,
                        customerId: widget.customerId,
                        profileId: widget.profileId,
                        customerName: widget.customerName,
                        currencyCode: ref.read(currencyProvider),
                      ),
                    ),
                  );
                },
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      alignment: Alignment.center,
                      clipBehavior: Clip.antiAlias,
                      child: (widget.customerPhotoPath != null &&
                              widget.customerPhotoPath!.trim().isNotEmpty)
                          ? Image.file(
                              File(widget.customerPhotoPath!),
                              fit: BoxFit.cover,
                              width: 34,
                              height: 34,
                              errorBuilder: (context, error, stackTrace) {
                                final initials = widget.customerName
                                    .trim()
                                    .split(' ')
                                    .where((part) => part.isNotEmpty)
                                    .take(2)
                                    .map((part) => part[0])
                                    .join()
                                    .toUpperCase();
                                return Text(
                                  initials.isEmpty ? '?' : initials,
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelLarge
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onPrimaryContainer,
                                        fontWeight: FontWeight.w800,
                                      ),
                                );
                              },
                            )
                          : Text(
                              widget.customerName
                                      .trim()
                                      .split(' ')
                                      .where((part) => part.isNotEmpty)
                                      .take(2)
                                      .map((part) => part[0])
                                      .join()
                                      .toUpperCase()
                                      .isEmpty
                                  ? '?'
                                  : widget.customerName
                                        .trim()
                                        .split(' ')
                                        .where((part) => part.isNotEmpty)
                                        .take(2)
                                        .map((part) => part[0])
                                        .join()
                                        .toUpperCase(),
                              style: Theme.of(context)
                                  .textTheme
                                  .labelLarge
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onPrimaryContainer,
                                    fontWeight: FontWeight.w800,
                                  ),
                            ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.customerName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 20),
                          ),
                          Text(
                            formatAmount(balance.abs()),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: balance >= 0
                                  ? (Theme.of(context).brightness ==
                                            Brightness.light
                                        ? Colors.green.shade800
                                        : Colors.green.shade400)
                                  : (Theme.of(context).brightness ==
                                            Brightness.light
                                        ? Colors.red.shade900
                                        : Colors.red.shade400),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
        actions: [
          if (!_showSearchBar)
            IconButton(
              icon: const Icon(Icons.ios_share_outlined),
              tooltip: 'Export',
              onPressed: _showExportOptions,
            ),
          if (!_showSearchBar)
            IconButton(
              icon: const Icon(Icons.search),
              onPressed: () {
                setState(() => _showSearchBar = true);
                Future.microtask(() => _searchFocusNode.requestFocus());
              },
            ),
          if (_showSearchBar)
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () {
                setState(() {
                  _showSearchBar = false;
                  _searchController.clear();
                });
              },
            ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final currency = ref.watch(currencyProvider);
    final labelStyle = ref.watch(settingsProvider);
    final appBarBg =
        Theme.of(context).appBarTheme.backgroundColor ??
        Theme.of(context).colorScheme.surface;

    final txs = _transactions;
    final nonNullTxs = txs.toList();

    final nonDeletedTxs = nonNullTxs.where((t) => !t.isDeleted).toList();
    final deletedTxs = nonNullTxs.where((t) => t.isDeleted).toList();

    final query = _searchController.text.trim().toLowerCase();
    final filteredTxs = nonDeletedTxs.where((t) {
      if (query.isNotEmpty) {
        final noteMatch = (t.note ?? '').toLowerCase().contains(query);
        final amtStr = t.amount.toStringAsFixed(2);
        final amtRaw = t.amount.toString();
        final amtMatch = amtStr.contains(query) || amtRaw.contains(query);
        if (!noteMatch && !amtMatch) return false;
      }
      return true;
    }).toList();

    List<Object> buildSectionItemsNewestToOldest(
      List<txn_model.Transaction> sectionTxsNewestToOldest, {
      String? skipOldestDayHeader,
    }
    ) {
      final items = <Object>[];
      if (sectionTxsNewestToOldest.isEmpty) return items;

      String? currentDay;
      final dayTransactions = <txn_model.Transaction>[];

      void flushDayGroup() {
        if (currentDay == null || dayTransactions.isEmpty) return;
        items.addAll(dayTransactions);
        items.add(currentDay);
        dayTransactions.clear();
      }

      for (final tx in sectionTxsNewestToOldest) {
        final day = tx.date.toLocal().toString().split(' ')[0];
        currentDay ??= day;

        if (day != currentDay) {
          flushDayGroup();
          currentDay = day;
        }

        dayTransactions.add(tx);
      }

      flushDayGroup();
      if (skipOldestDayHeader != null && items.last == skipOldestDayHeader) {
        items.removeLast();
      }
      return items;
    }

    final runningBalances = <int, double>{};
    final oldDisplayItems = <Object>[];
    final currentDisplayItems = <Object>[];
    bool canToggleOldTransactions = false;

    if (filteredTxs.isNotEmpty) {
      final allTxs = [...filteredTxs, ...deletedTxs];
      allTxs.sort((a, b) => a.date.compareTo(b.date));

      double running = 0;
      final zeroBalanceIndices = <int>[];
      for (var i = 0; i < allTxs.length; i++) {
        final tx = allTxs[i];
        if (!tx.isDeleted) {
          running += (tx.type == TransactionType.credit)
              ? tx.amount
              : -tx.amount;
          runningBalances[tx.id] = running;
          if (running == 0) {
            zeroBalanceIndices.add(i);
          }
        }
      }

      int? selectedZeroBalanceIndex;
      for (var z = zeroBalanceIndices.length - 1; z >= 0; z--) {
        final zeroIndex = zeroBalanceIndices[z];
        var hasLaterNonDeletedTransaction = false;
        for (var i = zeroIndex + 1; i < allTxs.length; i++) {
          if (!allTxs[i].isDeleted) {
            hasLaterNonDeletedTransaction = true;
            break;
          }
        }
        if (hasLaterNonDeletedTransaction) {
          selectedZeroBalanceIndex = zeroIndex;
          break;
        }
      }

      final splitIndex = (selectedZeroBalanceIndex == null)
          ? 0
          : selectedZeroBalanceIndex + 1;

      canToggleOldTransactions = selectedZeroBalanceIndex != null;

      final oldTxsToDisplay = (_showOldTransactions && canToggleOldTransactions)
          ? allTxs.sublist(0, splitIndex)
          : <txn_model.Transaction>[];
      final currentTxsToDisplay = allTxs.sublist(splitIndex);

      final oldTxsInReverseChronological = oldTxsToDisplay.reversed.toList();
      oldDisplayItems.addAll(
        buildSectionItemsNewestToOldest(oldTxsInReverseChronological),
      );

      String? lastOldDay;
      if (_showOldTransactions && oldTxsToDisplay.isNotEmpty) {
        lastOldDay = oldTxsToDisplay.last.date.toLocal().toString().split(
          ' ',
        )[0];
      }

      currentDisplayItems.addAll(
        buildSectionItemsNewestToOldest(
          currentTxsToDisplay.reversed.toList(),
          skipOldestDayHeader: _showOldTransactions ? lastOldDay : null,
        ),
      );
    }

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async {
          _loadTransactions();
          setState(() {});
        },
        child: CustomScrollView(
          reverse: true,
          physics: const ClampingScrollPhysics(),
          controller: _scrollController,
          slivers: [
            SliverList(
              key: _currentTransactionsAnchorKey,
              delegate: SliverChildBuilderDelegate((context, index) {
                final item = currentDisplayItems[index];

                if (item is String) {
                  return KeyedSubtree(
                    key: ValueKey('date_$item'),
                    child: TransactionTileBuilder.buildDateHeader(
                      context,
                      item,
                    ),
                  );
                }

                final t = item as txn_model.Transaction;
                return KeyedSubtree(
                  key: ValueKey('tx_${t.id}'),
                  child: TransactionTileBuilder.buildTransactionTile(
                    context: context,
                    transaction: t,
                    currencySymbol: currency,
                    runningBalances: runningBalances,
                    onLongPress: () {},
                    onTap: _openTransactionDetails,
                    onEdit: _editTransaction,
                    onSoftDelete: _softDelete,
                    onRestore: _undoDelete,
                    onHardDelete: _hardDelete,
                  ),
                );
              }, childCount: currentDisplayItems.length),
            ),
            if (canToggleOldTransactions && !_showOldTransactions)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16.0,
                    vertical: 12.0,
                  ),
                  child: Center(
                    child: TextButton.icon(
                      onPressed: () {
                        setState(() {
                          _autoScrollToBottom = false;
                          _pendingScrollOffset = _scrollController.hasClients
                              ? _scrollController.offset
                              : null;
                          _showOldTransactions = true;
                        });
                        _scheduleScrollAdjustment();
                      },
                      icon: const Icon(Icons.history, size: 18),
                      label: const Text('See previous transactions'),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.primary.withAlpha((0.22 * 255).round()),
                      ),
                    ),
                  ),
                ),
              ),
            if (_showOldTransactions && oldDisplayItems.isNotEmpty)
              SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final item = oldDisplayItems[index];

                  if (item is String) {
                    return KeyedSubtree(
                      key: ValueKey('old_date_$item'),
                      child: TransactionTileBuilder.buildDateHeader(
                        context,
                        item,
                      ),
                    );
                  }

                  final t = item as txn_model.Transaction;
                  return KeyedSubtree(
                    key: ValueKey('old_tx_${t.id}'),
                    child: TransactionTileBuilder.buildTransactionTile(
                      context: context,
                      transaction: t,
                      currencySymbol: currency,
                      runningBalances: runningBalances,
                      onLongPress: () {},
                      onTap: _openTransactionDetails,
                      onEdit: _editTransaction,
                      onSoftDelete: _softDelete,
                      onRestore: _undoDelete,
                      onHardDelete: _hardDelete,
                    ),
                  );
                }, childCount: oldDisplayItems.length),
              ),
            if (filteredTxs.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Text(
                    query.isEmpty
                        ? 'No transactions yet.'
                        : 'No matches found.',
                  ),
                ),
              ),
          ],
        ),
      ),
      bottomNavigationBar: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
        child: ColoredBox(
          color: appBarBg,
          child: SizedBox(
            height: 64,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Expanded(
                      child: AnimatedScale(
                        duration: const Duration(milliseconds: 120),
                        curve: Curves.easeOutCubic,
                        scale: _isDebitButtonAnimating ? 0.95 : 1,
                        child: ElevatedButton.icon(
                          onPressed: () => _animateAndShowAddTransactionDialog(
                            TransactionType.debit,
                          ),
                          icon: Icon(
                            Icons.north,
                            color:
                                Theme.of(context).brightness == Brightness.light
                                ? Colors.red.shade900
                                : Colors.red.shade400,
                            size: 20,
                          ),
                          label: Text(
                            getTransactionLabel(labelStyle, false),
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.light
                                  ? Colors.red.shade900
                                  : Colors.red.shade400,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Theme.of(context).colorScheme.surface
                                .withAlpha((0.48 * 255).round()),
                            elevation: 0,
                            shadowColor: Colors.transparent,
                            surfaceTintColor: Colors.transparent,
                            overlayColor: Colors.transparent,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 3,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      child: AnimatedScale(
                        duration: const Duration(milliseconds: 120),
                        curve: Curves.easeOutCubic,
                        scale: _isCreditButtonAnimating ? 0.95 : 1,
                        child: ElevatedButton.icon(
                          onPressed: () => _animateAndShowAddTransactionDialog(
                            TransactionType.credit,
                          ),
                          icon: Icon(
                            Icons.south,
                            color:
                                Theme.of(context).brightness == Brightness.light
                                ? Colors.green.shade800
                                : Colors.green.shade400,
                            size: 20,
                          ),
                          label: Text(
                            getTransactionLabel(labelStyle, true),
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.light
                                  ? Colors.green.shade800
                                  : Colors.green.shade400,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Theme.of(context).colorScheme.surface
                                .withAlpha((0.48 * 255).round()),
                            elevation: 0,
                            shadowColor: Colors.transparent,
                            surfaceTintColor: Colors.transparent,
                            overlayColor: Colors.transparent,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 3,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PdfRangePreviewPage extends StatefulWidget {
  final List<txn_model.Transaction> transactions;
  final String currencyCode;
  final TransactionLabelStyle labelStyle;

  const _PdfRangePreviewPage({
    required this.transactions,
    required this.currencyCode,
    required this.labelStyle,
  });

  @override
  State<_PdfRangePreviewPage> createState() => _PdfRangePreviewPageState();
}

class _PdfRangePreviewPageState extends State<_PdfRangePreviewPage> {
  _ExportRangePreset _selectedPreset = _ExportRangePreset.all;
  DateTimeRange? _customRange;

  int? _latestZeroBalanceSplitIndex(List<txn_model.Transaction> sortedTxs) {
    if (sortedTxs.isEmpty) return null;
    var running = 0.0;
    const epsilon = 0.0001;
    int? latestZeroIndex;
    for (var i = 0; i < sortedTxs.length; i++) {
      final tx = sortedTxs[i];
      running += (tx.type == TransactionType.credit) ? tx.amount : -tx.amount;
      if (running.abs() < epsilon) latestZeroIndex = i;
    }
    if (latestZeroIndex == null || latestZeroIndex >= sortedTxs.length - 1) {
      return null;
    }
    return latestZeroIndex + 1;
  }

  List<txn_model.Transaction> _transactionsForSelection() {
    final sortedTxs = widget.transactions.where((tx) => !tx.isDeleted).toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    if (sortedTxs.isEmpty) return const [];

    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);

    bool inRange(DateTime date, DateTime start, DateTime endInclusive) {
      return !date.isBefore(start) && !date.isAfter(endInclusive);
    }

    switch (_selectedPreset) {
      case _ExportRangePreset.all:
        return sortedTxs;
      case _ExportRangePreset.afterLatestZeroBalance:
        final splitIndex = _latestZeroBalanceSplitIndex(sortedTxs);
        if (splitIndex == null) return const [];
        return sortedTxs.sublist(splitIndex);
      case _ExportRangePreset.last7Days:
        final start = todayStart.subtract(
          Duration(days: todayStart.weekday - DateTime.monday),
        );
        return sortedTxs.where((tx) => !tx.date.isBefore(start)).toList();
      case _ExportRangePreset.last30Days:
        final start = todayStart.subtract(const Duration(days: 29));
        return sortedTxs.where((tx) => !tx.date.isBefore(start)).toList();
      case _ExportRangePreset.thisMonth:
        final start = DateTime(now.year, now.month, 1);
        return sortedTxs.where((tx) => !tx.date.isBefore(start)).toList();
      case _ExportRangePreset.custom:
        if (_customRange == null) return const [];
        final start = DateTime(
          _customRange!.start.year,
          _customRange!.start.month,
          _customRange!.start.day,
        );
        final end = DateTime(
          _customRange!.end.year,
          _customRange!.end.month,
          _customRange!.end.day,
          23,
          59,
          59,
          999,
        );
        return sortedTxs.where((tx) => inRange(tx.date, start, end)).toList();
    }
  }

  String _rangeLabel() {
    if (_selectedPreset == _ExportRangePreset.custom && _customRange != null) {
      final formatter = DateFormat('dd/MM/yyyy');
      return '${formatter.format(_customRange!.start)} - ${formatter.format(_customRange!.end)}';
    }
    switch (_selectedPreset) {
      case _ExportRangePreset.all:
        return 'All transactions';
      case _ExportRangePreset.afterLatestZeroBalance:
        return 'Transactions after latest zero balance';
      case _ExportRangePreset.last7Days:
        return 'This week';
      case _ExportRangePreset.last30Days:
        return 'Last 30 days';
      case _ExportRangePreset.thisMonth:
        return 'This month';
      case _ExportRangePreset.custom:
        return 'Custom date range';
    }
  }

  String _formatAmount(double value) {
    final amountFormatter = NumberFormat('#,##0.00');
    final amountIntFormatter = NumberFormat('#,##0');
    if (value == value.toInt()) {
      return '${widget.currencyCode} ${amountIntFormatter.format(value)}';
    }
    return '${widget.currencyCode} ${amountFormatter.format(value)}';
  }

  Future<void> _pickCustomRange() async {
    final selected = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
      initialDateRange:
          _customRange ??
          DateTimeRange(
            start: DateTime.now().subtract(const Duration(days: 29)),
            end: DateTime.now(),
          ),
    );
    if (selected == null) return;
    setState(() {
      _customRange = selected;
      _selectedPreset = _ExportRangePreset.custom;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final dateFormatter = DateFormat('dd/MM/yyyy');

    final txs = _transactionsForSelection();
    final totalCredit = txs
        .where((t) => t.type == TransactionType.credit)
        .fold<double>(0, (sum, t) => sum + t.amount);
    final totalDebit = txs
        .where((t) => t.type == TransactionType.debit)
        .fold<double>(0, (sum, t) => sum + t.amount);
    final netBalance = totalCredit - totalDebit;

    final balanceColor = netBalance > 0
        ? (theme.brightness == Brightness.light
              ? Colors.green.shade700
              : Colors.green.shade400)
        : netBalance < 0
        ? colorScheme.error
        : colorScheme.onSurfaceVariant;
    final balanceState = netBalance > 0
        ? 'Advance'
        : netBalance < 0
        ? 'Due'
        : 'Settled';
    final displayRangeBalance = _formatAmount(netBalance.abs());

    final creditLabel = getTransactionLabel(widget.labelStyle, true);
    final debitLabel = getTransactionLabel(widget.labelStyle, false);
    final isDark = theme.brightness == Brightness.dark;

    ChoiceChip buildRangeChip({
      required _ExportRangePreset preset,
      required String label,
      required ValueChanged<bool>? onSelected,
    }) {
      final selected = _selectedPreset == preset;
      final unselectedBg = colorScheme.surfaceContainerHighest.withAlpha(
        ((isDark ? 0.55 : 0.75) * 255).round(),
      );
      final selectedBg = colorScheme.primary.withAlpha(
        ((isDark ? 0.34 : 0.20) * 255).round(),
      );

      return ChoiceChip(
        label: Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: selected ? colorScheme.primary : colorScheme.onSurface,
          ),
        ),
        showCheckmark: false,
        selected: selected,
        backgroundColor: unselectedBg,
        selectedColor: selectedBg,
        side: BorderSide(
          color: selected
              ? colorScheme.primary.withAlpha(
                  ((isDark ? 0.70 : 0.45) * 255).round(),
                )
              : colorScheme.outlineVariant,
        ),
        onSelected: onSelected,
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Export Preview')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: SizedBox(
              width: double.infinity,
              child: Card(
                margin: EdgeInsets.zero,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: colorScheme.outlineVariant),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Range', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          const horizontalGap = 8.0;
                          const verticalGap = 8.0;

                          double estimatedChipWidth(String text) {
                            final textPainter = TextPainter(
                              text: TextSpan(
                                text: text,
                                style: theme.textTheme.labelMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              textDirection: Directionality.of(context),
                              maxLines: 1,
                            )..layout();

                            const horizontalInsetsAndBorder = 40.0;
                            return textPainter.width +
                                horizontalInsetsAndBorder;
                          }

                          final chipSpecs =
                              <({String label, Widget chip, double width})>[
                                (
                                  label: 'All',
                                  chip: buildRangeChip(
                                    preset: _ExportRangePreset.all,
                                    label: 'All',
                                    onSelected: (_) => setState(
                                      () => _selectedPreset =
                                          _ExportRangePreset.all,
                                    ),
                                  ),
                                  width: estimatedChipWidth('All'),
                                ),
                                (
                                  label: 'This week',
                                  chip: buildRangeChip(
                                    preset: _ExportRangePreset.last7Days,
                                    label: 'This week',
                                    onSelected: (_) => setState(
                                      () => _selectedPreset =
                                          _ExportRangePreset.last7Days,
                                    ),
                                  ),
                                  width: estimatedChipWidth('This week'),
                                ),
                                (
                                  label: 'This month',
                                  chip: buildRangeChip(
                                    preset: _ExportRangePreset.thisMonth,
                                    label: 'This month',
                                    onSelected: (_) => setState(
                                      () => _selectedPreset =
                                          _ExportRangePreset.thisMonth,
                                    ),
                                  ),
                                  width: estimatedChipWidth('This month'),
                                ),
                                (
                                  label: 'Last zero balance',
                                  chip: buildRangeChip(
                                    preset: _ExportRangePreset
                                        .afterLatestZeroBalance,
                                    label: 'Last zero balance',
                                    onSelected:
                                        _latestZeroBalanceSplitIndex(
                                              widget.transactions,
                                            ) ==
                                            null
                                        ? null
                                        : (_) => setState(
                                            () => _selectedPreset =
                                                _ExportRangePreset
                                                    .afterLatestZeroBalance,
                                          ),
                                  ),
                                  width: estimatedChipWidth(
                                    'Last zero balance',
                                  ),
                                ),
                                (
                                  label: 'Custom range',
                                  chip: buildRangeChip(
                                    preset: _ExportRangePreset.custom,
                                    label: 'Custom range',
                                    onSelected: (_) async {
                                      await _pickCustomRange();
                                    },
                                  ),
                                  width: estimatedChipWidth('Custom range'),
                                ),
                              ];

                          final rowIndexes = <List<int>>[];
                          var currentRow = <int>[];
                          var currentRowWidth = 0.0;

                          for (var i = 0; i < chipSpecs.length; i++) {
                            final nextWidth = chipSpecs[i].width;
                            final projectedWidth = currentRow.isEmpty
                                ? nextWidth
                                : currentRowWidth + horizontalGap + nextWidth;

                            if (currentRow.isNotEmpty &&
                                projectedWidth > constraints.maxWidth) {
                              rowIndexes.add(currentRow);
                              currentRow = [i];
                              currentRowWidth = nextWidth;
                            } else {
                              currentRow.add(i);
                              currentRowWidth = projectedWidth;
                            }
                          }
                          if (currentRow.isNotEmpty) rowIndexes.add(currentRow);

                          final rows = <Widget>[];
                          for (var r = 0; r < rowIndexes.length; r++) {
                            final indexes = rowIndexes[r];
                            final chipsInRow = indexes
                                .map((i) => chipSpecs[i])
                                .toList();
                            final totalChipWidth = chipsInRow.fold<double>(
                              0,
                              (sum, item) => sum + item.width,
                            );

                            final gapCount = chipsInRow.length - 1;
                            final baseGapsWidth = gapCount * horizontalGap;
                            final leftover =
                                (constraints.maxWidth -
                                        totalChipWidth -
                                        baseGapsWidth)
                                    .clamp(0.0, double.infinity);
                            final adjustedGap = gapCount > 0
                                ? horizontalGap + (leftover / gapCount)
                                : 0.0;

                            rows.add(
                              Row(
                                children: [
                                  for (
                                    var i = 0;
                                    i < chipsInRow.length;
                                    i++
                                  ) ...[
                                    chipsInRow[i].chip,
                                    if (i != chipsInRow.length - 1)
                                      SizedBox(width: adjustedGap),
                                  ],
                                ],
                              ),
                            );

                            if (r != rowIndexes.length - 1) {
                              rows.add(const SizedBox(height: verticalGap));
                            }
                          }

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: rows,
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: balanceColor.withAlpha((0.12 * 255).round()),
                border: Border.all(
                  color: balanceColor.withAlpha((0.45 * 255).round()),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_rangeLabel(), style: theme.textTheme.labelMedium),
                  const SizedBox(height: 2),
                  Text(
                    'Net Balance: $displayRangeBalance ($balanceState)',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: balanceColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: colorScheme.outlineVariant),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.primary.withAlpha(
                            (0.10 * 255).round(),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: Text(
                                'Txn Date',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.labelLarge?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            SizedBox(
                              height: 20,
                              child: VerticalDivider(
                                width: 10,
                                thickness: 1,
                                color: colorScheme.outlineVariant,
                              ),
                            ),
                            Expanded(
                              flex: 3,
                              child: Text(
                                creditLabel,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.labelLarge?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            SizedBox(
                              height: 20,
                              child: VerticalDivider(
                                width: 10,
                                thickness: 1,
                                color: colorScheme.outlineVariant,
                              ),
                            ),
                            Expanded(
                              flex: 3,
                              child: Text(
                                debitLabel,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.labelLarge?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Divider(height: 1, color: colorScheme.outlineVariant),
                      Expanded(
                        child: txs.isEmpty
                            ? const Center(
                                child: Text(
                                  'No transactions in selected range',
                                ),
                              )
                            : ListView.separated(
                                padding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
                                itemCount: txs.length,
                                separatorBuilder: (_, _) =>
                                    const Divider(height: 1),
                                itemBuilder: (context, index) {
                                  final tx = txs[index];
                                  final isCredit =
                                      tx.type == TransactionType.credit;
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          flex: 3,
                                          child: Text(
                                            dateFormatter.format(tx.date),
                                            style: theme.textTheme.bodyMedium,
                                            textAlign: TextAlign.center,
                                          ),
                                        ),
                                        SizedBox(
                                          height: 20,
                                          child: VerticalDivider(
                                            width: 10,
                                            thickness: 1,
                                            color: colorScheme.outlineVariant,
                                          ),
                                        ),
                                        Expanded(
                                          flex: 3,
                                          child: Text(
                                            isCredit
                                                ? _formatAmount(tx.amount)
                                                : '',
                                            textAlign: TextAlign.center,
                                            style: theme.textTheme.bodyMedium
                                                ?.copyWith(
                                                  color: isCredit
                                                      ? (theme.brightness ==
                                                                Brightness.light
                                                            ? Colors
                                                                  .green
                                                                  .shade700
                                                            : Colors
                                                                  .green
                                                                  .shade400)
                                                      : colorScheme
                                                            .onSurfaceVariant,
                                                  fontWeight: isCredit
                                                      ? FontWeight.w600
                                                      : FontWeight.w400,
                                                ),
                                          ),
                                        ),
                                        SizedBox(
                                          height: 20,
                                          child: VerticalDivider(
                                            width: 10,
                                            thickness: 1,
                                            color: colorScheme.outlineVariant,
                                          ),
                                        ),
                                        Expanded(
                                          flex: 3,
                                          child: Text(
                                            isCredit
                                                ? ''
                                                : _formatAmount(tx.amount),
                                            textAlign: TextAlign.center,
                                            style: theme.textTheme.bodyMedium
                                                ?.copyWith(
                                                  color: !isCredit
                                                      ? colorScheme.error
                                                      : colorScheme
                                                            .onSurfaceVariant,
                                                  fontWeight: !isCredit
                                                      ? FontWeight.w600
                                                      : FontWeight.w400,
                                                ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: txs.isEmpty
                    ? null
                    : () {
                        Navigator.of(context).pop(
                          _ExportSelection(
                            transactions: txs,
                            label: _rangeLabel(),
                            action: _ExportAction.download,
                          ),
                        );
                      },
                icon: const Icon(Icons.download_rounded),
                label: const Text('Download PDF'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: txs.isEmpty
                    ? null
                    : () {
                        Navigator.of(context).pop(
                          _ExportSelection(
                            transactions: txs,
                            label: _rangeLabel(),
                            action: _ExportAction.share,
                          ),
                        );
                      },
                icon: const Icon(Icons.share_rounded),
                label: const Text('Share PDF'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
