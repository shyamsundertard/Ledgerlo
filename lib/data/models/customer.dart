import 'package:isar/isar.dart';

part 'customer.g.dart';

@collection
class Customer {
  Id id = Isar.autoIncrement;

  @Index()
  int profileId = 0;

  /// Unique ID for backup/restore & multi-device safety
  @Index(unique: true)
  late String uuid;

  @Index(caseSensitive: false)
  late String name;

  String? phone;

  /// Optional notes about customer
  String? note;

  /// Cached balance (optional optimization)
  /// You can recalculate if needed
  double currentBalance = 0;

  /// Soft delete support
  bool isDeleted = false;

  DateTime createdAt = DateTime.now();
  DateTime updatedAt = DateTime.now();
}
