import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Enum for transaction label style
enum TransactionLabelStyle { creditDebit, givenReceived }

final settingsProvider = StateNotifierProvider<SettingsNotifier, TransactionLabelStyle>((ref) {
  return SettingsNotifier();
});

class SettingsNotifier extends StateNotifier<TransactionLabelStyle> {
  SettingsNotifier() : super(TransactionLabelStyle.creditDebit) {
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final labelStyle = prefs.getString('transactionLabelStyle') ?? 'creditDebit';
    state = labelStyle == 'givenReceived' 
        ? TransactionLabelStyle.givenReceived 
        : TransactionLabelStyle.creditDebit;
  }

  Future<void> setLabelStyle(TransactionLabelStyle style) async {
    state = style;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'transactionLabelStyle',
      style == TransactionLabelStyle.givenReceived ? 'givenReceived' : 'creditDebit',
    );
  }
}
