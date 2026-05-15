import 'package:isar/isar.dart';

import '../../data/models/app_metadata.dart';
import '../../data/models/business_profile.dart';
import '../../data/models/customer.dart';
import '../../data/models/transaction.dart';

class ProfileRepository {
  static const String _activeProfileKey = 'active_profile_id';
  static const String _defaultProfileName = 'Default Business';

  static String _normalizedName(String name) =>
      name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  static Future<bool> _hasDuplicateName(
    Isar isar,
    String name, {
    int? exceptProfileId,
  }) async {
    final normalized = _normalizedName(name);
    final profiles = await isar.businessProfiles.where().findAll();
    return profiles.any((profile) {
      if (exceptProfileId != null && profile.id == exceptProfileId) {
        return false;
      }
      return _normalizedName(profile.name) == normalized;
    });
  }

  static Future<int> ensureInitialized(Isar isar) async {
    var profiles = await isar.businessProfiles.where().findAll();

    if (profiles.isEmpty) {
      final defaultProfile = BusinessProfile()
        ..uuid = DateTime.now().microsecondsSinceEpoch.toString()
        ..name = _defaultProfileName
        ..createdAt = DateTime.now()
        ..updatedAt = DateTime.now();

      await isar.writeTxn(() async {
        await isar.businessProfiles.put(defaultProfile);
      });

      profiles = [defaultProfile];
    }

    final activeMetadata = await isar.appMetadatas
        .filter()
        .keyEqualTo(_activeProfileKey)
        .findFirst();

    int? activeProfileId = int.tryParse(activeMetadata?.value ?? '');
    final knownProfileIds = profiles.map((profile) => profile.id).toSet();
    if (activeProfileId == null || !knownProfileIds.contains(activeProfileId)) {
      activeProfileId = profiles.first.id;
      await _setActiveProfileMetadata(isar, activeProfileId);
    }

    await _migrateLegacyDataToProfile(isar, activeProfileId);
    return activeProfileId;
  }

  static Future<List<BusinessProfile>> getProfiles(Isar isar) {
    return isar.businessProfiles.where().sortByName().findAll();
  }

  static Future<BusinessProfile> createProfile(
    Isar isar,
    String name, {
    bool setActive = true,
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw StateError('Profile name is required.');
    }

    if (await _hasDuplicateName(isar, trimmedName)) {
      throw StateError('A profile with this name already exists.');
    }

    final profile = BusinessProfile()
      ..uuid = DateTime.now().microsecondsSinceEpoch.toString()
      ..name = trimmedName
      ..createdAt = DateTime.now()
      ..updatedAt = DateTime.now();

    await isar.writeTxn(() async {
      await isar.businessProfiles.put(profile);
    });

    if (setActive) {
      await setActiveProfile(isar, profile.id);
    }
    return profile;
  }

  static Future<void> setActiveProfile(Isar isar, int profileId) {
    return _setActiveProfileMetadata(isar, profileId);
  }

  static Future<void> renameProfile(
    Isar isar,
    int profileId,
    String name,
  ) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) return;

    final profile = await isar.businessProfiles.get(profileId);
    if (profile == null) return;

    if (await _hasDuplicateName(
      isar,
      trimmedName,
      exceptProfileId: profileId,
    )) {
      throw StateError('A profile with this name already exists.');
    }

    profile.name = trimmedName;
    profile.updatedAt = DateTime.now();

    await isar.writeTxn(() async {
      await isar.businessProfiles.put(profile);
    });
  }

  static Future<void> deleteProfile(Isar isar, int profileId) async {
    final profiles = await isar.businessProfiles.where().findAll();
    if (profiles.length <= 1) {
      throw StateError('At least one profile is required.');
    }

    final remainingProfiles = profiles.where((p) => p.id != profileId).toList();
    final fallbackProfileId = remainingProfiles.first.id;

    final customers = await isar.customers
        .filter()
        .profileIdEqualTo(profileId)
        .findAll();

    final transactionsForProfile = await isar.transactions
        .filter()
        .profileIdEqualTo(profileId)
        .findAll();

    await isar.writeTxn(() async {
      if (transactionsForProfile.isNotEmpty) {
        await isar.transactions.deleteAll(
          transactionsForProfile.map((tx) => tx.id).toList(),
        );
      }

      if (customers.isNotEmpty) {
        await isar.customers.deleteAll(customers.map((c) => c.id).toList());
      }

      await isar.businessProfiles.delete(profileId);
    });

    await _setActiveProfileMetadata(isar, fallbackProfileId);
  }

  static Future<void> _setActiveProfileMetadata(
    Isar isar,
    int profileId,
  ) async {
    final existing = await isar.appMetadatas
        .filter()
        .keyEqualTo(_activeProfileKey)
        .findFirst();

    final metadata = existing ?? (AppMetadata()..key = _activeProfileKey);
    metadata.value = profileId.toString();

    await isar.writeTxn(() async {
      await isar.appMetadatas.put(metadata);
    });
  }

  static Future<void> _migrateLegacyDataToProfile(
    Isar isar,
    int profileId,
  ) async {
    final customers = await isar.customers
        .filter()
        .profileIdEqualTo(0)
        .findAll();

    final transactions = await isar.transactions
        .filter()
        .profileIdEqualTo(0)
        .findAll();

    if (customers.isEmpty && transactions.isEmpty) {
      return;
    }

    await isar.writeTxn(() async {
      for (final customer in customers) {
        customer.profileId = profileId;
        customer.updatedAt = DateTime.now();
      }
      for (final transaction in transactions) {
        transaction.profileId = profileId;
        transaction.updatedAt = DateTime.now();
      }

      if (customers.isNotEmpty) {
        await isar.customers.putAll(customers);
      }
      if (transactions.isNotEmpty) {
        await isar.transactions.putAll(transactions);
      }
    });
  }
}
