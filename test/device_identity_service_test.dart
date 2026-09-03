import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oneshare/config/app_environment.dart';
import 'package:oneshare/services/crypto/crypto_key_storage.dart';
import 'package:oneshare/services/crypto/trust_store.dart';
import 'package:oneshare/services/device_identity_service.dart';

void main() {
  setUp(() {
    DeviceIdentityService.resetForTesting();
  });

  group('DeviceIdentityService', () {
    test('generates and persists new Ed25519 identity on first run', () async {
      final storage = InMemoryKeyStorage();
      expect(DeviceIdentityService.isInitialized, isFalse);

      final identity = await DeviceIdentityService.initialize(storage: storage);
      expect(DeviceIdentityService.isInitialized, isTrue);
      expect(identity.deviceId.isNotEmpty, isTrue);
      expect(identity.deviceName.startsWith('OneShare-'), isTrue);
      expect(identity.identityPublicKeyBytes.length, 32);
      expect(identity.fingerprint.length, 64);
      expect(identity.shortFingerprint.length, 16);
      expect(identity.formattedFingerprint.contains(' '), isTrue);

      // Verify stored values in storage
      expect(await storage.containsKey(key: DeviceIdentityService.kDeviceIdKey), isTrue);
      expect(await storage.containsKey(key: DeviceIdentityService.kDeviceNameKey), isTrue);
      expect(await storage.containsKey(key: DeviceIdentityService.kIdentityPrivateKeyKey), isTrue);

      // Check that fingerprint matches SHA-256 of public key
      final expectedFp = await DeviceIdentityService.computeFingerprint(identity.identityPublicKeyBytes);
      expect(identity.fingerprint, expectedFp);
    });

    test('reloads existing persistent identity across app restarts', () async {
      final storage = InMemoryKeyStorage();

      // First run: initializes and saves
      final firstIdentity = await DeviceIdentityService.initialize(storage: storage);
      final firstDeviceId = firstIdentity.deviceId;
      final firstDeviceName = firstIdentity.deviceName;
      final firstPublicKey = firstIdentity.identityPublicKeyBytes;
      final firstFingerprint = firstIdentity.fingerprint;

      // Simulate app restart by resetting in-memory singleton
      DeviceIdentityService.resetForTesting();
      expect(DeviceIdentityService.isInitialized, isFalse);

      // Second run: re-initializes from same storage
      final reloadedIdentity = await DeviceIdentityService.initialize(storage: storage);
      expect(reloadedIdentity.deviceId, firstDeviceId);
      expect(reloadedIdentity.deviceName, firstDeviceName);
      expect(reloadedIdentity.identityPublicKeyBytes, firstPublicKey);
      expect(reloadedIdentity.fingerprint, firstFingerprint);

      // Test cryptographic signing with restored keypair
      final message = [10, 20, 30, 40];
      final ed25519 = Ed25519();
      final sig = await ed25519.sign(message, keyPair: reloadedIdentity.identityKeyPair);
      final verified = await ed25519.verify(
        message,
        signature: sig,
      );
      expect(verified, isTrue);
    });

    test('synchronous identity access provides valid fallback if uninitialized', () {
      expect(DeviceIdentityService.isInitialized, isFalse);
      final fallback = DeviceIdentityService.identity;

      expect(fallback.deviceId.isNotEmpty, isTrue);
      expect(fallback.deviceName.isNotEmpty, isTrue);
      expect(fallback.identityPublicKeyBytes.length, 32);
      expect(fallback.fingerprint.length, 64);
    });

    test('storage read error throws IdentityStorageException and halts startup', () async {
      final failingStorage = _FailingKeyStorage();
      expect(
        () => DeviceIdentityService.initialize(storage: failingStorage),
        throwsA(isA<IdentityStorageException>()),
      );
      expect(DeviceIdentityService.isInitialized, isFalse);
    });

    test('corrupted or incomplete identity in storage throws IdentityCorruptedException and refuses silent regeneration', () async {
      final storage = InMemoryKeyStorage();
      await storage.write(key: DeviceIdentityService.kDeviceIdKey, value: 'device-123');
      await storage.write(key: DeviceIdentityService.kDeviceNameKey, value: 'OneShare-Test');
      // Intentionally write an invalid Base64 string that is not 32 bytes
      await storage.write(key: DeviceIdentityService.kIdentityPrivateKeyKey, value: 'bm90LWEtdmFsaWQtMzItYnl0ZS1zZWVk');

      expect(
        () => DeviceIdentityService.initialize(storage: storage),
        throwsA(isA<IdentityCorruptedException>()),
      );
      expect(DeviceIdentityService.isInitialized, isFalse);
    });

    test('explicit resetIdentity clears existing keys and purges trust store', () async {
      final storage = InMemoryKeyStorage();
      final trustStore = TrustStore(storage: storage);

      final original = await DeviceIdentityService.initialize(storage: storage);
      final originalDeviceId = original.deviceId;
      final originalFp = original.fingerprint;

      // Add a peer record to trust store
      await trustStore.markManuallyVerified(
        fingerprint: '1111222233334444555566677778888999900001111222233334444555566677',
        identityPublicKeyBytes: Uint8List.fromList(List.generate(32, (i) => i)),
        deviceName: 'Alice',
        deviceId: 'alice-id-1',
      );
      expect((await trustStore.getAllPeers()).length, 1);

      // Perform reset passing trustStore
      final reset = await DeviceIdentityService.resetIdentity(
        storage: storage,
        trustStore: trustStore,
      );
      expect(reset.deviceId, isNot(equals(originalDeviceId)));
      expect(reset.fingerprint, isNot(equals(originalFp)));
      expect(DeviceIdentityService.isInitialized, isTrue);

      // Verify trust store was completely purged
      expect((await trustStore.getAllPeers()).isEmpty, isTrue);
    });

    test('valid Phase 1 identity without commit marker is automatically backfilled with kIdentityCommittedKey', () async {
      final storage = InMemoryKeyStorage();
      final ed25519 = Ed25519();
      final keyPair = await ed25519.newKeyPair();
      final privBytes = await keyPair.extractPrivateKeyBytes();

      // Write valid Phase 1 3-key identity (no commit marker)
      await storage.write(key: DeviceIdentityService.kDeviceIdKey, value: 'phase1-device-id');
      await storage.write(key: DeviceIdentityService.kDeviceNameKey, value: 'OneShare-Phase1');
      await storage.write(key: DeviceIdentityService.kIdentityPrivateKeyKey, value: base64Encode(privBytes));

      expect(await storage.containsKey(key: DeviceIdentityService.kIdentityCommittedKey), isFalse);

      final loaded = await DeviceIdentityService.initialize(storage: storage);
      expect(loaded.deviceId, 'phase1-device-id');
      expect(loaded.deviceName, 'OneShare-Phase1');

      // Verify commit marker was automatically backfilled
      expect(await storage.containsKey(key: DeviceIdentityService.kIdentityCommittedKey), isTrue);
      expect(await storage.read(key: DeviceIdentityService.kIdentityCommittedKey), 'true');
    });

    test('pre-initialization identity getter throws StateError in staging and production', () {
      AppEnvironment.current = AppEnvironment.production;
      expect(DeviceIdentityService.isInitialized, isFalse);

      expect(
        () => DeviceIdentityService.identity,
        throwsStateError,
      );

      AppEnvironment.resetForTesting();
    });
  });
}

class _FailingKeyStorage implements KeyStorage {
  @override
  Future<String?> read({required String key}) async => throw Exception('Disk read error');
  @override
  Future<void> write({required String key, required String value}) async => throw Exception('Disk write error');
  @override
  Future<void> delete({required String key}) async {}
  @override
  Future<bool> containsKey({required String key}) async => false;
  @override
  Future<void> deleteAll() async {}
}
