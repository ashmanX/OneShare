import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oneshare/config/app_environment.dart';
import 'package:oneshare/services/crypto/crypto_key_storage.dart';
import 'package:oneshare/services/crypto/trust_store.dart';
import 'package:oneshare/services/device_identity_service.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    AppEnvironment.resetForTesting();
    DeviceIdentityService.resetForTesting();
    tempDir = Directory.systemTemp.createTempSync('oneshare_test_mig_');
  });

  tearDown(() {
    AppEnvironment.resetForTesting();
    DeviceIdentityService.resetForTesting();
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('Phase 2: Storage Migration, Persistence & Failure State Tests', () {
    test('real legacy file migration imports keys into Keychain-backed storage and deletes legacy file', () async {
      AppEnvironment.current = AppEnvironment.staging;
      final mockSecure = _MockFlutterSecureStorage();
      final storage = CryptoKeyStorage(
        storage: mockSecure,
        namespacePrefix: AppEnvironment.staging.storageNamespacePrefix,
        allowFallback: false,
      );

      // Create a real legacy file with valid 32-byte seed
      final validSeedBytes = List.generate(32, (i) => i + 1);
      final validSeedB64 = base64Encode(validSeedBytes);
      final legacyFile = File('${tempDir.path}/.oneshare_secure_keys.json');

      final legacyData = {
        'oneshare_device_id': 'legacy-device-id-123',
        'oneshare_device_name': 'OneShare-Legacy',
        'oneshare_identity_priv_key_b64': validSeedB64,
        'oneshare_trust_index_fingerprints': ['fp_legacy_001'],
      };
      await legacyFile.writeAsString(jsonEncode(legacyData));
      expect(await legacyFile.exists(), isTrue);

      // Execute migration
      await storage.migrateLegacyFileIfNeeded(legacyFileOverride: legacyFile);

      // Verify keys migrated into secure storage under staging namespace
      final namespacedPrivKey = 'oneshare.staging.oneshare_identity_priv_key_b64';
      final namespacedCommitted = 'oneshare.staging.oneshare_identity_committed';
      expect(mockSecure.map.containsKey(namespacedPrivKey), isTrue);
      expect(mockSecure.map[namespacedPrivKey], validSeedB64);
      expect(mockSecure.map[namespacedCommitted], 'true');

      // Verify physical legacy file was deleted after confirmed migration
      expect(await legacyFile.exists(), isFalse);
    });

    test('corrupted legacy file is quarantined to .corrupted and triggers per-attempt rollback', () async {
      AppEnvironment.current = AppEnvironment.staging;
      final mockSecure = _MockFlutterSecureStorage();
      // Pre-seed an existing valid staging key that must NOT be deleted by rollback
      mockSecure.map['oneshare.staging.existing_safe_key'] = 'preserve_me';

      final storage = CryptoKeyStorage(
        storage: mockSecure,
        namespacePrefix: AppEnvironment.staging.storageNamespacePrefix,
        allowFallback: false,
      );

      // Create legacy file with invalid 16-byte seed
      final invalidSeedB64 = base64Encode(List.generate(16, (i) => i));
      final legacyFile = File('${tempDir.path}/.oneshare_secure_keys.json');
      await legacyFile.writeAsString(jsonEncode({
        'oneshare_device_id': 'corrupt-device',
        'oneshare_identity_priv_key_b64': invalidSeedB64,
      }));

      // Expect migration to fail closed
      await expectLater(
        storage.migrateLegacyFileIfNeeded(legacyFileOverride: legacyFile),
        throwsA(isA<LegacyMigrationException>()),
      );

      // Verify corrupted file was quarantined
      final quarantinedFile = File('${tempDir.path}/.oneshare_secure_keys.json.corrupted');
      expect(await quarantinedFile.exists(), isTrue);

      // Verify pre-existing key was preserved (per-attempt rollback, never deleteAll)
      expect(mockSecure.map['oneshare.staging.existing_safe_key'], 'preserve_me');
      expect(mockSecure.map.containsKey('oneshare.staging.oneshare_device_id'), isFalse);
    });

    test('TrustStore.load fails closed with TrustStorageException on secure storage read error', () async {
      final failingStorage = _MockFailingStorage();
      final trustStore = TrustStore(storage: failingStorage);

      expect(
        () => trustStore.load(),
        throwsA(isA<TrustStorageException>()),
      );
    });

    test('TrustStore.load fails closed with TrustCorruptedException on malformed index or corrupted fingerprint', () async {
      final storage = InMemoryKeyStorage();
      // Write corrupted non-64-character fingerprint to index
      await storage.write(key: TrustStore.kTrustIndexKey, value: jsonEncode(['invalid_short_fp']));
      final trustStore = TrustStore(storage: storage);

      expect(
        () => trustStore.load(),
        throwsA(isA<TrustCorruptedException>()),
      );
    });

    test('persistent identity restored from namespaced storage has identical public key and fingerprint', () async {
      AppEnvironment.current = AppEnvironment.unitTest;
      final storage = InMemoryKeyStorage();

      // First run: bootstrap
      final id1 = await DeviceIdentityService.initialize(storage: storage);
      final pubKey1 = id1.identityPublicKeyBytes;
      final fp1 = id1.fingerprint;

      // Simulate process death / restart
      DeviceIdentityService.resetForTesting();
      expect(DeviceIdentityService.isInitialized, isFalse);

      // Second run: restore from same storage
      final id2 = await DeviceIdentityService.initialize(storage: storage);
      expect(id2.identityPublicKeyBytes, pubKey1);
      expect(id2.fingerprint, fp1);
      expect(id2.deviceId, id1.deviceId);
      expect(id2.deviceName, id1.deviceName);
    });

    test('storage failure policy: read failure throws IdentityStorageException and never creates fallback identity', () async {
      final failingStorage = _MockFailingStorage();

      expect(
        () => DeviceIdentityService.initialize(storage: failingStorage),
        throwsA(isA<IdentityStorageException>()),
      );

      expect(DeviceIdentityService.isInitialized, isFalse);
    });

    test('StorageUnavailableException formats message without raw exception dump', () {
      final ex = StorageUnavailableException('Keychain locked', 'OSStatus -25308');
      expect(ex.toString(), contains('Keychain locked'));
    });
  });
}

class _MockFlutterSecureStorage extends FlutterSecureStorage {
  final Map<String, String> map = {};

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value != null) {
      map[key] = value;
    }
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => map[key];

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    map.remove(key);
  }

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map.from(map);
}

class _MockFailingStorage implements KeyStorage {
  @override
  Future<String?> read({required String key}) async => throw Exception('Hardware keystore unavailable');
  @override
  Future<void> write({required String key, required String value}) async => throw Exception('Hardware keystore unavailable');
  @override
  Future<void> delete({required String key}) async {}
  @override
  Future<bool> containsKey({required String key}) async => false;
  @override
  Future<void> deleteAll() async {}
}
