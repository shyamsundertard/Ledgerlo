import 'package:isar/isar.dart';

part 'business_profile.g.dart';

@collection
class BusinessProfile {
  Id id = Isar.autoIncrement;

  @Index(unique: true)
  late String uuid;

  @Index(caseSensitive: false)
  late String name;

  DateTime createdAt = DateTime.now();
  DateTime updatedAt = DateTime.now();
}
