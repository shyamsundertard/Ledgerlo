import '../providers/settings_provider.dart';

String getTransactionLabel(
  TransactionLabelStyle labelStyle,
  bool isCredit,
) {
  if (labelStyle == TransactionLabelStyle.givenReceived) {
    return isCredit ? 'Received' : 'Given';
  }
  return isCredit ? 'Credit' : 'Debit';
}

String getTransactionLabelsTitle(TransactionLabelStyle labelStyle) {
  return labelStyle == TransactionLabelStyle.givenReceived ? 'Received' : 'Credit';
}

String getTransactionLabelsTitle2(TransactionLabelStyle labelStyle) {
  return labelStyle == TransactionLabelStyle.givenReceived ? 'Given' : 'Debit';
}
