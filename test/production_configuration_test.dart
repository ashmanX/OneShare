import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:oneshare/config/app_environment.dart';

void main() {
  group('Phase 8a Production Configuration Tests', () {
    test('Environment production invariants are enforced', () {
      AppEnvironment.current = AppEnvironment.production;
      final env = AppEnvironment.current;
      expect(env.type, equals(EnvironmentType.production));
      expect(env.storageNamespacePrefix, equals('oneshare.prod.'));
      expect(env.isFallbackPermitted, isFalse);
      expect(env.isCleartextLanPermitted, isTrue);
      expect(env.isVerboseLoggingEnabled, isFalse);
    });

    test('Zero occurrences of legacy com.example.droplan in project and configs', () {
      final projectDir = Directory.current;
      final targetFiles = [
        'android/app/build.gradle.kts',
        'macos/Runner/Configs/AppInfo.xcconfig',
        'macos/Runner.xcodeproj/project.pbxproj',
        'ios/Runner.xcodeproj/project.pbxproj',
        'linux/CMakeLists.txt',
        'windows/runner/Runner.rc',
      ];

      for (final relPath in targetFiles) {
        final file = File('${projectDir.path}/$relPath');
        expect(file.existsSync(), isTrue, reason: '$relPath should exist');
        final content = file.readAsStringSync();
        expect(
          content.contains('com.example.droplan'),
          isFalse,
          reason: '$relPath still contains "com.example.droplan"',
        );
      }
    });

    test('Zero occurrences of legacy droplan.app in macos build targets', () {
      final projectDir = Directory.current;
      final targetFiles = [
        'macos/Runner.xcodeproj/project.pbxproj',
        'macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme',
      ];

      for (final relPath in targetFiles) {
        final file = File('${projectDir.path}/$relPath');
        expect(file.existsSync(), isTrue, reason: '$relPath should exist');
        final content = file.readAsStringSync();
        expect(
          content.contains('droplan.app'),
          isFalse,
          reason: '$relPath still contains "droplan.app"',
        );
        expect(
          content.contains('oneshare.app'),
          isTrue,
          reason: '$relPath should refer to "oneshare.app"',
        );
      }
    });

    test('Zero occurrences of legacy method/event channels (com.example.oneshare)', () {
      final projectDir = Directory.current;
      final targetFiles = [
        'android/app/src/main/kotlin/com/oneshare/app/MainActivity.kt',
        'macos/Runner/AppDelegate.swift',
        'lib/services/oneshare_discovery_service.dart',
        'lib/services/network_monitor_service.dart',
        'lib/services/transfer_service.dart',
        'lib/main.dart',
      ];

      for (final relPath in targetFiles) {
        final file = File('${projectDir.path}/$relPath');
        expect(file.existsSync(), isTrue, reason: '$relPath should exist');
        final content = file.readAsStringSync();
        expect(
          content.contains('com.example.oneshare'),
          isFalse,
          reason: '$relPath still contains legacy channel "com.example.oneshare"',
        );
        expect(
          content.contains('com.oneshare.app'),
          isTrue,
          reason: '$relPath should use production channel "com.oneshare.app"',
        );
      }
    });

    test('Kotlin files are completely relocated to com.oneshare.app package', () {
      final projectDir = Directory.current;
      final oldDir = Directory('${projectDir.path}/android/app/src/main/kotlin/com/example');
      expect(oldDir.existsSync(), isFalse, reason: 'Legacy com.example directory should be deleted');

      final kotlinFiles = [
        'MainActivity.kt',
        'NsdHelper.kt',
        'InstantFilePicker.kt',
        'UriStreamHandler.kt',
      ];

      for (final kt in kotlinFiles) {
        final file = File('${projectDir.path}/android/app/src/main/kotlin/com/oneshare/app/$kt');
        expect(file.existsSync(), isTrue, reason: '$kt should exist under com/oneshare/app/');
        final content = file.readAsStringSync();
        expect(
          content.startsWith('package com.oneshare.app'),
          isTrue,
          reason: '$kt should declare package com.oneshare.app',
        );
      }
    });

    test('Android Manifest specifies required discovery permissions and no unused permissions', () {
      final manifestFile = File('android/app/src/main/AndroidManifest.xml');
      expect(manifestFile.existsSync(), isTrue);
      final manifest = manifestFile.readAsStringSync();

      // Verified permissions
      expect(manifest.contains('android.permission.NEARBY_WIFI_DEVICES'), isTrue);
      expect(manifest.contains('android:usesPermissionFlags="neverForLocation"'), isTrue);
      expect(manifest.contains('android.permission.ACCESS_FINE_LOCATION'), isTrue);
      expect(manifest.contains('android:maxSdkVersion="32"'), isTrue);
      expect(manifest.contains('android:allowBackup="false"'), isTrue);

      // Raw IP P2P cleartext transport retained with justification
      expect(manifest.contains('android:usesCleartextTraffic="true"'), isTrue);

      // Pruned unearned permissions (must NOT be present until implemented)
      expect(manifest.contains('FOREGROUND_SERVICE'), isFalse);
      expect(manifest.contains('POST_NOTIFICATIONS'), isFalse);
    });

    test('iOS Info.plist contains matching Bonjour and Local Network declarations', () {
      final iosPlist = File('ios/Runner/Info.plist');
      expect(iosPlist.existsSync(), isTrue);
      final content = iosPlist.readAsStringSync();

      expect(content.contains('NSLocalNetworkUsageDescription'), isTrue);
      expect(content.contains('NSBonjourServices'), isTrue);
      expect(content.contains('<string>_oneshare._tcp</string>'), isTrue);
    });

    test('macOS Info.plist contains matching Bonjour and Local Network declarations', () {
      final macosPlist = File('macos/Runner/Info.plist');
      expect(macosPlist.existsSync(), isTrue);
      final content = macosPlist.readAsStringSync();

      expect(content.contains('NSLocalNetworkUsageDescription'), isTrue);
      expect(content.contains('NSBonjourServices'), isTrue);
      expect(content.contains('<string>_oneshare._tcp</string>'), isTrue);
    });

    test('Bundled fonts exist and are registered in pubspec.yaml', () {
      expect(File('assets/fonts/PlusJakartaSans-Regular.ttf').existsSync(), isTrue);
      expect(File('assets/fonts/SpaceMono-Regular.ttf').existsSync(), isTrue);

      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec.contains('family: PlusJakartaSans'), isTrue);
      expect(pubspec.contains('assets/fonts/PlusJakartaSans-Regular.ttf'), isTrue);
      expect(pubspec.contains('family: SpaceMono'), isTrue);
      expect(pubspec.contains('assets/fonts/SpaceMono-Regular.ttf'), isTrue);
    });

    test('Release build signing is decoupled from debug keys', () {
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      expect(
        gradle.contains('signingConfig = signingConfigs.getByName("debug")'),
        isFalse,
        reason: 'Release build should NOT sign with debug key',
      );
      expect(
        gradle.contains('hasReleaseSigning'),
        isTrue,
        reason: 'build.gradle.kts should check for release signing properties',
      );
    });
  });
}
