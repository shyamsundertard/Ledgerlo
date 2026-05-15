import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:ledger_app/core/enums/transaction_type.dart';
import 'package:ledger_app/data/models/transaction.dart' as txn_model;
import 'package:ledger_app/customer_ledger/transaction_utils.dart';

class TransactionTileBuilder {
  static List<String> _getPhotoPaths(txn_model.Transaction transaction) {
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

  static bool _isEdited(txn_model.Transaction transaction) {
    if (transaction.isEdited) return true;
    return transaction.updatedAt.isAfter(
      transaction.createdAt.add(const Duration(seconds: 1)),
    );
  }

  static Widget _editedBadge(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'Edited',
        style:
            Theme.of(context).textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.primary,
            ) ??
            TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }

  static Widget _buildPhotoPreview(
    BuildContext context,
    String photoPath, {
    bool compact = false,
  }) {
    return FutureBuilder<Uint8List>(
      future: XFile(photoPath).readAsBytes(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            height: 100,
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }

        if (snapshot.hasError ||
            snapshot.data == null ||
            snapshot.data!.isEmpty) {
          return Row(
            children: [
              Icon(
                Icons.broken_image_outlined,
                size: 14,
                color: Theme.of(context).brightness == Brightness.light
                    ? const Color(0xFF3c5152)
                    : Colors.grey.shade400,
              ),
              const SizedBox(width: 6),
              Text(
                'Bill unavailable',
                style:
                    Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).brightness == Brightness.light
                          ? const Color(
                              0xFF3c5152,
                            ).withAlpha((0.6 * 255).round())
                          : Colors.grey.shade400,
                    ) ??
                    const TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ],
          );
        }

        final imageBytes = snapshot.data!;

        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            imageBytes,
            height: 100,
            width: compact ? 86 : double.infinity,
            fit: BoxFit.cover,
          ),
        );
      },
    );
  }

  static Widget _buildPhotoGallery(
    BuildContext context,
    List<String> photoPaths,
  ) {
    if (photoPaths.isEmpty) return const SizedBox.shrink();

    if (photoPaths.length == 1) {
      return _buildPhotoPreview(context, photoPaths.first);
    }

    return SizedBox(
      height: 100,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: photoPaths.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          return _buildPhotoPreview(context, photoPaths[index], compact: true);
        },
      ),
    );
  }

  static Widget buildDateHeader(BuildContext context, String dateStr) {
    final dateLabel = TransactionUtils.getDateLabel(dateStr);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF84AFAF),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            dateLabel,
            style: const TextStyle(
              fontWeight: FontWeight.w400,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  static Widget buildTransactionTile({
    required BuildContext context,
    required txn_model.Transaction transaction,
    required String currencySymbol,
    required Map<int, double> runningBalances,
    required Function() onLongPress,
    required Function(txn_model.Transaction) onTap,
    required Function(txn_model.Transaction) onEdit,
    required Function(txn_model.Transaction) onSoftDelete,
    required Function(txn_model.Transaction) onRestore,
    required Function(txn_model.Transaction) onHardDelete,
  }) {
    final t = transaction;
    final isEdited = _isEdited(t);
    final photoPaths = _getPhotoPaths(t);
    final isCredit = t.type == TransactionType.credit;
    final timeStr = TransactionUtils.formatTimeOfDay(t.date);
    final isDeleted = t.isDeleted;
    final showEditedBadge = isEdited && !isDeleted;
    final finalBal = runningBalances[t.id] ?? 0.0;
    final balLabel = finalBal < 0 ? 'Due' : 'Advance';

    String formatAmount(double amount) {
      final intFormatter = NumberFormat.simpleCurrency(
        name: currencySymbol,
        decimalDigits: 0,
      );
      final formatter = NumberFormat.simpleCurrency(name: currencySymbol);
      if (amount == amount.toInt()) {
        return intFormatter.format(amount);
      } else {
        return formatter.format(amount);
      }
    }

    if (isDeleted) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 8),
        child: Dismissible(
          key: ValueKey('deleted-${t.id}'),
          direction: DismissDirection.horizontal,
          background: Container(
            decoration: BoxDecoration(
              color: Colors.blue.shade600,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.only(left: 20),
            child: const Icon(Icons.restore, color: Colors.white),
          ),
          secondaryBackground: Container(
            decoration: BoxDecoration(
              color: Colors.red.shade700,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            child: const Icon(Icons.delete_forever, color: Colors.white),
          ),
          confirmDismiss: (direction) async {
            if (direction == DismissDirection.startToEnd) {
              return await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Restore transaction'),
                      content: const Text('Restore this transaction?'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Restore'),
                        ),
                      ],
                    ),
                  ) ??
                  false;
            }
            return await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Delete permanently'),
                    content: const Text('Permanently delete this transaction?'),
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
          },
          onDismissed: (direction) async {
            if (direction == DismissDirection.startToEnd) {
              await onRestore(t);
              return;
            }
            await onHardDelete(t);
          },
          child: Align(
            alignment: isCredit ? Alignment.centerRight : Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.55,
              ),
              child: GestureDetector(
                onLongPress: onLongPress,
                onTap: () => onTap(t),
                child: Column(
                  crossAxisAlignment: isCredit
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        vertical: 14,
                        horizontal: 16,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: const Color(0xFF85ADAC).withValues(alpha: 0.5),
                          width: 1.2,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Flexible(
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            isCredit
                                                ? Icons.south
                                                : Icons.north,
                                            size: 16,
                                            color: isCredit
                                                ? (Theme.of(context).brightness ==
                                                          Brightness.light
                                                      ? Colors.green.shade700
                                                      : Colors.green.shade300)
                                                : (Theme.of(context).brightness ==
                                                          Brightness.light
                                                      ? Colors.red.shade700
                                                      : Colors.red.shade300),
                                          ),
                                          const SizedBox(width: 8),
                                          Flexible(
                                            child: Text(
                                              formatAmount(t.amount),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style:
                                                  Theme.of(context)
                                                      .textTheme
                                                      .headlineSmall
                                                      ?.copyWith(
                                                        fontWeight:
                                                            FontWeight.w800,
                                                        fontSize: 18,
                                                        decoration:
                                                            TextDecoration
                                                                .lineThrough,
                                                        decorationThickness:
                                                            3.0,
                                                        decorationColor:
                                                            Theme.of(
                                                                  context,
                                                                ).brightness ==
                                                                Brightness.light
                                                            ? const Color(
                                                                0xFF3c5152,
                                                              ).withOpacity(
                                                                0.55,
                                                              )
                                                            : Colors
                                                                  .grey
                                                                  .shade300
                                                                  .withOpacity(
                                                                    0.55,
                                                                  ),
                                                        color:
                                                            Theme.of(
                                                                  context,
                                                                ).brightness ==
                                                                Brightness.light
                                                            ? const Color(
                                                                0xFF3c5152,
                                                              ).withOpacity(
                                                                0.55,
                                                              )
                                                            : Colors
                                                                  .grey
                                                                  .shade300
                                                                  .withOpacity(
                                                                    0.55,
                                                                  ),
                                                      ) ??
                                                  TextStyle(
                                                    fontWeight: FontWeight.w800,
                                                    fontSize: 18,
                                                    decoration: TextDecoration
                                                        .lineThrough,
                                                    decorationThickness: 3.0,
                                                    color: Colors.grey
                                                        .withOpacity(0.55),
                                                  ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      timeStr,
                                      maxLines: 1,
                                      softWrap: false,
                                      overflow: TextOverflow.visible,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w400,
                                            color:
                                                Theme.of(context).brightness ==
                                                    Brightness.light
                                                ? const Color(0xFF3c5152)
                                                : Colors.grey.shade300,
                                          ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 4,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    if (showEditedBadge) _editedBadge(context),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.grey.shade300,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        'Deleted',
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          color:
                                              Theme.of(context).brightness ==
                                                  Brightness.light
                                              ? Colors.red.shade700
                                              : Colors.red.shade300,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                if ((t.note ?? '').isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  _ExpandableNote(
                                    text: t.note ?? '',
                                    style:
                                        Theme.of(
                                          context,
                                        ).textTheme.bodySmall?.copyWith(
                                          color:
                                              Theme.of(context).brightness ==
                                                  Brightness.light
                                              ? const Color(
                                                  0xFF3c5152,
                                                ).withAlpha((0.6 * 255).round())
                                              : Colors.grey.shade400,
                                        ) ??
                                        const TextStyle(
                                          fontSize: 12,
                                          color: Colors.black54,
                                        ),
                                  ),
                                ],
                              ],
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
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 8),
      child: Dismissible(
        key: ValueKey(t.id),
        direction: DismissDirection.horizontal,
        background: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.only(left: 20),
          child: const Icon(Icons.edit, color: Colors.white),
        ),
        secondaryBackground: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.error,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          child: const Icon(Icons.delete, color: Colors.white),
        ),
        confirmDismiss: (direction) async {
          if (direction == DismissDirection.startToEnd) {
            final shouldEdit =
                await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Edit transaction'),
                    content: const Text('Edit this transaction?'),
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

            if (shouldEdit) {
              onEdit(t);
            }
            return false;
          }
          return await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Delete transaction'),
                  content: const Text('Soft-delete this transaction?'),
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
        },
        onDismissed: (direction) async {
          if (direction != DismissDirection.endToStart) return;
          await onSoftDelete(t);
        },
        child: Align(
          alignment: isCredit ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.55,
            ),
            child: GestureDetector(
              onLongPress: onLongPress,
              onTap: () => onTap(t),
              child: Column(
                crossAxisAlignment: isCredit
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 14,
                      horizontal: 16,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: const Color(0xFF85ADAC).withValues(alpha: 0.5),
                        width: 1.2,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Flexible(
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          isCredit ? Icons.south : Icons.north,
                                          size: 16,
                                          color: isCredit
                                              ? (Theme.of(context).brightness ==
                                                        Brightness.light
                                                    ? Colors.green.shade800
                                                    : Colors.green.shade400)
                                              : (Theme.of(context).brightness ==
                                                        Brightness.light
                                                    ? Colors.red.shade900
                                                    : Colors.red.shade400),
                                        ),
                                        const SizedBox(width: 8),
                                        Flexible(
                                          child: Text(
                                            formatAmount(t.amount),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style:
                                                Theme.of(context)
                                                    .textTheme
                                                    .headlineSmall
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      fontSize: 18,
                                                      color:
                                                          Theme.of(
                                                                context,
                                                              ).brightness ==
                                                              Brightness.light
                                                          ? const Color(
                                                              0xFF3c5152,
                                                            )
                                                          : Colors
                                                                .grey
                                                                .shade300,
                                                    ) ??
                                                const TextStyle(
                                                  fontWeight: FontWeight.w800,
                                                  fontSize: 18,
                                                ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    timeStr,
                                    maxLines: 1,
                                    softWrap: false,
                                    overflow: TextOverflow.visible,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w400,
                                          color:
                                              Theme.of(context).brightness ==
                                                  Brightness.light
                                              ? const Color(0xFF3c5152)
                                              : Colors.grey.shade300,
                                        ),
                                  ),
                                ],
                              ),
                              if (showEditedBadge) ...[
                                const SizedBox(height: 6),
                                _editedBadge(context),
                              ],
                              if ((t.note ?? '').isNotEmpty) ...[
                                const SizedBox(height: 6),
                                _ExpandableNote(
                                  text: t.note ?? '',
                                  style:
                                      Theme.of(
                                        context,
                                      ).textTheme.bodySmall?.copyWith(
                                        color:
                                            Theme.of(context).brightness ==
                                                Brightness.light
                                            ? const Color(
                                                0xFF3c5152,
                                              ).withAlpha((0.6 * 255).round())
                                            : Colors.grey.shade400,
                                      ) ??
                                      const TextStyle(
                                        fontSize: 12,
                                        color: Colors.black54,
                                      ),
                                ),
                              ],
                              if (photoPaths.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                _buildPhotoGallery(context, photoPaths),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${formatAmount(finalBal.abs())} $balLabel',
                    style:
                        Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w500,
                          color:
                              Theme.of(context).brightness == Brightness.light
                              ? const Color(0xFF3c5152)
                              : Colors.grey.shade300,
                        ) ??
                        const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ExpandableNote extends StatefulWidget {
  const _ExpandableNote({
    required this.text,
    required this.style,
  });

  final String text;
  final TextStyle style;
  static const int _collapsedMaxLines = 5;

  @override
  State<_ExpandableNote> createState() => _ExpandableNoteState();
}

class _ExpandableNoteState extends State<_ExpandableNote> {
  bool _expanded = false;

  bool _exceedsLines(double maxWidth, int maxLines) {
    final tp = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: maxLines,
      textDirection: ui.TextDirection.ltr,
      textScaler: MediaQuery.of(context).textScaler,
    )..layout(maxWidth: maxWidth);
    return tp.didExceedMaxLines;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.of(context).size.width;
        final overflowsCollapsed =
            _exceedsLines(maxWidth, _ExpandableNote._collapsedMaxLines);
        final maxLines = _expanded
            ? null
            : _ExpandableNote._collapsedMaxLines;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              style: widget.style,
              maxLines: maxLines,
              overflow: _expanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
            ),
            if (overflowsCollapsed)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: InkWell(
                  onTap: () => setState(() => _expanded = !_expanded),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    child: Text(
                      _expanded ? 'Show less' : 'Show more',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
