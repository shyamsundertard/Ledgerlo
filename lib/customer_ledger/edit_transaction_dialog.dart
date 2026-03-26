// ignore_for_file: use_build_context_synchronously
import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:isar/isar.dart';
import 'package:ledger_app/core/enums/transaction_type.dart';
import 'package:ledger_app/data/models/transaction.dart' as txn_model;
import 'package:ledger_app/providers/currency_provider.dart';
import 'package:ledger_app/customer_ledger/calculator_session.dart';
import 'package:ledger_app/customer_ledger/transaction_dialogs.dart';

class EditTransactionDialog {
  static const String _successSoundAsset = 'sounds/transaction_success.mp3';
  static final AudioPlayer _successPlayer = AudioPlayer(
    playerId: 'tx-success-sfx',
  );
  static bool _successPlayerConfigured = false;

  static void _showPickerMessage(BuildContext context, String message) {
    if (!context.mounted) return;
  }

  static Future<ImageSource?> _pickImageSource(BuildContext context) async {
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

  static Future<List<String>> _pickPhotos(
    BuildContext context, {
    required int remainingSlots,
  }) async {
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
          _showPickerMessage(
            context,
            'You can add only $remainingSlots more bill(s).',
          );
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
    } on PlatformException {
      _showPickerMessage(
        context,
        'Unable to access camera or gallery for bills. Please check permissions.',
      );
      return const [];
    } catch (_) {
      _showPickerMessage(context, 'Could not pick bill. Please try again.');
      return const [];
    }
  }

  static Future<void> _showSuccessAnimation(
    BuildContext context, {
    required Color color,
    required IconData pulseIcon,
    String label = 'Changes saved',
  }) async {
    if (!context.mounted) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = PageRouteBuilder<void>(
      opaque: false,
      barrierDismissible: false,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 700),
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => const SizedBox.shrink(),
      transitionsBuilder: (ctx, animation, secondaryAnimation, child) {
        return _FintechTransactionTransitionOverlay(
          animation: animation,
          accent: color,
          pulseIcon: pulseIcon,
          label: label,
        );
      },
    );

    Future.delayed(const Duration(milliseconds: 700), () {
      if (navigator.mounted && route.isActive) {
        navigator.pop();
      }
    });

    final pushFuture = navigator.push(route);
    unawaited(_playSuccessSound());
    await pushFuture;
  }

  static Future<void> _playSuccessSound() async {
    try {
      await _ensureSuccessPlayerConfigured();
      await _successPlayer.stop();
      await _successPlayer.play(AssetSource(_successSoundAsset));
      Future.delayed(const Duration(milliseconds: 35), () {
        try {
          HapticFeedback.heavyImpact();
        } catch (_) {}
      });
      Future.delayed(const Duration(milliseconds: 70), () {
        try {
          HapticFeedback.mediumImpact();
        } catch (_) {}
      });
    } catch (_) {
      try {
        SystemSound.play(SystemSoundType.click);
      } catch (_) {}
    }
  }

  static Future<void> _ensureSuccessPlayerConfigured() async {
    if (_successPlayerConfigured) return;
    await _successPlayer.setPlayerMode(PlayerMode.lowLatency);
    await _successPlayer.setVolume(0.15);
    _successPlayerConfigured = true;
  }

  static Future<void> show({
    required BuildContext context,
    required WidgetRef ref,
    required txn_model.Transaction transaction,
    required Isar isar,
    required Function(txn_model.Transaction) onTransactionUpdated,
    required Function(BuildContext, String, Color, IconData) onShowSnackBar,
  }) async {
    unawaited(_ensureSuccessPlayerConfigured());

    String formatAmount(double amount) {
      final fixed = amount.toStringAsFixed(2);
      return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
    }

    final amountController = TextEditingController(
      text: formatAmount(transaction.amount),
    );
    final amountFocus = FocusNode();
    final noteController = TextEditingController(text: transaction.note ?? '');
    final selectedPhotoPaths =
        (transaction.photoPaths.isNotEmpty
                ? transaction.photoPaths
                : (transaction.photoPath == null
                      ? const <String>[]
                      : <String>[transaction.photoPath!]))
            .where((path) => path.trim().isNotEmpty)
            .take(3)
            .toList();
    DateTime selectedDateTime = transaction.date;
    final session = CalculatorSession();
    session.expression = formatAmount(transaction.amount);
    final initialAmountText = formatAmount(
      transaction.amount,
    ).replaceAll(',', '');
    final initialNoteText = (transaction.note ?? '').trim();
    final initialDateTime = transaction.date;
    final initialPhotoPaths = List<String>.from(selectedPhotoPaths);
    bool bypassUnsavedPrompt = false;

    bool hasUnsavedChanges() {
      final currentAmount = amountController.text.trim().replaceAll(',', '');
      final currentNote = noteController.text.trim();
      final amountChanged = currentAmount != initialAmountText;
      final noteChanged = currentNote != initialNoteText;
      final photoChanged =
          selectedPhotoPaths.length != initialPhotoPaths.length ||
          selectedPhotoPaths.asMap().entries.any(
            (entry) => initialPhotoPaths[entry.key] != entry.value,
          );
      final dateChanged =
          selectedDateTime.millisecondsSinceEpoch !=
          initialDateTime.millisecondsSinceEpoch;
      return amountChanged || noteChanged || photoChanged || dateChanged;
    }

    Future<bool> confirmDiscardChanges(BuildContext dialogContext) async {
      if (!hasUnsavedChanges() || bypassUnsavedPrompt) return true;

      return await showDialog<bool>(
            context: dialogContext,
            builder: (confirmCtx) => AlertDialog(
              title: const Text('Discard changes?'),
              content: const Text(
                'You have unsaved changes. Do you want to keep editing or discard them?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(confirmCtx, false),
                  child: const Text('Keep editing'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(confirmCtx, true),
                  child: const Text('Discard'),
                ),
              ],
            ),
          ) ??
          false;
    }

    Future<void> attemptCloseEditor(BuildContext dialogContext) async {
      try {
        FocusScope.of(dialogContext).unfocus();
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 120));
      if (!dialogContext.mounted) return;

      final shouldDiscard = await confirmDiscardChanges(dialogContext);
      if (!shouldDiscard || !dialogContext.mounted) return;

      bypassUnsavedPrompt = true;
      Navigator.pop(dialogContext, false);
    }

    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setState) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              try {
                if (!amountFocus.hasFocus) amountFocus.requestFocus();
              } catch (_) {}
            });

            final showOptions = true; // Always show options in edit mode
            final canSave =
                amountController.text.isNotEmpty &&
                (double.tryParse(amountController.text.replaceAll(',', '')) ??
                        0) >
                    0;
            final ledgerTint = Theme.of(
              ctx,
            ).colorScheme.primary.withAlpha((0.18 * 255).round());

            return PopScope<bool>(
              canPop: !hasUnsavedChanges() || bypassUnsavedPrompt,
              onPopInvokedWithResult: (didPop, _) async {
                if (didPop || bypassUnsavedPrompt) return;
                await attemptCloseEditor(ctx);
              },
              child: Scaffold(
                resizeToAvoidBottomInset: false,
                appBar: AppBar(
                  title: const Text('Edit Transaction'),
                  leading: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () async {
                      await attemptCloseEditor(ctx);
                    },
                  ),
                  actions: const [],
                ),
                body: SafeArea(
                  bottom: false,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
                        child: Card(
                          color: ledgerTint,
                          surfaceTintColor: ledgerTint,
                          elevation: 0,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                            child: Column(
                              children: [
                                TextField(
                                  controller: amountController,
                                  focusNode: amountFocus,
                                  readOnly: true,
                                  decoration: InputDecoration(
                                    labelText: 'Amount',
                                    prefixText:
                                        '${NumberFormat.simpleCurrency(name: ref.read(currencyProvider)).currencySymbol} ',
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    session.expression.isEmpty
                                        ? ''
                                        : session.expression,
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: Theme.of(
                                        ctx,
                                      ).colorScheme.onSurface.withAlpha(180),
                                      fontFamily: 'monospace',
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (showOptions)
                        Expanded(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
                            child: Column(
                              children: [
                                Card(
                                  color: ledgerTint,
                                  surfaceTintColor: ledgerTint,
                                  elevation: 0,
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      12,
                                      8,
                                      12,
                                      8,
                                    ),
                                    child: Column(
                                      children: [
                                        GestureDetector(
                                          onTap: () async {
                                            final pickedDateTime =
                                                await TransactionDialogHelpers.showCombinedDateTimePicker(
                                                  context: ctx,
                                                  initialDateTime:
                                                      selectedDateTime,
                                                  firstDate: DateTime(1900),
                                                  lastDate: DateTime.now(),
                                                );
                                            if (pickedDateTime != null) {
                                              setState(() {
                                                selectedDateTime =
                                                    pickedDateTime;
                                              });
                                            }
                                          },
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 6,
                                            ),
                                            decoration: BoxDecoration(
                                              border: Border(
                                                bottom: BorderSide(
                                                  color: Theme.of(
                                                    ctx,
                                                  ).colorScheme.outlineVariant,
                                                ),
                                              ),
                                            ),
                                            child: Row(
                                              children: [
                                                Icon(
                                                  Icons.calendar_month_rounded,
                                                  size: 22,
                                                  color: Theme.of(
                                                    ctx,
                                                  ).colorScheme.primary,
                                                ),
                                                const SizedBox(width: 12),
                                                Expanded(
                                                  child: Text(
                                                    TransactionDialogHelpers
                                                        .formatDisplayDateTime(
                                                          selectedDateTime,
                                                        ),
                                                    style: Theme.of(ctx)
                                                        .textTheme
                                                        .bodyLarge
                                                        ?.copyWith(
                                                          color: Theme.of(
                                                            ctx,
                                                          ).colorScheme.primary,
                                                        ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        GestureDetector(
                                  onTap: () async {
                                    final tempController =
                                        TextEditingController(
                                          text: noteController.text,
                                        );
                                    await showModalBottomSheet<void>(
                                      context: ctx,
                                      isScrollControlled: true,
                                      useSafeArea: true,
                                      isDismissible: false,
                                      enableDrag: false,
                                      backgroundColor: Colors.transparent,
                                      builder: (dialogCtx) => StatefulBuilder(
                                        builder: (dialogCtx, setDialogState) => AnimatedPadding(
                                          duration: const Duration(milliseconds: 220),
                                          curve: Curves.easeOutCubic,
                                          padding: EdgeInsets.only(
                                            left: 8,
                                            right: 8,
                                            top: 8,
                                            bottom:
                                                MediaQuery.viewInsetsOf(dialogCtx)
                                                    .bottom +
                                                8,
                                          ),
                                          child: Container(
                                            constraints: BoxConstraints(
                                              maxHeight:
                                                  MediaQuery.of(
                                                    dialogCtx,
                                                  ).size.height *
                                                  0.6,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Theme.of(
                                                dialogCtx,
                                              ).colorScheme.surface,
                                              borderRadius:
                                                  BorderRadius.circular(22),
                                              border: Border.all(
                                                color: Theme.of(
                                                  dialogCtx,
                                                ).colorScheme.outlineVariant,
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: Colors.black.withAlpha(
                                                    20,
                                                  ),
                                                  blurRadius: 18,
                                                  offset: const Offset(0, 8),
                                                ),
                                              ],
                                            ),
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const SizedBox(height: 10),
                                                Container(
                                                  width: 42,
                                                  height: 4,
                                                  decoration: BoxDecoration(
                                                    color: Theme.of(
                                                      dialogCtx,
                                                    ).colorScheme.outlineVariant,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          2,
                                                        ),
                                                  ),
                                                ),
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.fromLTRB(
                                                        20,
                                                        14,
                                                        20,
                                                        12,
                                                      ),
                                                  child: Row(
                                                    children: [
                                                      Icon(
                                                        Icons.note_alt_rounded,
                                                        color: Theme.of(
                                                          dialogCtx,
                                                        ).colorScheme.primary,
                                                        size: 20,
                                                      ),
                                                      const SizedBox(width: 10),
                                                      Expanded(
                                                        child: Text(
                                                          'Edit Description',
                                                          style: Theme.of(
                                                            dialogCtx,
                                                          ).textTheme.titleMedium?.copyWith(
                                                            fontWeight:
                                                                FontWeight.w700,
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                Flexible(
                                                  child: Padding(
                                                    padding:
                                                        const EdgeInsets.fromLTRB(
                                                          20,
                                                          0,
                                                          20,
                                                          10,
                                                        ),
                                                    child: Container(
                                                      decoration: BoxDecoration(
                                                        color: Theme.of(
                                                          dialogCtx,
                                                        ).colorScheme.surfaceContainerHighest,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              16,
                                                            ),
                                                        border: Border.all(
                                                          color: Theme.of(
                                                            dialogCtx,
                                                          ).colorScheme.outlineVariant,
                                                        ),
                                                      ),
                                                      child: TextField(
                                                        controller:
                                                            tempController,
                                                        maxLines: null,
                                                        minLines: 5,
                                                        autofocus: true,
                                                        maxLength: 500,
                                                        style: Theme.of(dialogCtx)
                                                            .textTheme
                                                            .bodyMedium
                                                            ?.copyWith(
                                                              height: 1.45,
                                                            ),
                                                        decoration: InputDecoration(
                                                          hintText:
                                                              'Add description (optional)',
                                                          border:
                                                              InputBorder.none,
                                                          contentPadding:
                                                              const EdgeInsets.fromLTRB(
                                                                14,
                                                                14,
                                                                14,
                                                                10,
                                                              ),
                                                          counterStyle: TextStyle(
                                                            color: Theme.of(
                                                              dialogCtx,
                                                            ).colorScheme.onSurfaceVariant,
                                                            fontSize: 11,
                                                          ),
                                                        ),
                                                        onChanged: (_) =>
                                                            setDialogState(
                                                              () {},
                                                            ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.fromLTRB(
                                                        20,
                                                        2,
                                                        20,
                                                        18,
                                                      ),
                                                  child: Row(
                                                    children: [
                                                      Expanded(
                                                        child: OutlinedButton(
                                                          onPressed: () =>
                                                              Navigator.pop(
                                                                dialogCtx,
                                                              ),
                                                          child: const Text(
                                                            'Discard',
                                                          ),
                                                        ),
                                                      ),
                                                      const SizedBox(width: 12),
                                                      Expanded(
                                                        child: FilledButton(
                                                          onPressed: () {
                                                            noteController
                                                                    .text =
                                                                tempController
                                                                    .text;
                                                            Navigator.pop(
                                                              dialogCtx,
                                                            );
                                                          },
                                                          child: const Text(
                                                            'Save',
                                                          ),
                                                        ),
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
                                    setState(() {});
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 0,
                                      vertical: 2,
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.note_add_rounded,
                                          color: Theme.of(
                                            ctx,
                                          ).colorScheme.primary,
                                          size: 22,
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Text(
                                            noteController.text.isEmpty
                                                ? 'Add description (optional)'
                                                : noteController.text,
                                            style: TextStyle(
                                              color: Theme.of(
                                                ctx,
                                              ).colorScheme.primary,
                                            ),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Card(
                                  color: ledgerTint,
                                  surfaceTintColor: ledgerTint,
                                  elevation: 0,
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      10,
                                      16,
                                      10,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Text(
                                              'Bills',
                                              style: Theme.of(
                                                ctx,
                                              ).textTheme.titleMedium,
                                            ),
                                            const Spacer(),
                                            Text(
                                              '${selectedPhotoPaths.length}/3',
                                              style: Theme.of(
                                                ctx,
                                              ).textTheme.bodyMedium,
                                            ),
                                            const SizedBox(width: 10),
                                            FilledButton.tonalIcon(
                                              onPressed:
                                                  selectedPhotoPaths.length >= 3
                                                  ? null
                                                  : () async {
                                                      final pickedPaths =
                                                          await _pickPhotos(
                                                            ctx,
                                                            remainingSlots:
                                                                3 -
                                                                selectedPhotoPaths
                                                                    .length,
                                                          );
                                                      if (pickedPaths.isEmpty) {
                                                        _showPickerMessage(
                                                          ctx,
                                                          'No bill selected.',
                                                        );
                                                        return;
                                                      }
                                                      final newPaths =
                                                          pickedPaths
                                                              .where(
                                                                (path) =>
                                                                    !selectedPhotoPaths
                                                                        .contains(
                                                                          path,
                                                                        ),
                                                              )
                                                              .toList();
                                                      if (newPaths.isEmpty) {
                                                        _showPickerMessage(
                                                          ctx,
                                                          'This bill is already attached.',
                                                        );
                                                        return;
                                                      }
                                                      if (newPaths.length <
                                                          pickedPaths.length) {
                                                        _showPickerMessage(
                                                          ctx,
                                                          'Some selected bills were already attached.',
                                                        );
                                                      }
                                                      setState(() {
                                                        selectedPhotoPaths
                                                            .addAll(newPaths);
                                                      });
                                                    },
                                              icon: const Icon(
                                                Icons
                                                    .add_photo_alternate_outlined,
                                              ),
                                              label: const Text('Attach'),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 2),
                                        if (selectedPhotoPaths.isEmpty)
                                          Container(
                                            width: double.infinity,
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 10,
                                            ),
                                            child: const Text(
                                              'No bills attached.',
                                            ),
                                          )
                                        else
                                          Wrap(
                                            spacing: 8,
                                            runSpacing: 8,
                                            children: List.generate(
                                              selectedPhotoPaths.length,
                                              (index) {
                                                return Stack(
                                                  clipBehavior: Clip.none,
                                                  children: [
                                                    ClipRRect(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            8,
                                                          ),
                                                      child: Image.file(
                                                        File(
                                                          selectedPhotoPaths[index],
                                                        ),
                                                        width: 64,
                                                        height: 64,
                                                        fit: BoxFit.cover,
                                                        errorBuilder:
                                                            (
                                                              context,
                                                              error,
                                                              stackTrace,
                                                            ) => Container(
                                                              width: 64,
                                                              height: 64,
                                                              color: Theme.of(
                                                                ctx,
                                                              ).colorScheme.surfaceContainerHighest,
                                                              alignment:
                                                                  Alignment
                                                                      .center,
                                                              child: const Icon(
                                                                Icons
                                                                    .broken_image_outlined,
                                                                size: 18,
                                                              ),
                                                            ),
                                                      ),
                                                    ),
                                                    Positioned(
                                                      top: -6,
                                                      right: -6,
                                                      child: Material(
                                                        color: Theme.of(
                                                          ctx,
                                                        ).colorScheme.surface,
                                                        shape:
                                                            const CircleBorder(),
                                                        child: InkWell(
                                                          customBorder:
                                                              const CircleBorder(),
                                                          onTap: () async {
                                                            final shouldRemove =
                                                                await showDialog<
                                                                  bool
                                                                >(
                                                                  context: ctx,
                                                                  builder: (
                                                                    confirmCtx,
                                                                  ) => AlertDialog(
                                                                    title:
                                                                        const Text(
                                                                          'Remove bill?',
                                                                        ),
                                                                    content:
                                                                        const Text(
                                                                          'Do you want to remove this attached bill?',
                                                                        ),
                                                                    actions: [
                                                                      TextButton(
                                                                        onPressed: () =>
                                                                            Navigator.pop(
                                                                              confirmCtx,
                                                                              false,
                                                                            ),
                                                                        child:
                                                                            const Text(
                                                                              'Cancel',
                                                                            ),
                                                                      ),
                                                                      TextButton(
                                                                        onPressed: () =>
                                                                            Navigator.pop(
                                                                              confirmCtx,
                                                                              true,
                                                                            ),
                                                                        child:
                                                                            const Text(
                                                                              'Remove',
                                                                            ),
                                                                      ),
                                                                    ],
                                                                  ),
                                                                ) ??
                                                                false;
                                                            if (!shouldRemove) {
                                                              return;
                                                            }
                                                            setState(() {
                                                              selectedPhotoPaths
                                                                  .removeAt(
                                                                    index,
                                                                  );
                                                            });
                                                          },
                                                          child: const Padding(
                                                            padding:
                                                                EdgeInsets.all(
                                                                  3,
                                                                ),
                                                            child: Icon(
                                                              Icons.close,
                                                              size: 14,
                                                            ),
                                                          ),
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
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
                        child: Row(
                          children: [
                            Expanded(
                              child: FilledButton(
                                onPressed: canSave
                                    ? () async {
                                        try {
                                          FocusScope.of(ctx).unfocus();
                                        } catch (_) {}
                                        await Future.delayed(
                                          const Duration(milliseconds: 120),
                                        );
                                        final amountText = amountController.text
                                            .trim()
                                            .replaceAll(',', '');
                                        final amount = double.tryParse(
                                          amountText,
                                        );
                                        if (amount == null || amount <= 0) {
                                          return;
                                        }
                                        bypassUnsavedPrompt = true;
                                        if (ctx.mounted) {
                                          Navigator.pop(ctx, true);
                                        }
                                      }
                                    : null,
                                child: const Text('Save'),
                              ),
                            ),
                          ],
                        ),
                      ),
                      TransactionDialogHelpers.buildCalculatorKeyboard(
                        context: ctx,
                        controller: amountController,
                        onDone: () {},
                        setStateDialog: setState,
                        session: session,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );

    if (result == true) {
      final amountText = amountController.text.trim().replaceAll(',', '');
      if (amountText.isEmpty) {
        return;
      }
      final amount = double.tryParse(amountText);
      if (amount == null || amount <= 0) {
        return;
      }

      final nextNote = noteController.text.trim().isEmpty
          ? null
          : noteController.text.trim();
      final currentNote = (transaction.note ?? '').trim().isEmpty
          ? null
          : (transaction.note ?? '').trim();
      final nextPhotoPaths = List<String>.from(selectedPhotoPaths);
      final photosChanged =
          nextPhotoPaths.length != transaction.photoPaths.length ||
          nextPhotoPaths.asMap().entries.any(
            (entry) => transaction.photoPaths[entry.key] != entry.value,
          );
      final hasChanges =
          amount != transaction.amount ||
          nextNote != currentNote ||
          photosChanged ||
          !selectedDateTime.isAtSameMomentAs(transaction.date);

      if (!hasChanges) {
        return;
      }

      await isar.writeTxn(() async {
        transaction.amount = amount;
        transaction.note = nextNote;
        transaction.photoPaths = nextPhotoPaths;
        transaction.photoPath = selectedPhotoPaths.isEmpty
            ? null
            : selectedPhotoPaths.first;
        transaction.date = selectedDateTime;
        transaction.isEdited = true;
        transaction.updatedAt = DateTime.now();
        await isar.transactions.put(transaction);
      });

      onTransactionUpdated(transaction);

      if (context.mounted) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final accent = transaction.type == TransactionType.credit
            ? (isDark
                  ? const Color(0xFF34D399)
                  : const Color(0xFF059669))
            : Colors.blue.shade600;
        await _showSuccessAnimation(
          context,
          color: accent,
          pulseIcon: Icons.auto_fix_high_rounded,
          label: 'Changes saved',
        );
      }
    }

    Future.delayed(const Duration(milliseconds: 350), () {
      try {
        amountController.dispose();
      } catch (_) {}
      try {
        noteController.dispose();
      } catch (_) {}
      try {
        amountFocus.dispose();
      } catch (_) {}
    });
  }
}

class _FintechTransactionTransitionOverlay extends StatelessWidget {
  const _FintechTransactionTransitionOverlay({
    required this.animation,
    required this.accent,
    required this.pulseIcon,
    required this.label,
  });

  final Animation<double> animation;
  final Color accent;
  final IconData pulseIcon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final rippleCoreBase = isDark
        ? const Color(0xFF8A5CFF)
        : const Color(0xFF6C3DFF);
    final rippleOuterBase = isDark
        ? const Color(0xFF3DD9FF)
        : const Color(0xFF00B8E6);
    final rippleCore = Color.alphaBlend(
      rippleCoreBase.withAlpha(isDark ? 190 : 150),
      colorScheme.surface,
    );
    final rippleOuter = Color.alphaBlend(
      rippleOuterBase.withAlpha(isDark ? 170 : 130),
      colorScheme.surface,
    );
    final routeCurve = CurvedAnimation(parent: animation, curve: Curves.linear);

    final circleScale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: 3.0)
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 18,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 3.0, end: 24.0)
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 82,
      ),
    ]).animate(routeCurve);

    final flashOpacity = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: 0.34)
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 24,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 0.34, end: 0.0)
            .chain(CurveTween(curve: Curves.easeInCubic)),
        weight: 76,
      ),
    ]).animate(routeCurve);

    final overlayFade = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: routeCurve,
        curve: const Interval(0.70, 1.0, curve: Curves.easeOutCubic),
      ),
    );

    final contentFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: routeCurve,
        curve: const Interval(0.42, 1.0, curve: Curves.easeOutCubic),
      ),
    );

    final contentScale = Tween<double>(begin: 0.95, end: 1.0).animate(
      CurvedAnimation(
        parent: routeCurve,
        curve: const Interval(0.42, 1.0, curve: Curves.easeOutCubic),
      ),
    );

    final iconScale = Tween<double>(begin: 0.84, end: 1.0).animate(
      CurvedAnimation(
        parent: routeCurve,
        curve: const Interval(0.0, 0.34, curve: Curves.easeOutBack),
      ),
    );
    final symbolReveal = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: routeCurve,
        curve: const Interval(0.14, 0.52, curve: Curves.easeOutCubic),
      ),
    );
    final symbolScale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.74, end: 1.10)
            .chain(CurveTween(curve: Curves.easeOutBack)),
        weight: 58,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.10, end: 1.0)
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 42,
      ),
    ]).animate(
      CurvedAnimation(
        parent: routeCurve,
        curve: const Interval(0.14, 0.62, curve: Curves.linear),
      ),
    );
    final symbolTilt = Tween<double>(begin: -0.10, end: 0.0).animate(
      CurvedAnimation(
        parent: routeCurve,
        curve: const Interval(0.14, 0.48, curve: Curves.easeOutCubic),
      ),
    );

    final ringOneScale = Tween<double>(begin: 1.0, end: 10.0).animate(
      CurvedAnimation(
        parent: routeCurve,
        curve: const Interval(0.06, 0.86, curve: Curves.easeOutCubic),
      ),
    );
    final ringTwoScale = Tween<double>(begin: 1.0, end: 14.0).animate(
      CurvedAnimation(
        parent: routeCurve,
        curve: const Interval(0.12, 0.94, curve: Curves.easeOutCubic),
      ),
    );
    final ringOneOpacity = Tween<double>(begin: 0.75, end: 0.0).animate(
      CurvedAnimation(
        parent: routeCurve,
        curve: const Interval(0.08, 0.90, curve: Curves.easeOut),
      ),
    );
    final ringTwoOpacity = Tween<double>(begin: 0.55, end: 0.0).animate(
      CurvedAnimation(
        parent: routeCurve,
        curve: const Interval(0.16, 0.98, curve: Curves.easeOut),
      ),
    );

    return Material(
      color: Colors.transparent,
      child: AnimatedBuilder(
        animation: routeCurve,
        builder: (ctx, child) {
          final bgCoverOpacity = (1 - contentFade.value).clamp(0.0, 1.0);

          return Stack(
            fit: StackFit.expand,
            children: [
              Transform.scale(
                scale: contentScale.value,
                child: Opacity(
                  opacity: bgCoverOpacity,
                  child: ColoredBox(color: Theme.of(ctx).scaffoldBackgroundColor),
                ),
              ),
              Opacity(
                opacity: flashOpacity.value,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment.center,
                      radius: 1.35,
                      colors: [
                        rippleCore.withAlpha(isDark ? 190 : 145),
                        rippleOuter.withAlpha(isDark ? 120 : 82),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
              Center(
                child: Opacity(
                  opacity: ringTwoOpacity.value * overlayFade.value,
                  child: Transform.scale(
                    scale: ringTwoScale.value,
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: rippleOuter.withAlpha(isDark ? 245 : 210),
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Center(
                child: Opacity(
                  opacity: ringOneOpacity.value * overlayFade.value,
                  child: Transform.scale(
                    scale: ringOneScale.value,
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: rippleCore.withAlpha(isDark ? 255 : 230),
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Center(
                child: Opacity(
                  opacity: overlayFade.value,
                  child: Transform.scale(
                    scale: circleScale.value,
                    child: Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        color: accent,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: accent.withAlpha(180),
                            blurRadius: 34,
                            spreadRadius: 3,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Center(
                child: Opacity(
                  opacity: overlayFade.value,
                  child: Transform.scale(
                    scale: iconScale.value,
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: colorScheme.surface,
                        shape: BoxShape.circle,
                        border: Border.all(color: accent.withAlpha(200)),
                        boxShadow: [
                          BoxShadow(
                            color: accent.withAlpha(100),
                            blurRadius: 18,
                            spreadRadius: 0,
                          ),
                        ],
                      ),
                      child: Center(
                        child: Transform.rotate(
                          angle: symbolTilt.value,
                          child: Transform.scale(
                            scale: symbolScale.value,
                            child: Opacity(
                              opacity: symbolReveal.value,
                              child: Icon(
                                pulseIcon,
                                size: 40,
                                color: accent,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
