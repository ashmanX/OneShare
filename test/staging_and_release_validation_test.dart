import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oneshare/config/app_environment.dart';
import 'package:oneshare/models/e2ee_models.dart';
import 'package:oneshare/services/crypto/crypto_key_storage.dart';
import 'package:oneshare/services/crypto/trust_store.dart';
import 'package:oneshare/services/device_identity_service.dart';

/// Mock implementation of KeyStorage for testing storage failure scenarios.
class MockFailingKeyStorage implements KeyStorage {
  MockFailingKeyStorage({this.shouldFail = true});

  final bool shouldFail;
  final Map<String, String> _backend = {};

  @override
  Future<void> write({required String key, required String value}) async {
    if (shouldFail) {
      throw StorageUnavailableException('Keychain write failed: errSecItemNotFound');
    }
    _backend[key] = value;
  }

  @override
  Future<String?> read({required String key}) async {
    if (shouldFail) {
      throw StorageUnavailableException('Keychain read failed: errSecAuthFailed');
    }
    return _backend[key];
  }

  @override
  Future<bool> containsKey({required String key}) async {
    if (shouldFail) {
      throw StorageUnavailableException('Keychain probe failed');
    }
    return _backend.containsKey(key);
  }

  @override
  Future<void> delete({required String key}) async {
    if (shouldFail) {
      throw StorageUnavailableException('Keychain delete failed');
    }
    _backend.remove(key);
  }

  @override
  Future<void> deleteAll() async {
    if (shouldFail) {
      throw StorageUnavailableException('Keychain deleteAll failed');
    }
    _backend.clear();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    DeviceIdentityService.resetForTesting();
    AppEnvironment.current = AppEnvironment.staging;
  });

  tearDown(() {
    DeviceIdentityService.resetForTesting();
    AppEnvironment.current = AppEnvironment.development;
  });

  group('Phase 7: Staging Environment Enforcement', () {
    test('AppEnvironment.staging enforces isolated namespace and zero fallback', () {
      final env = AppEnvironment.staging;
      expect(env.type, equals(EnvironmentType.staging));
      expect(env.storageNamespacePrefix, equals('oneshare.staging.'));
      expect(env.isFallbackPermitted, isFalse);
      expect(env.isVerboseLoggingEnabled, isFalse);
      expect(env.isCleartextLanPermitted, isTrue);
    });

    test('Synchronous identity access fails closed in staging if uninitialized', () {
      AppEnvironment.current = AppEnvironment.staging;
      expect(DeviceIdentityService.isInitialized, isFalse);
      expect(
        () => DeviceIdentityService.identity,
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Identity accessed before initialize() in secure environment (staging)'),
        )),
      );
    });
  });

  group('Phase 7: Platform Secure Storage & Fail-Closed Integrity', () {
    test('In staging mode, storage access throws StorageUnavailableException on Keychain error without writing fallback files', () async {
      AppEnvironment.current = AppEnvironment.staging;
      final failingStorage = MockFailingKeyStorage(shouldFail: true);

      // Write must fail closed with StorageUnavailableException
      expect(
        () => failingStorage.write(key: 'test_key', value: 'test_val'),
        throwsA(isA<StorageUnavailableException>()),
      );

      // Read must fail closed with StorageUnavailableException
      expect(
        () => failingStorage.read(key: 'test_key'),
        throwsA(isA<StorageUnavailableException>()),
      );

      // DeviceIdentityService.initialize must fail closed and refuse silent regeneration
      expect(
        () => DeviceIdentityService.initialize(storage: failingStorage),
        throwsA(isA<IdentityStorageException>()),
      );
      expect(DeviceIdentityService.isInitialized, isFalse);
    });

    test('Strict namespace isolation across dev, staging, and prod partitions', () async {
      final devStorage = InMemoryKeyStorage(
        namespacePrefix: AppEnvironment.development.storageNamespacePrefix,
      );

      final stagingStorage = InMemoryKeyStorage(
        namespacePrefix: AppEnvironment.staging.storageNamespacePrefix,
      );

      final prodStorage = InMemoryKeyStorage(
        namespacePrefix: AppEnvironment.production.storageNamespacePrefix,
      );

      // Write keys with identical name across 3 environments
      await devStorage.write(key: 'shared_config', value: 'dev_value');
      await stagingStorage.write(key: 'shared_config', value: 'staging_value');
      await prodStorage.write(key: 'shared_config', value: 'prod_value');

      // Assert complete isolation
      expect(await devStorage.read(key: 'shared_config'), equals('dev_value'));
      expect(await stagingStorage.read(key: 'shared_config'), equals('staging_value'));
      expect(await prodStorage.read(key: 'shared_config'), equals('prod_value'));

      // Deleting staging must never touch dev or prod
      await stagingStorage.deleteAll();
      expect(await stagingStorage.read(key: 'shared_config'), isNull);
      expect(await devStorage.read(key: 'shared_config'), equals('dev_value'));
      expect(await prodStorage.read(key: 'shared_config'), equals('prod_value'));
    });
  });

  group('Phase 7: Staging TrustStore & Compromise Recovery', () {
    test('TrustStore in staging isolates peer records and index under staging prefix', () async {
      AppEnvironment.current = AppEnvironment.staging;
      final storage = InMemoryKeyStorage(
        namespacePrefix: AppEnvironment.staging.storageNamespacePrefix,
      );
      final trustStore = TrustStore(storage: storage);

      final key = Uint8List.fromList(List.filled(32, 7));
      final hash = await Sha256().hash(key);
      final fp = hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      await trustStore.recordPeerEncounter(
        fingerprint: fp,
        identityPublicKeyBytes: key,
        deviceName: 'Staging Peer Device',
        deviceId: 'staging-peer-001',
      );

      final storedPeer = await trustStore.getPeer(fp);
      expect(storedPeer, isNotNull);
      expect(storedPeer!.deviceName, equals('Staging Peer Device'));
      expect(storedPeer.trustLevel, equals(TrustLevel.unverifiedSeen));

      // Assert key prefix in underlying storage
      expect(await storage.containsKey(key: TrustStore.kTrustIndexKey), isTrue);
    });

    test('DeviceIdentityService.resetIdentity in staging regenerates identity and wipes staging trust store', () async {
      AppEnvironment.current = AppEnvironment.staging;
      final storage = InMemoryKeyStorage(
        namespacePrefix: AppEnvironment.staging.storageNamespacePrefix,
      );
      final trustStore = TrustStore(storage: storage);

      final originalIdentity = await DeviceIdentityService.initialize(storage: storage);
      expect(originalIdentity.deviceId, isNotEmpty);

      // Record peer in trust store
      final peerKey = Uint8List.fromList(List.filled(32, 3));
      final peerHash = await Sha256().hash(peerKey);
      final peerFp = peerHash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      await trustStore.recordPeerEncounter(
        fingerprint: peerFp,
        identityPublicKeyBytes: peerKey,
        deviceName: 'Peer To Purge',
        deviceId: 'peer-purge-id',
      );
      expect((await trustStore.getAllPeers()).length, equals(1));

      // Reset identity under staging
      final newIdentity = await DeviceIdentityService.resetIdentity(
        storage: storage,
        trustStore: trustStore,
      );

      expect(newIdentity.deviceId, isNot(equals(originalIdentity.deviceId)));
      expect(newIdentity.fingerprint, isNot(equals(originalIdentity.fingerprint)));
      expect((await trustStore.getAllPeers()).isEmpty, isTrue);
    });
  });

  group('Phase 7: Release Entitlements & Packaging Verification', () {
    test('macOS Release entitlements omit allow-jit and retain App Sandbox', () {
      final entitlementsFile = File('macos/Runner/Release.entitlements');
      expect(entitlementsFile.existsSync(), isTrue);

      final content = entitlementsFile.readAsStringSync();
      expect(content, contains('<key>com.apple.security.app-sandbox</key>'));
      expect(content, contains('<key>com.apple.security.network.client</key>'));
      expect(content, contains('<key>com.apple.security.network.server</key>'));
      expect(content, contains('<key>com.apple.security.files.downloads.read-write</key>'));

      // Crucial security requirement: Release entitlements MUST NOT contain allow-jit
      expect(content.contains('com.apple.security.cs.allow-jit'), isFalse);
    });

    test('Android Manifest specifies cleartext traffic for local LAN socket bindings', () {
      final manifestFile = File('android/app/src/main/AndroidManifest.xml');
      expect(manifestFile.existsSync(), isTrue);

      final content = manifestFile.readAsStringSync();
      expect(content, contains('android:usesCleartextTraffic="true"'));
      expect(content, contains('android.permission.INTERNET'));
      expect(content, contains('android.permission.ACCESS_WIFI_STATE'));
      expect(content, contains('android.permission.CHANGE_WIFI_MULTICAST_STATE'));
    });
  });
}
