import 'dart:async';
import 'package:flutter/material.dart';

class SnackBarManager {
  static void showTopSnackBar(
    BuildContext context,
    String message,
    Color backgroundColor,
    IconData icon,
    List<OverlayEntry> overlayEntries,
    List<Timer> overlayTimers,
  ) {
    if (!context.mounted) return;
    final overlay = Overlay.of(context, rootOverlay: true);

    for (final timer in overlayTimers) {
      try {
        timer.cancel();
      } catch (_) {}
    }
    overlayTimers.clear();

    for (final entry in overlayEntries) {
      try {
        if (entry.mounted) {
          entry.remove();
        }
      } catch (_) {}
    }
    overlayEntries.clear();

    final isVisible = ValueNotifier<bool>(false);
    var isDisposed = false;

    late OverlayEntry overlayEntry;

    overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        top: MediaQuery.of(context).padding.top + 16,
        left: 16,
        right: 16,
        child: Material(
          color: Colors.transparent,
          child: ValueListenableBuilder<bool>(
            valueListenable: isVisible,
            builder: (context, visible, child) {
              return AnimatedSlide(
                offset: visible ? Offset.zero : const Offset(0, -1.0),
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                child: AnimatedOpacity(
                  opacity: visible ? 1 : 0,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  child: child,
                ),
              );
            },
            child: Container(
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha((0.2 * 255).round()),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      message,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    try {
      overlay.insert(overlayEntry);
      overlayEntries.add(overlayEntry);

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!isDisposed) {
          isVisible.value = true;
        }
      });

      final hideTimer = Timer(const Duration(milliseconds: 2600), () {
        isVisible.value = false;
      });

      final removeTimer = Timer(const Duration(milliseconds: 2900), () {
        try {
          if (overlayEntry.mounted) overlayEntry.remove();
        } catch (_) {}
        try {
          isDisposed = true;
          isVisible.dispose();
        } catch (_) {}
        overlayEntries.remove(overlayEntry);
        overlayTimers.removeWhere((t) => !t.isActive);
      });
      overlayTimers.add(hideTimer);
      overlayTimers.add(removeTimer);
    } catch (_) {}
  }
}
