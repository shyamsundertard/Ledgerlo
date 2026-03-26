// ignore_for_file: use_build_context_synchronously
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:isar/isar.dart';
import 'package:ledger_app/core/enums/transaction_type.dart';
import 'package:ledger_app/data/models/transaction.dart' as txn_model;
import 'package:ledger_app/providers/currency_provider.dart';
import 'package:ledger_app/providers/settings_provider.dart';
import 'package:ledger_app/utils/transaction_labels.dart';
import 'package:ledger_app/customer_ledger/calculator_session.dart';

class TransactionDialogHelpers {
  static String formatDisplayDateTime(DateTime value) {
    return DateFormat('EEE, MMM d, y • h:mm a').format(value);
  }

  static Future<DateTime?> showCombinedDateTimePicker({
    required BuildContext context,
    required DateTime initialDateTime,
    required DateTime firstDate,
    required DateTime lastDate,
  }) async {
    DateTime clampDate(DateTime value) {
      if (value.isBefore(firstDate)) return firstDate;
      if (value.isAfter(lastDate)) return lastDate;
      return value;
    }

    int daysInMonth(int year, int month) {
      return DateTime(year, month + 1, 0).day;
    }

    final years = [
      for (int year = firstDate.year; year <= lastDate.year; year++) year,
    ];
    final months = [for (int month = 1; month <= 12; month++) month];
    final monthFormat = DateFormat.MMM();

    return showModalBottomSheet<DateTime>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        var selected = clampDate(initialDateTime);
        var pickerVersion = 0;

        return StatefulBuilder(
          builder: (sheetCtx, setSheetState) {
            InputDecoration pickerDecoration(String label) {
              final theme = Theme.of(sheetCtx);
              return InputDecoration(
                labelText: label,
                isDense: true,
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest.withAlpha(
                  140,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: theme.colorScheme.outlineVariant.withAlpha(120),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: theme.colorScheme.primary),
                ),
              );
            }

            return SafeArea(
              top: false,
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(sheetCtx).viewInsets.bottom,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(sheetCtx).colorScheme.surface,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(24),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Theme.of(sheetCtx)
                          .colorScheme
                          .shadow
                          .withAlpha(40),
                      blurRadius: 24,
                      offset: const Offset(0, -6),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 42,
                        height: 5,
                        decoration: BoxDecoration(
                          color: Theme.of(
                            sheetCtx,
                          ).colorScheme.outlineVariant.withAlpha(190),
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                      const SizedBox(height: 10),
                        Row(
                          children: [
                            TextButton(
                              onPressed: () => Navigator.pop(sheetCtx),
                              child: const Text('Cancel'),
                            ),
                            const Spacer(),
                            FilledButton.tonal(
                              onPressed: () => Navigator.pop(
                                sheetCtx,
                                clampDate(selected),
                              ),
                              child: const Text('Done'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  sheetCtx,
                                ).colorScheme.primary.withAlpha(24),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                Icons.calendar_today_rounded,
                                size: 18,
                                color: Theme.of(sheetCtx).colorScheme.primary,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Select date & time',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(
                                  sheetCtx,
                                ).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(
                              sheetCtx,
                            ).colorScheme.surfaceContainerHighest.withAlpha(120),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            formatDisplayDateTime(selected),
                            textAlign: TextAlign.center,
                            style: Theme.of(sheetCtx).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<int>(
                                initialValue: selected.month,
                                isExpanded: true,
                                borderRadius: BorderRadius.circular(12),
                                menuMaxHeight: 280,
                                icon: const Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                ),
                                decoration: pickerDecoration('Month'),
                                items: months
                                    .map(
                                      (month) => DropdownMenuItem<int>(
                                        value: month,
                                        child: Text(
                                          monthFormat.format(
                                            DateTime(selected.year, month, 1),
                                          ),
                                        ),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (month) {
                                  if (month == null) return;
                                  var targetYear = selected.year;
                                  var maxDay = daysInMonth(targetYear, month);
                                  var day =
                                      selected.day > maxDay ? maxDay : selected.day;
                                  var candidate = DateTime(
                                    targetYear,
                                    month,
                                    day,
                                    selected.hour,
                                    selected.minute,
                                  );

                                  while (candidate.isAfter(lastDate) &&
                                      targetYear > firstDate.year) {
                                    targetYear--;
                                    maxDay = daysInMonth(targetYear, month);
                                    day = selected.day > maxDay
                                        ? maxDay
                                        : selected.day;
                                    candidate = DateTime(
                                      targetYear,
                                      month,
                                      day,
                                      selected.hour,
                                      selected.minute,
                                    );
                                  }

                                  while (candidate.isBefore(firstDate) &&
                                      targetYear < lastDate.year) {
                                    targetYear++;
                                    maxDay = daysInMonth(targetYear, month);
                                    day = selected.day > maxDay
                                        ? maxDay
                                        : selected.day;
                                    candidate = DateTime(
                                      targetYear,
                                      month,
                                      day,
                                      selected.hour,
                                      selected.minute,
                                    );
                                  }

                                  setSheetState(() {
                                    selected = clampDate(candidate);
                                    pickerVersion++;
                                  });
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: DropdownButtonFormField<int>(
                                initialValue: selected.year,
                                isExpanded: true,
                                borderRadius: BorderRadius.circular(12),
                                menuMaxHeight: 280,
                                icon: const Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                ),
                                decoration: pickerDecoration('Year'),
                                items: years
                                    .map(
                                      (year) => DropdownMenuItem<int>(
                                        value: year,
                                        child: Text('$year'),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (year) {
                                  if (year == null) return;
                                  final maxDay = daysInMonth(
                                    year,
                                    selected.month,
                                  );
                                  final day = selected.day > maxDay
                                      ? maxDay
                                      : selected.day;
                                  setSheetState(() {
                                    selected = clampDate(
                                      DateTime(
                                        year,
                                        selected.month,
                                        day,
                                        selected.hour,
                                        selected.minute,
                                      ),
                                    );
                                    pickerVersion++;
                                  });
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Container(
                          decoration: BoxDecoration(
                            color: Theme.of(sheetCtx).colorScheme.surface,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: Theme.of(
                                sheetCtx,
                              ).colorScheme.outlineVariant.withAlpha(100),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Theme.of(
                                  sheetCtx,
                                ).colorScheme.shadow.withAlpha(20),
                                blurRadius: 12,
                                offset: const Offset(0, 5),
                              ),
                              BoxShadow(
                                color: Theme.of(
                                  sheetCtx,
                                ).colorScheme.shadow.withAlpha(10),
                                blurRadius: 2,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: Stack(
                              children: [
                                SizedBox(
                                  height: 210,
                                  child: CupertinoTheme(
                                    data: CupertinoThemeData(
                                      brightness:
                                          Theme.of(sheetCtx).brightness ==
                                              Brightness.dark
                                          ? Brightness.dark
                                          : Brightness.light,
                                    ),
                                    child: CupertinoDatePicker(
                                      key: ValueKey(pickerVersion),
                                      mode: CupertinoDatePickerMode.dateAndTime,
                                      initialDateTime: selected,
                                      minimumDate: firstDate,
                                      maximumDate: lastDate,
                                      use24hFormat: false,
                                      onDateTimeChanged: (value) {
                                        setSheetState(() {
                                          selected = clampDate(value);
                                        });
                                      },
                                    ),
                                  ),
                                ),
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  top: 0,
                                  child: IgnorePointer(
                                    child: Container(
                                      height: 24,
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [
                                            Theme.of(
                                              sheetCtx,
                                            ).colorScheme.surface.withAlpha(210),
                                            Theme.of(
                                              sheetCtx,
                                            ).colorScheme.surface.withAlpha(0),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 0,
                                  child: IgnorePointer(
                                    child: Container(
                                      height: 24,
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [
                                            Theme.of(
                                              sheetCtx,
                                            ).colorScheme.surface.withAlpha(0),
                                            Theme.of(
                                              sheetCtx,
                                            ).colorScheme.surface.withAlpha(210),
                                          ],
                                        ),
                                      ),
                                    ),
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
            );
          },
        );
      },
    );
  }

  static Widget buildCalculatorKeyboard({
    required BuildContext context,
    required TextEditingController controller,
    required VoidCallback onDone,
    required Function(VoidCallback) setStateDialog,
    required CalculatorSession session,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final operatorBackground = colorScheme.primary.withAlpha(28);
    final deleteBackground = colorScheme.error.withAlpha(22);

    Widget key(
      String label, {
      Color? backgroundColor,
      Color? foregroundColor,
      double fontSize = 18,
    }) {
      return Material(
        color: backgroundColor ?? colorScheme.surfaceContainerHighest,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: InkWell(
          onTap: () {
            if (label == 'DEL') {
              session.backspace();
            } else if (label == 'C') {
              session.clear();
            } else if (label == '=') {
              // live-evaluated already; keep as explicit no-op
            } else if (label == '+' ||
                label == '-' ||
                label == '×' ||
                label == '÷') {
              session.appendOperator(label);
            } else if (label == 'OK') {
              onDone();
              return;
            } else {
              // digit or dot
              if (label == '.') {
                session.appendDot();
              } else {
                session.appendDigit(label);
              }
            }
            final rs = session.resultString();
            if (rs.isNotEmpty) {
              try {
                controller.text = rs;
              } catch (_) {
                controller.text = '';
              }
            } else if (session.expression.isEmpty) {
              // fully cleared -> clear controller too
              try {
                controller.text = '';
              } catch (_) {}
            }
            try {
              controller.selection = TextSelection.collapsed(
                offset: controller.text.length,
              );
            } catch (_) {}
            try {
              setStateDialog(() {});
            } catch (_) {}
          },
          borderRadius: BorderRadius.circular(12),
          child: Center(
            child: label == 'DEL'
                ? Icon(
                    Icons.backspace_outlined,
                    size: 20,
                    color: foregroundColor ?? colorScheme.onSurface,
                  )
                : Text(
                    label,
                    style: TextStyle(
                      fontSize: fontSize,
                      fontWeight: FontWeight.w600,
                      color: foregroundColor ?? colorScheme.onSurface,
                    ),
                  ),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colorScheme.outlineVariant.withAlpha(60)),
      ),
      child: GridView.count(
        shrinkWrap: true,
        primary: false,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: 4,
        childAspectRatio: 1.8,
        padding: EdgeInsets.zero,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        children: [
          key('7'),
          key('8'),
          key('9'),
          key(
            'DEL',
            backgroundColor: deleteBackground,
            foregroundColor: colorScheme.error,
            fontSize: 16,
          ),
          key('4'),
          key('5'),
          key('6'),
          key(
            '+',
            backgroundColor: operatorBackground,
            foregroundColor: colorScheme.primary,
          ),
          key('1'),
          key('2'),
          key('3'),
          key(
            '-',
            backgroundColor: operatorBackground,
            foregroundColor: colorScheme.primary,
          ),
          key('.'),
          key('0', fontSize: 20),
          key(
            '÷',
            backgroundColor: operatorBackground,
            foregroundColor: colorScheme.primary,
          ),
          key(
            '×',
            backgroundColor: operatorBackground,
            foregroundColor: colorScheme.primary,
          ),
        ],
      ),
    );
  }

  static Future<void> showEditTransactionDialog({
    required BuildContext context,
    required WidgetRef ref,
    required txn_model.Transaction transaction,
    required Function(txn_model.Transaction) onTransactionUpdated,
    required Function(BuildContext, String, Color, IconData) onShowSnackBar,
    required Isar isar,
  }) async {
    final amountController = TextEditingController(
      text: transaction.amount.toStringAsFixed(2),
    );
    final amountFocus = FocusNode();
    final noteController = TextEditingController(text: transaction.note ?? '');
    var selectedType = transaction.type;
    DateTime selectedDateTime = transaction.date;
    final session = CalculatorSession();

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final labelStyle = ref.watch(settingsProvider);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            try {
              if (!amountFocus.hasFocus) amountFocus.requestFocus();
            } catch (_) {}
          });

          final eval = session.evaluate();

          return AlertDialog(
            title: const Text('Edit Transaction'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
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
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        ctx,
                      ).colorScheme.surfaceContainerHighest.withAlpha(128),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      session.expression.isEmpty ? '0' : session.expression,
                      style: TextStyle(
                        fontSize: 14,
                        color: Theme.of(
                          ctx,
                        ).colorScheme.onSurface.withAlpha(180),
                        fontFamily: 'monospace',
                      ),
                      textAlign: TextAlign.right,
                    ),
                  ),
                  buildCalculatorKeyboard(
                    context: ctx,
                    controller: amountController,
                    onDone: () {},
                    setStateDialog: setState,
                    session: session,
                  ),
                  const SizedBox(height: 12),
                  DropdownButton<TransactionType>(
                    isExpanded: true,
                    value: selectedType,
                    items: TransactionType.values.map((type) {
                      return DropdownMenuItem(
                        value: type,
                        child: Text(
                          getTransactionLabel(
                            labelStyle,
                            type == TransactionType.credit,
                          ),
                        ),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => selectedType = value);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  GestureDetector(
                    onTap: () async {
                      final pickedDateTime =
                          await showCombinedDateTimePicker(
                        context: ctx,
                        initialDateTime: selectedDateTime,
                        firstDate: DateTime(1900),
                        lastDate: DateTime.now(),
                      );
                      if (pickedDateTime != null) {
                        setState(() => selectedDateTime = pickedDateTime);
                      }
                    },
                    child: Row(
                      children: [
                        const Icon(Icons.calendar_month_rounded),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            formatDisplayDateTime(selectedDateTime),
                            style: Theme.of(ctx).textTheme.bodyLarge?.copyWith(
                              color: Theme.of(ctx).colorScheme.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  GestureDetector(
                    onTap: () async {
                      final note = await showDialog<String>(
                        context: ctx,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Edit Description'),
                          content: TextField(
                            controller: noteController,
                            maxLines: 4,
                            decoration: const InputDecoration(
                              hintText: 'Add description (optional)',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('Cancel'),
                            ),
                            TextButton(
                              onPressed: () =>
                                  Navigator.pop(ctx, noteController.text),
                              child: const Text('Done'),
                            ),
                          ],
                        ),
                      );
                      if (note != null) {
                        setState(() {});
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 16,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Theme.of(ctx).colorScheme.outline,
                        ),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.note_add,
                            color: Theme.of(ctx).colorScheme.primary,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              noteController.text.isEmpty
                                  ? 'Add description (optional)'
                                  : noteController.text,
                              style: TextStyle(
                                color: noteController.text.isEmpty
                                    ? Theme.of(
                                        ctx,
                                      ).colorScheme.onSurface.withAlpha(128)
                                    : Theme.of(ctx).colorScheme.onSurface,
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
            actions: [
              TextButton(
                onPressed: () async {
                  try {
                    FocusScope.of(ctx).unfocus();
                  } catch (_) {}
                  await Future.delayed(const Duration(milliseconds: 120));
                  if (ctx.mounted) Navigator.pop(ctx, false);
                },
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: (eval != null && eval > 0)
                    ? () async {
                        try {
                          FocusScope.of(ctx).unfocus();
                        } catch (_) {}
                        await Future.delayed(const Duration(milliseconds: 120));
                        if (ctx.mounted) Navigator.pop(ctx, true);
                      }
                    : null,
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );

    if (result == true) {
      final amount =
          double.tryParse(amountController.text) ?? transaction.amount;

      final nextNote = noteController.text.trim().isEmpty
        ? null
        : noteController.text.trim();
      final currentNote = (transaction.note ?? '').trim().isEmpty
        ? null
        : (transaction.note ?? '').trim();
      final hasChanges =
        amount != transaction.amount ||
        nextNote != currentNote ||
        selectedType != transaction.type ||
        !selectedDateTime.isAtSameMomentAs(transaction.date);

      if (!hasChanges) {
      return;
      }

      await isar.writeTxn(() async {
        transaction.amount = amount;
      transaction.note = nextNote;
        transaction.type = selectedType;
        transaction.date = selectedDateTime;
        transaction.isEdited = true;
        transaction.updatedAt = DateTime.now();
        await isar.transactions.put(transaction);
      });
      onTransactionUpdated(transaction);
    }
    // Delay disposing controllers until the dialog's reverse animation completes
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
