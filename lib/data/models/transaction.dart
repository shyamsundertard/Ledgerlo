import 'package:isar/isar.dart';
import '../../core/enums/transaction_type.dart';

part 'transaction.g.dart';

@collection
class Transaction {
  Id id = Isar.autoIncrement;

  @Index()
  int profileId = 0;

  /// Unique ID for backup safety
  @Index(unique: true)
  late String uuid;

  /// Fast lookup by customer
  @Index()
  late int customerId;

  /// credit or debit
  @Enumerated(EnumType.name)
  late TransactionType type;

  /// Amount should always be positive
  late double amount;

  String? note;

  /// Legacy single-photo field kept for backward compatibility.
  String? photoPath;

  /// Preferred multi-photo attachment field (max 3 enforced in UI).
  List<String> photoPaths = [];

  @Index()
  DateTime date = DateTime.now();

  /// Soft delete
  bool isDeleted = false;
  bool isEdited = false;

  DateTime createdAt = DateTime.now();
  DateTime updatedAt = DateTime.now();
}
