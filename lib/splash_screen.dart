import 'package:flutter/material.dart';
import 'package:isar/isar.dart';
import 'core/security/app_lock_gate.dart';
import 'core/widgets/app_logo.dart';
import 'home_screen.dart';

class SplashScreen extends StatefulWidget {
  final Isar isar;
  const SplashScreen({super.key, required this.isar});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => AppLockGate(child: HomeScreen(isar: widget.isar)),
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppLogo(height: 72),
            const SizedBox(height: 14),
            Text(
              'Ledgerlo',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}
