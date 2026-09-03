# Phase 8a Implementation Plan: Production-Ready Code Without Accounts (Corrected)

## 1. Overview & Objectives
The primary objective of **Phase 8a** ("Production-Ready Code Without Accounts") is to make the OneShare codebase store-submittable, clean, and fully production-configured without requiring paid Apple Developer Program or Google Play Console accounts.

Holding off on publishing must not block this phase. Everything that can be finalized, tested, secured, and frozen locally must be completed before any store accounts are enrolled or bound in Phase 8b.

---

## 2. User Review Required & Frozen Decisions

> [!IMPORTANT]
> **Key Decisions & Freezes for Phase 8a:**
>
> 1. **Single Frozen Application Identifier (`com.oneshare.app`):**
>    - **Choice**: Strictly **`com.oneshare.app`** across all platforms.
>    - **Android**: `namespace = "com.oneshare.app"`, `applicationId = "com.oneshare.app"`.
>    - **macOS & iOS**: `PRODUCT_BUNDLE_IDENTIFIER = com.oneshare.app`.
>    - **macOS Build Target**: Rename `droplan.app` to `oneshare.app` across `Runner.xcodeproj` (productReference, PBXFileReference, `TEST_HOST` paths) and `Runner.xcscheme`.
>    - **RunnerTests Bundle IDs**: Update all `*.RunnerTests` bundle identifiers from `com.example.droplan.RunnerTests` to `com.oneshare.app.RunnerTests` on macOS and iOS.
>    - **Linux**: `APPLICATION_ID "com.oneshare.app"`.
>    - **Windows**: `CompanyName "com.oneshare"`, `LegalCopyright "Copyright (C) 2026 com.oneshare. All rights reserved."` in `windows/runner/Runner.rc`.
>    - **Method/Event Channels**: Update all channel names from `com.example.oneshare/*` to `com.oneshare.app/*`.
>
> 2. **Complete Kotlin Package Move**:
>    - Move directory from `android/app/src/main/kotlin/com/example/droplan/` to `android/app/src/main/kotlin/com/oneshare/app/`.
>    - Update `package com.oneshare.app` in all 4 `.kt` files:
>      - [`MainActivity.kt`](file:///Users/ashmaanmainali/Projects/oneshare/android/app/src/main/kotlin/com/example/droplan/MainActivity.kt)
>      - [`NsdHelper.kt`](file:///Users/ashmaanmainali/Projects/oneshare/android/app/src/main/kotlin/com/example/droplan/NsdHelper.kt)
>      - [`InstantFilePicker.kt`](file:///Users/ashmaanmainali/Projects/oneshare/android/app/src/main/kotlin/com/example/droplan/InstantFilePicker.kt)
>      - [`UriStreamHandler.kt`](file:///Users/ashmaanmainali/Projects/oneshare/android/app/src/main/kotlin/com/example/droplan/UriStreamHandler.kt)
>
> 3. **Android Cleartext Transport Policy for Raw-IP P2P LAN**:
>    - **Reality of Android Network Security Config**: Android `network_security_config.xml` `<domain>` elements do NOT support CIDR blocks (e.g. `10.0.0.0/8`, `192.168.0.0/16`) or raw IP address strings. Configuring `<base-config cleartextTrafficPermitted="false" />` causes Android's network stack to block all direct HTTP connections to peer DHCP IP addresses (e.g. `http://192.168.x.y:4040/`), which would break P2P LAN transfers entirely.
>    - **Architecture Decision**: Retain `android:usesCleartextTraffic="true"` globally on Android, paired with our verified cryptographic justification:
>      - The application makes **zero external HTTP/HTTPS requests** to any cloud backend or public internet host.
>      - The local HTTP server is bound exclusively to ephemeral LAN ports for device-to-device transport.
>      - **All application payloads, metadata, and control frames are end-to-end encrypted** at the application layer via Ed25519 authenticated handshakes and XChaCha20-Poly1305 authenticated streaming. The underlying HTTP layer is merely an unauthenticated raw socket transport.
>      - Provide an optional `network_security_config.xml` explicitly documenting this P2P architecture and configuring `.local` domain overrides if needed for mDNS hostnames.
>
> 4. **Pruned, Non-Extraneous Android Permissions**:
>    - **Avoid Unused Permission Rejections**: The current codebase does not implement foreground services (`startForeground()`, Android notification channels) or background notification dispatchers. Requesting `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`, or `POST_NOTIFICATIONS` in Phase 8a would trigger Google Play Console rejections for declaring permissions without active in-app functional implementations. These are deferred until their background service feature lands.
>    - **Permissions to Add in 8a (Active Discovery Requisite)**:
>      - `android.permission.NEARBY_WIFI_DEVICES` with `android:usesPermissionFlags="neverForLocation"` (Android 13+ / API 33+ requirement for Wi-Fi P2P and NSD discovery).
>      - `android.permission.ACCESS_FINE_LOCATION` with `android:maxSdkVersion="32"` (retains Wi-Fi SSID discovery compatibility on Android 12 and below without triggering location disclosures on modern Android 13+).
>      - `android:allowBackup="false"` in `<application>` to strictly block credential extraction and keystore database leakage via cloud or ADB backup.
>
> 5. **Verified Bonjour / Local Network Permissions on iOS & macOS**:
>    - Native discovery in `NsdHelper.kt` and `AppDelegate.swift` registers `_oneshare._tcp`.
>    - Add missing `NSLocalNetworkUsageDescription` and `NSBonjourServices` (`<string>_oneshare._tcp</string>`) to [`ios/Runner/Info.plist`](file:///Users/ashmaanmainali/Projects/oneshare/ios/Runner/Info.plist) to match macOS.
>
> 6. **Bundled Fonts for Truthful Zero-Network Disclosure**:
>    - `google_fonts` package downloads font files at runtime from Google CDN when not pre-bundled, contradicting a "zero-network / zero-telemetry / offline" privacy disclosure.
>    - **Action**: Bundle `PlusJakartaSans` font assets locally in `assets/fonts/`, declare in `pubspec.yaml`, and configure `ThemeData` to use local font family rather than dynamic HTTP CDN fetches.
>
> 7. **Release Signing & Local Dry-Run Keystore**:
>    - Remove `signingConfig = signingConfigs.getByName("debug")` from `buildTypes.release` in `build.gradle.kts`.
>    - Add release signing configuration that reads `key.properties` (or environment variables) if present, but fails gracefully with a helpful message when missing.
>    - **Explicit Build Behavior**: Without `key.properties`, running `flutter build apk --release` is explicitly expected to fail signing. Provide a local dry-run self-signed upload keystore script (`scripts/create_test_keystore.sh`) and local template (`android/key.properties.template`) so release builds can be compiled and validated locally without checking secrets into git.

---

## 3. Proposed Changes

### 3.1 Identifier & Channel Standardization (`com.oneshare.app`)

#### [MODIFY] [android/app/build.gradle.kts](file:///Users/ashmaanmainali/Projects/oneshare/android/app/build.gradle.kts)
- Update `namespace = "com.oneshare.app"`
- Update `applicationId = "com.oneshare.app"`
- Remove `signingConfig = signingConfigs.getByName("debug")` from `release` block. Configure conditional signing via `key.properties`.

#### [MOVE & MODIFY] Android Kotlin Source Files
- Move `android/app/src/main/kotlin/com/example/droplan/` -> `android/app/src/main/kotlin/com/oneshare/app/`
- Update `package com.oneshare.app` in `MainActivity.kt`, `NsdHelper.kt`, `InstantFilePicker.kt`, `UriStreamHandler.kt`.
- Update channel strings to `com.oneshare.app/*`:
  - `com.oneshare.app/nsd_control`
  - `com.oneshare.app/nsd_events`
  - `com.oneshare.app/instant_picker`
  - `com.oneshare.app/uri_stream`
  - `com.oneshare.app/wifi_control`
  - `com.oneshare.app/wifi_events`

#### [MODIFY] Dart Service Method/Event Channels & Swift AppDelegate
- Update channel strings across:
  - [`lib/services/oneshare_discovery_service.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/oneshare_discovery_service.dart)
  - [`lib/services/network_monitor_service.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/network_monitor_service.dart)
  - [`lib/services/transfer_service.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/services/transfer_service.dart)
  - [`lib/main.dart`](file:///Users/ashmaanmainali/Projects/oneshare/lib/main.dart)
  - [`macos/Runner/AppDelegate.swift`](file:///Users/ashmaanmainali/Projects/oneshare/macos/Runner/AppDelegate.swift)

#### [MODIFY] macOS & iOS Project Configurations
- [`macos/Runner/Configs/AppInfo.xcconfig`](file:///Users/ashmaanmainali/Projects/oneshare/macos/Runner/Configs/AppInfo.xcconfig):
  - `PRODUCT_BUNDLE_IDENTIFIER = com.oneshare.app`
  - `PRODUCT_COPYRIGHT = Copyright © 2026 com.oneshare. All rights reserved.`
- [`macos/Runner.xcodeproj/project.pbxproj`](file:///Users/ashmaanmainali/Projects/oneshare/macos/Runner.xcodeproj/project.pbxproj):
  - Update `droplan.app` -> `oneshare.app` in `path`, `productReference`, and `TEST_HOST`.
  - Update `PRODUCT_BUNDLE_IDENTIFIER = com.oneshare.app.RunnerTests`.
- [`macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme`](file:///Users/ashmaanmainali/Projects/oneshare/macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme):
  - Update `BuildableName = "droplan.app"` -> `BuildableName = "oneshare.app"`.
- [`ios/Runner.xcodeproj/project.pbxproj`](file:///Users/ashmaanmainali/Projects/oneshare/ios/Runner.xcodeproj/project.pbxproj):
  - Update `PRODUCT_BUNDLE_IDENTIFIER = com.oneshare.app` (Runner) and `com.oneshare.app.RunnerTests` (RunnerTests).
- [`ios/Runner/Info.plist`](file:///Users/ashmaanmainali/Projects/oneshare/ios/Runner/Info.plist):
  - Add `NSLocalNetworkUsageDescription` and `NSBonjourServices` (`_oneshare._tcp`).
- [`linux/CMakeLists.txt`](file:///Users/ashmaanmainali/Projects/oneshare/linux/CMakeLists.txt):
  - Set `APPLICATION_ID "com.oneshare.app"`.
- [`windows/runner/Runner.rc`](file:///Users/ashmaanmainali/Projects/oneshare/windows/runner/Runner.rc):
  - Replace `com.example` with `com.oneshare`.

---

### 3.2 Network Security & Permissions Hardening

#### [MODIFY] [android/app/src/main/AndroidManifest.xml](file:///Users/ashmaanmainali/Projects/oneshare/android/app/src/main/AndroidManifest.xml)
- Maintain `android:usesCleartextTraffic="true"` for direct peer-to-peer IP communication, with cryptographic E2EE security justification documented.
- Set `android:allowBackup="false"`.
- Add required discovery permissions:
  - `android.permission.NEARBY_WIFI_DEVICES` with `android:usesPermissionFlags="neverForLocation"`
  - `android.permission.ACCESS_FINE_LOCATION` with `android:maxSdkVersion="32"`
- Omit `FOREGROUND_SERVICE` and `POST_NOTIFICATIONS` until background transfer features are actively implemented.

---

### 3.3 Bundled Local Fonts & Zero-Network Privacy
- Download and place `PlusJakartaSans` TTF font files into `assets/fonts/`.
- Declare font family in `pubspec.yaml`.
- Update `lib/main.dart` theme to use local `fontFamily: 'PlusJakartaSans'` instead of runtime `GoogleFonts.plusJakartaSansTextTheme()`, eliminating Google CDN network requests during execution.

---

### 3.4 Release Signing Templates & Documentation

#### [NEW] `android/key.properties.template`
- Template file demonstrating `storePassword`, `keyPassword`, `keyAlias`, `storeFile` for release signing. Ensure `key.properties` is in `.gitignore`.

#### [NEW] `scripts/create_test_keystore.sh`
- Local script for generating a self-signed dry-run keystore to validate release builds locally without checking in secrets.

#### [NEW] `docs/KEY_MANAGEMENT.md`
- Documentation for generating upload keys via `keytool`, key custody, rotation procedures, and zero-leakage policies.

#### [NEW] `docs/STORE_METADATA_AND_PRIVACY.md`
- Data Safety form declaration (Zero data collected, zero data shared).
- Apple Privacy Nutrition Labels ("Data Not Collected").
- Permission justifications for local networking and nearby devices.

---

### 3.5 Automated Production Configuration Test Suite

#### [NEW] [test/production_configuration_test.dart](file:///Users/ashmaanmainali/Projects/oneshare/test/production_configuration_test.dart)
- Tests to assert:
  1. No occurrences of `com.example.droplan` in any build, project, or source file.
  2. No occurrences of `com.example.oneshare` in method channels.
  3. Release build type does NOT use debug signing.
  4. `AndroidManifest.xml` enforces `android:allowBackup="false"` and contains required Wi-Fi discovery permissions (`NEARBY_WIFI_DEVICES`, `ACCESS_FINE_LOCATION maxSdkVersion="32"`).
  5. `AndroidManifest.xml` does not declare unearned foreground service or notification permissions.
  6. macOS and iOS `Info.plist` files have valid `NSLocalNetworkUsageDescription` and `_oneshare._tcp` Bonjour services.
  7. Fonts are bundled locally without dynamic CDN dependencies.
  8. Production environment invariants (`AppEnvironment.production`, `oneshare.prod.`, `isFallbackPermitted == false`).

---

## 4. Verification Plan

### Automated Tests
```bash
flutter test test/production_configuration_test.dart
dart analyze lib/ test/
flutter test
```

### Local Build Verifications
1. **macOS Release Build**:
   ```bash
   flutter build macos --release --dart-define=ENV=production
   ```
2. **Android Release Compilation**:
   - Verify that running without `key.properties` fails cleanly with a clear message: `"Release signing not configured"`.
   - Verify that generating a local test upload keystore via `scripts/create_test_keystore.sh` and configuring `key.properties` compiles the release APK successfully:
     ```bash
     flutter build apk --release --dart-define=ENV=production
     ```

---

## 5. Phase 8a Deliverables & Exit Criteria
1. Zero occurrences of `com.example.droplan` and `com.example.oneshare` anywhere in the repository.
2. Complete Kotlin package migration to `com.oneshare.app`.
3. Cleartext P2P LAN transport policy documented and justified with application-layer E2EE v2 guarantees.
4. Active Android Wi-Fi discovery permissions (`NEARBY_WIFI_DEVICES`, `ACCESS_FINE_LOCATION maxSdkVersion="32"`) and `android:allowBackup="false"`, omitting undeclared FGS/notification permissions.
5. Matching iOS and macOS Bonjour declarations (`_oneshare._tcp`) and Local Network descriptions.
6. Fonts bundled locally to ensure 100% offline zero-network privacy compliance.
7. Release signing configuration decoupled from debug keys with local key template, dry-run script, and custody guide.
8. 100% passing tests in `test/production_configuration_test.dart` and full test suite regression.
9. `PHASE_8A_IMPLEMENTATION_REPORT.md` documenting evidence and readiness for Phase 8b.
