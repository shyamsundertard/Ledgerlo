import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar/isar.dart';

import 'providers/theme_provider.dart';

class SettingsScreen extends ConsumerWidget {
  final Isar isar;
  const SettingsScreen({super.key, required this.isar});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDarkMode = ref.watch(themeProvider);

    return Scaffold(
      appBar: AppBar(title: const Text("Menu")),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.dark_mode),
            title: const Text("Dark Mode"),
            trailing: Switch(
              value: isDarkMode,
              onChanged: (_) async {
                await ref.read(themeProvider.notifier).toggleTheme();
              },
            ),
          ),
          const ListTile(
            leading: Icon(Icons.fingerprint),
            title: Text("Enable Biometric"),
          ),
          const ListTile(
            leading: Icon(Icons.backup),
            title: Text("Backup to Drive"),
          ),
          const ListTile(
            leading: Icon(Icons.restore),
            title: Text("Restore from Drive"),
          ),
        ],
      ),
    );
  }
}
