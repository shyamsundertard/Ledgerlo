import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:isar/isar.dart';

import 'data/models/customer.dart';
import 'data/models/transaction.dart';
import 'data/models/app_metadata.dart';
import 'data/models/business_profile.dart';
import 'providers/theme_provider.dart';
import 'core/backup/backup_scheduler.dart';
import 'core/backup/backup_notification_service.dart';
import 'splash_screen.dart';

const Color _brandBlue = Color(0xFF1E88E5);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await BackupNotificationService.initialize();
  await BackupScheduler.initialize();
  await BackupScheduler.ensurePeriodicAutoBackupTask();

  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDarkMode = ref.watch(themeProvider);

    return MaterialApp(
      title: 'Ledgerlo',
      debugShowCheckedModeBanner: false,
      theme: lightTheme(),
      darkTheme: darkTheme(),
      themeMode: isDarkMode ? ThemeMode.dark : ThemeMode.light,
      themeAnimationDuration: const Duration(milliseconds: 320),
      themeAnimationCurve: Curves.easeInOutCubic,
      home: const _AppBootstrap(),
    );
  }
}

class _AppBootstrap extends StatefulWidget {
  const _AppBootstrap();

  @override
  State<_AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<_AppBootstrap> {
  late final Future<Isar> _isarFuture;

  @override
  void initState() {
    super.initState();
    _isarFuture = _openIsar();
  }

  Future<Isar> _openIsar() async {
    final dir = await getApplicationDocumentsDirectory();
    return Isar.open([
      CustomerSchema,
      TransactionSchema,
      AppMetadataSchema,
      BusinessProfileSchema,
    ], directory: dir.path);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Isar>(
      future: _isarFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final isar = snapshot.data;
        if (isar == null) {
          return const Scaffold(
            body: Center(child: Text('Failed to initialize app storage.')),
          );
        }

        return SplashScreen(isar: isar);
      },
    );
  }
}

class _SlideFromRightPageTransitionsBuilder extends PageTransitionsBuilder {
  const _SlideFromRightPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final offsetTween = Tween<Offset>(begin: Offset(1, 0), end: Offset.zero);
    final curveTween = CurveTween(curve: Curves.easeOutCubic);
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SlideTransition(
        position: animation.drive(offsetTween.chain(curveTween)),
        child: child,
      ),
    );
  }
}

ThemeData lightTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: _brandBlue,
    brightness: Brightness.light,
  );
  final pageBackground = Color.alphaBlend(
    _brandBlue.withAlpha((0.08 * 255).round()),
    colorScheme.surface,
  );
  final appBarTint = Color.alphaBlend(
    _brandBlue.withAlpha((0.24 * 255).round()),
    colorScheme.surface,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: pageBackground,
    canvasColor: pageBackground,
    colorScheme: colorScheme,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: _SlideFromRightPageTransitionsBuilder(),
        TargetPlatform.iOS: _SlideFromRightPageTransitionsBuilder(),
        TargetPlatform.macOS: _SlideFromRightPageTransitionsBuilder(),
        TargetPlatform.linux: _SlideFromRightPageTransitionsBuilder(),
        TargetPlatform.windows: _SlideFromRightPageTransitionsBuilder(),
        TargetPlatform.fuchsia: _SlideFromRightPageTransitionsBuilder(),
      },
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: appBarTint,
      surfaceTintColor: appBarTint,
      scrolledUnderElevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(14)),
      ),
    ),
  );
}

ThemeData darkTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: _brandBlue,
    brightness: Brightness.dark,
  );
  final pageBackground = Color.alphaBlend(
    _brandBlue.withAlpha((0.22 * 255).round()),
    colorScheme.surface,
  );
  final appBarTint = Color.alphaBlend(
    _brandBlue.withAlpha((0.36 * 255).round()),
    colorScheme.surface,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: pageBackground,
    canvasColor: pageBackground,
    colorScheme: colorScheme,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: _SlideFromRightPageTransitionsBuilder(),
        TargetPlatform.iOS: _SlideFromRightPageTransitionsBuilder(),
        TargetPlatform.macOS: _SlideFromRightPageTransitionsBuilder(),
        TargetPlatform.linux: _SlideFromRightPageTransitionsBuilder(),
        TargetPlatform.windows: _SlideFromRightPageTransitionsBuilder(),
        TargetPlatform.fuchsia: _SlideFromRightPageTransitionsBuilder(),
      },
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: appBarTint,
      surfaceTintColor: appBarTint,
      scrolledUnderElevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(14)),
      ),
    ),
  );
}
