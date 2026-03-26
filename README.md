# Ledgerlo

Ledgerlo is a Flutter-based customer ledger app for small businesses and individuals.

It supports multi-profile bookkeeping, customer-wise transaction history, analytics, backup/restore, and secure app access.

## Features

- Multiple business profiles
- Customer ledger with transaction details
- Transaction labels mode: `Credit/Debit` or `Given/Received`
- Advanced search (customer + transaction matches with time filters)
- Analytics dashboard
- Local backup/restore (`CSV` / `ZIP`)
- Optional Google Drive backup integration
- Optional app lock using device authentication

## Tech Stack

- Flutter + Dart
- Riverpod
- Isar database
- SharedPreferences

## Getting Started

### Prerequisites

- Flutter SDK installed
- Android Studio / Xcode (for platform builds)
- Java 17+

### Install

```bash
flutter pub get
```

### Run

```bash
flutter run
```

## Google Drive Backup Setup

Google Drive backup/restore requires OAuth client IDs.

### 1) Create OAuth credentials in Google Cloud

- Enable Google Drive API.
- Create OAuth credentials:
  - Web client (for `GOOGLE_WEB_CLIENT_ID`)
  - iOS client (for `GOOGLE_IOS_CLIENT_ID`)
  - Server/Web client (for `GOOGLE_SERVER_CLIENT_ID`)

### 2) Android configuration

- Add Android package + SHA fingerprints in Google Cloud OAuth.
- Package ID in this project: `com.ledgerlo.app`
- Run with:

```bash
flutter run \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=YOUR_SERVER_CLIENT_ID
```

### 3) iOS configuration

- Set `GOOGLE_REVERSED_CLIENT_ID` in:
  - `ios/Flutter/Debug.xcconfig`
  - `ios/Flutter/Release.xcconfig`
- Run with:

```bash
flutter run \
  --dart-define=GOOGLE_IOS_CLIENT_ID=YOUR_IOS_CLIENT_ID \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=YOUR_SERVER_CLIENT_ID
```

### 4) Web configuration

```bash
flutter run -d chrome \
  --dart-define=GOOGLE_WEB_CLIENT_ID=YOUR_WEB_CLIENT_ID \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=YOUR_SERVER_CLIENT_ID
```

## Release Build

### Android APK (direct sharing/install)

```bash
flutter build apk --release
```

Output:

- `build/app/outputs/flutter-apk/app-release.apk`

### Android App Bundle (Play Store)

```bash
flutter build appbundle --release
```

Output:

- `build/app/outputs/bundle/release/app-release.aab`

## Release Signing

1. Create keystore (one time):

```bash
mkdir -p keystore
keytool -genkeypair -v -keystore keystore/upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

2. Create `android/key.properties` from `android/key.properties.example`.

3. Fill:

- `storeFile`
- `storePassword`
- `keyAlias`
- `keyPassword`

> `android/key.properties` is ignored by git.

## Project Notes

- Primary Android application id: `com.ledgerlo.app`
- Keep keystore + passwords backed up safely (password manager + secure storage).
