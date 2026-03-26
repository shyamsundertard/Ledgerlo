import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../providers/security_provider.dart';

class AppLockGate extends ConsumerStatefulWidget {
  final Widget child;

  const AppLockGate({super.key, required this.child});

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate>
    with WidgetsBindingObserver {
  final LocalAuthentication _localAuth = LocalAuthentication();

  bool _unlocked = false;
  bool _isAuthenticating = false;
  bool _authPromptInProgress = false;
  bool _shouldRelockOnResume = false;
  bool _initialAuthTriggered = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      if (_authPromptInProgress) {
        return;
      }
      _shouldRelockOnResume = true;
      return;
    }

    if (state == AppLifecycleState.resumed) {
      if (_authPromptInProgress) {
        return;
      }
      final settings = ref.read(securityProvider);
      if (!settings.isLoaded) {
        return;
      }
      if (_shouldRelockOnResume && settings.appLockEnabled && _unlocked) {
        _shouldRelockOnResume = false;
        setState(() {
          _unlocked = false;
          _errorMessage = null;
        });
        _authenticate();
      }
    }
  }

  Future<void> _authenticate() async {
    if (_isAuthenticating) {
      return;
    }

    final settings = ref.read(securityProvider);
    if (!settings.appLockEnabled || kIsWeb) {
      if (mounted) {
        setState(() {
          _unlocked = true;
          _errorMessage = null;
        });
      }
      return;
    }

    setState(() {
      _isAuthenticating = true;
      _authPromptInProgress = true;
      _errorMessage = null;
    });

    try {
      final isSupported = await _localAuth.isDeviceSupported();
      final canCheckBiometrics = await _localAuth.canCheckBiometrics;

      if (!isSupported && !canCheckBiometrics) {
        setState(() {
          _unlocked = true;
          _errorMessage = null;
        });
        return;
      }

      final didAuthenticate = await _localAuth.authenticate(
        localizedReason: 'Authenticate to open Ledgerlo',
        biometricOnly: false,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _unlocked = didAuthenticate;
        _errorMessage = didAuthenticate ? null : 'Authentication was canceled.';
      });
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }

      final fallbackAllowed =
          error.code == 'NotAvailable' ||
          error.code == 'NotEnrolled' ||
          error.code == 'PasscodeNotSet';

      setState(() {
        _unlocked = fallbackAllowed;
        _errorMessage = fallbackAllowed
            ? null
            : error.message ?? 'Authentication failed.';
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _unlocked = false;
        _errorMessage = 'Authentication failed. Please try again.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isAuthenticating = false;
          _authPromptInProgress = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(securityProvider);

    if (!settings.isLoaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (settings.appLockEnabled &&
        !_unlocked &&
        !_isAuthenticating &&
        !_initialAuthTriggered) {
      _initialAuthTriggered = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _authenticate();
        }
      });
    }

    if (!settings.appLockEnabled || _unlocked) {
      return widget.child;
    }

    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock, size: 56),
              const SizedBox(height: 16),
              Text(
                'Ledgerlo is locked',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'Use your device lock method to continue.',
                textAlign: TextAlign.center,
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                Text(
                  _errorMessage!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _isAuthenticating ? null : _authenticate,
                icon: _isAuthenticating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.lock_open),
                label: Text(_isAuthenticating ? 'Checking...' : 'Unlock'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
