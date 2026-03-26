import 'package:ledger_app/core/enums/transaction_type.dart';
import 'package:ledger_app/data/models/transaction.dart' as txn_model;

class TransactionUtils {
  static double computeBalance(List<txn_model.Transaction> txs) {
    double bal = 0;
    for (final t in txs) {
      bal += (t.type == TransactionType.credit) ? t.amount : -t.amount;
    }
    return bal;
  }

  static String formatDate(DateTime date) {
    const monthNames = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    return '${date.day} ${monthNames[date.month - 1]} ${date.year}';
  }

  static String formatTimeOfDay(DateTime dateTime) {
    return dateTime.toLocal().toString().split(' ')[1].substring(0, 5);
  }

  static String getDateLabel(String dateStr) {
    // dateStr format: yyyy-mm-dd
    final parts = dateStr.split('-');
    final year = int.tryParse(parts[0]) ?? 0;
    final month = int.tryParse(parts[1]) ?? 1;
    final day = int.tryParse(parts[2]) ?? 1;
    const monthNames = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final monthName = monthNames[month - 1];
    return '$day $monthName $year';
  }
}
