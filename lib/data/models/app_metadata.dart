import 'package:isar/isar.dart';

part 'app_metadata.g.dart';

@collection
class AppMetadata {
  Id id = Isar.autoIncrement;

  @Index(unique: true)
  late String key;

  String? value;
}
