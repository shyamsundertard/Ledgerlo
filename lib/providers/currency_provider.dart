import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final currencyProvider = StateNotifierProvider<CurrencyNotifier, String>((ref) {
  return CurrencyNotifier();
});

class CurrencyNotifier extends StateNotifier<String> {
  CurrencyNotifier() : super('INR') {
    _loadCurrency();
  }

  Future<void> _loadCurrency() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString('currencyCode') ?? 'INR';
    state = code;
  }

  Future<void> setCurrency(String code) async {
    state = code;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('currencyCode', code);
  }
}
