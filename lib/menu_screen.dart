import 'package:currency_picker/currency_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar/isar.dart';

import 'providers/currency_provider.dart';
import 'providers/theme_provider.dart';
import 'settings_page.dart';

class MenuScreen extends ConsumerWidget {
  final Isar isar;
  const MenuScreen({super.key, required this.isar});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDarkMode = ref.watch(themeProvider);
    final currency = ref.watch(currencyProvider);

    return Scaffold(
      appBar: AppBar(title: const Text("Menu")),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.monetization_on),
            title: const Text('Currency'),
            subtitle: Text(currency),
            onTap: () {
              showCurrencyPicker(
                context: context,
                showFlag: true,
                showCurrencyName: true,
                showCurrencyCode: true,
                onSelect: (Currency cur) async {
                  await ref
                      .read(currencyProvider.notifier)
                      .setCurrency(cur.code);
                },
              );
            },
          ),
          const Divider(
            height: 1,
            indent: 60,
            endIndent: 12,
          ),
          ListTile(
            leading: Icon(isDarkMode ? Icons.dark_mode : Icons.light_mode),
            title: const Text("Dark Mode"),
            subtitle: Text(isDarkMode ? 'Enabled' : 'Disabled'),
            trailing: Transform.scale(
              scale: 1.08,
              child: Switch(
                value: isDarkMode,
                thumbIcon: WidgetStateProperty.resolveWith<Icon?>(
                  (states) => Icon(
                    states.contains(WidgetState.selected)
                        ? Icons.dark_mode
                        : Icons.light_mode,
                    size: 14,
                  ),
                ),
                activeThumbColor: Theme.of(context).colorScheme.onPrimary,
                activeTrackColor: Theme.of(context).colorScheme.primary,
                inactiveThumbColor: Theme.of(context).colorScheme.surface,
                inactiveTrackColor: Theme.of(
                  context,
                ).colorScheme.outlineVariant.withAlpha((0.55 * 255).round()),
                trackOutlineColor: const WidgetStatePropertyAll(
                  Colors.transparent,
                ),
                onChanged: (enabled) async {
                  await ref.read(themeProvider.notifier).setDarkMode(enabled);
                },
              ),
            ),
          ),
          const Divider(
            height: 1,
            indent: 60,
            endIndent: 12,
          ),
          ListTile(
            leading: const Icon(Icons.settings),
            title: const Text("Settings"),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => SettingsPage(isar: isar)),
              );
            },
          ),
          const Divider(
            height: 1,
            indent: 60,
            endIndent: 12,
          ),
        ],
      ),
    );
  }
}
