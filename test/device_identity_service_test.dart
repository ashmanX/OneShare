import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oneshare/services/crypto/crypto_key_storage.dart';
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
  });
}
