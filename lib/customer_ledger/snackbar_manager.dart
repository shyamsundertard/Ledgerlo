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

  /// Shows a top-aligned snackbar with an action button (e.g. UNDO).
  /// The snackbar auto-dismisses after [duration]. Tapping the action
  /// invokes [onAction] and immediately dismisses.
  static void showTopActionSnackBar(
    BuildContext context, {
    required String message,
    required IconData icon,
    required String actionLabel,
    required VoidCallback onAction,
    required List<OverlayEntry> overlayEntries,
    required List<Timer> overlayTimers,
    Color? backgroundColor,
    Color? foregroundColor,
    Color? actionColor,
    Duration duration = const Duration(seconds: 5),
  }) {
    if (!context.mounted) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    final theme = Theme.of(context);
    final bg =
        backgroundColor ?? theme.colorScheme.inverseSurface;
    final fg = foregroundColor ?? theme.colorScheme.onInverseSurface;
    final action = actionColor ?? theme.colorScheme.inversePrimary;

    for (final timer in overlayTimers) {
      try {
        timer.cancel();
      } catch (_) {}
    }
    overlayTimers.clear();
    for (final entry in overlayEntries) {
      try {
        if (entry.mounted) entry.remove();
      } catch (_) {}
    }
    overlayEntries.clear();

    final isVisible = ValueNotifier<bool>(false);
    var isDisposed = false;
    late OverlayEntry overlayEntry;

    void dismiss() {
      if (isDisposed) return;
      isVisible.value = false;
      Timer(const Duration(milliseconds: 280), () {
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
    }

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
            child: _SwipeDismissibleSnack(
              onDismissed: dismiss,
              child: Container(
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha((0.2 * 255).round()),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, color: fg, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        message,
                        style: TextStyle(color: fg, fontSize: 14),
                      ),
                    ),
                    const SizedBox(width: 4),
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: action,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          letterSpacing: 0.5,
                        ),
                      ),
                      onPressed: () {
                        onAction();
                        dismiss();
                      },
                      child: Text(actionLabel.toUpperCase()),
                    ),
                  ],
                ),
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

      final hideAt = duration - const Duration(milliseconds: 280);
      final hideTimer = Timer(
        hideAt > Duration.zero ? hideAt : duration,
        () {
          if (!isDisposed) isVisible.value = false;
        },
      );
      final removeTimer = Timer(duration, () {
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

/// Wraps a snackbar so the user can swipe up / left / right to dismiss
/// it before its auto-dismiss timer fires.
class _SwipeDismissibleSnack extends StatefulWidget {
  final Widget child;
  final VoidCallback onDismissed;
  const _SwipeDismissibleSnack({
    required this.child,
    required this.onDismissed,
  });

  @override
  State<_SwipeDismissibleSnack> createState() => _SwipeDismissibleSnackState();
}

class _SwipeDismissibleSnackState extends State<_SwipeDismissibleSnack>
    with SingleTickerProviderStateMixin {
  Offset _drag = Offset.zero;
  bool _dismissed = false;

  static const double _dismissThreshold = 60;
  static const double _velocityThreshold = 700;

  void _onUpdate(DragUpdateDetails details) {
    if (_dismissed) return;
    setState(() {
      var dx = _drag.dx + details.delta.dx;
      var dy = _drag.dy + details.delta.dy;
      // Only allow up/left/right movement; clamp downward drag.
      if (dy > 0) dy = 0;
      _drag = Offset(dx, dy);
    });
  }

  void _onEnd(DragEndDetails details) {
    if (_dismissed) return;
    final velocity = details.velocity.pixelsPerSecond;
    final shouldDismiss =
        _drag.dx.abs() > _dismissThreshold ||
        (-_drag.dy) > _dismissThreshold ||
        velocity.dx.abs() > _velocityThreshold ||
        (-velocity.dy) > _velocityThreshold;

    if (shouldDismiss) {
      _dismissed = true;
      // Fling out in the direction of motion.
      final width = MediaQuery.of(context).size.width;
      Offset target;
      if ((-_drag.dy) > _drag.dx.abs() || (-velocity.dy) > velocity.dx.abs()) {
        target = const Offset(0, -300);
      } else if (_drag.dx >= 0) {
        target = Offset(width, 0);
      } else {
        target = Offset(-width, 0);
      }
      setState(() => _drag = target);
      widget.onDismissed();
    } else {
      setState(() => _drag = Offset.zero);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: _onUpdate,
      onPanEnd: _onEnd,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        transform: Matrix4.translationValues(_drag.dx, _drag.dy, 0),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 180),
          opacity: _dismissed ? 0 : 1,
          child: widget.child,
        ),
      ),
    );
  }
}
