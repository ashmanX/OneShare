import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:oneshare/models/e2ee_models.dart';
import 'package:oneshare/services/crypto/crypto_key_storage.dart';
import 'package:oneshare/services/crypto/trust_store.dart';

void main() {
  late InMemoryKeyStorage storage;
  late TrustStore trustStore;

  final samplePubKey1 = Uint8List.fromList(List.generate(32, (i) => i + 1));
  const sampleFp1 = '0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20';

  final samplePubKey2 = Uint8List.fromList(List.generate(32, (i) => i + 33));
  const sampleFp2 = '2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40';

  setUp(() {
    storage = InMemoryKeyStorage();
    trustStore = TrustStore(storage: storage);
  });

  group('TrustStore - 3-State Trust Lifecycle & Safety', () {
    test('unseen peer evaluates as untrusted initially', () async {
      final eval = await trustStore.evaluatePeer(
        fingerprint: sampleFp1,
        deviceName: "Alice's Phone",
        deviceId: 'dev-alice-01',
      );

      expect(eval.fingerprint, sampleFp1);
      expect(eval.trustLevel, TrustLevel.untrusted);
      expect(eval.isKnownFingerprint, isFalse);
      expect(eval.hasIdentityMismatchForDeviceName, isFalse);
      expect(eval.existingRecord, isNull);
    });

    test('first encounter is recorded as unverifiedSeen and is NOT trusted', () async {
      final record = await trustStore.recordPeerEncounter(
        fingerprint: sampleFp1,
        identityPublicKeyBytes: samplePubKey1,
        deviceName: "Alice's Phone",
        deviceId: 'dev-alice-01',
      );

      expect(record.trustLevel, TrustLevel.unverifiedSeen);
      expect(record.isTrusted, isFalse);
      expect(record.fingerprint, sampleFp1);
      expect(record.deviceName, "Alice's Phone");

      // Evaluation now shows it is known as unverifiedSeen (NOT trusted)
      final eval = await trustStore.evaluatePeer(
        fingerprint: sampleFp1,
        deviceName: "Alice's Phone",
        deviceId: 'dev-alice-01',
      );
      expect(eval.trustLevel, TrustLevel.unverifiedSeen);
      expect(eval.isKnownFingerprint, isTrue);
      expect(eval.hasIdentityMismatchForDeviceName, isFalse);
    });

    test('repeat connection with unverified peer is NEVER auto-promoted to trusted', () async {
      // First session
      await trustStore.recordPeerEncounter(
        fingerprint: sampleFp1,
        identityPublicKeyBytes: samplePubKey1,
        deviceName: "Alice's Phone",
        deviceId: 'dev-alice-01',
      );

      // Repeat session (simulate subsequent transfer)
      final secondRecord = await trustStore.recordPeerEncounter(
        fingerprint: sampleFp1,
        identityPublicKeyBytes: samplePubKey1,
        deviceName: "Alice's Phone (Updated)",
        deviceId: 'dev-alice-01',
      );

      // Trust level remains unverifiedSeen — NO AUTOMATIC PROMOTION
      expect(secondRecord.trustLevel, TrustLevel.unverifiedSeen);
      expect(secondRecord.isTrusted, isFalse);
      expect(secondRecord.deviceName, "Alice's Phone (Updated)");
    });

    test('markManuallyVerified explicitly elevates status to manuallyVerified (trusted)', () async {
      // First recorded as seen
      await trustStore.recordPeerEncounter(
        fingerprint: sampleFp1,
        identityPublicKeyBytes: samplePubKey1,
        deviceName: "Alice's Phone",
        deviceId: 'dev-alice-01',
      );

      // User performs out-of-band SAS comparison and confirms
      final verified = await trustStore.markManuallyVerified(
        fingerprint: sampleFp1,
        identityPublicKeyBytes: samplePubKey1,
        deviceName: "Alice's Phone",
        deviceId: 'dev-alice-01',
      );

      expect(verified.trustLevel, TrustLevel.manuallyVerified);
      expect(verified.isTrusted, isTrue);

      // Subsequent evaluation shows manuallyVerified
      final eval = await trustStore.evaluatePeer(
        fingerprint: sampleFp1,
        deviceName: "Alice's Phone",
        deviceId: 'dev-alice-01',
      );
      expect(eval.trustLevel, TrustLevel.manuallyVerified);
      expect(eval.isKnownFingerprint, isTrue);
    });

    test('manuallyVerified status persists across reload and repeat encounters', () async {
      // Verify peer
      await trustStore.markManuallyVerified(
        fingerprint: sampleFp1,
        identityPublicKeyBytes: samplePubKey1,
        deviceName: "Alice's Phone",
        deviceId: 'dev-alice-01',
      );

      // Simulate app restart with a fresh TrustStore instance over same storage
      final reloadedStore = TrustStore(storage: storage);

      // Subsequent encounter does NOT demote manuallyVerified
      final encounter = await reloadedStore.recordPeerEncounter(
        fingerprint: sampleFp1,
        identityPublicKeyBytes: samplePubKey1,
        deviceName: "Alice's Phone New Name",
        deviceId: 'dev-alice-01',
      );

      expect(encounter.trustLevel, TrustLevel.manuallyVerified);
      expect(encounter.isTrusted, isTrue);
      expect(encounter.deviceName, "Alice's Phone New Name");
    });

    test('detects identity mismatch when known deviceName presents different fingerprint', () async {
      // Alice is known and verified
      await trustStore.markManuallyVerified(
        fingerprint: sampleFp1,
        identityPublicKeyBytes: samplePubKey1,
        deviceName: "Alice's Phone",
        deviceId: 'dev-alice-01',
      );

      // Mallory connects claiming to be "Alice's Phone" but with sampleFp2
      final eval = await trustStore.evaluatePeer(
        fingerprint: sampleFp2,
        deviceName: "Alice's Phone",
        deviceId: 'dev-mallory-99',
      );

      expect(eval.isKnownFingerprint, isFalse);
      expect(eval.trustLevel, TrustLevel.untrusted);
      expect(eval.hasIdentityMismatchForDeviceName, isTrue);
      expect(eval.mismatchedRecord, isNotNull);
      expect(eval.mismatchedRecord!.fingerprint, sampleFp1);
    });

    test('detects identity mismatch when known deviceId presents different fingerprint', () async {
      // Bob is known with deviceId
      await trustStore.recordPeerEncounter(
        fingerprint: sampleFp1,
        identityPublicKeyBytes: samplePubKey1,
        deviceName: "Bob's Tablet",
        deviceId: 'device-id-bob-42',
      );

      // Attacker uses same deviceId with different key
      final eval = await trustStore.evaluatePeer(
        fingerprint: sampleFp2,
        deviceName: 'Different Name',
        deviceId: 'device-id-bob-42',
      );

      expect(eval.isKnownFingerprint, isFalse);
      expect(eval.hasIdentityMismatchForDeviceName, isTrue);
      expect(eval.mismatchedRecord!.deviceId, 'device-id-bob-42');
    });

    test('removePeer and clearAll correctly purge records from memory and storage', () async {
      await trustStore.recordPeerEncounter(
        fingerprint: sampleFp1,
        identityPublicKeyBytes: samplePubKey1,
        deviceName: 'Dev 1',
        deviceId: 'id1',
      );
      await trustStore.recordPeerEncounter(
        fingerprint: sampleFp2,
        identityPublicKeyBytes: samplePubKey2,
        deviceName: 'Dev 2',
        deviceId: 'id2',
      );

      expect((await trustStore.getAllPeers()).length, 2);

      await trustStore.removePeer(sampleFp1);
      expect(await trustStore.getPeer(sampleFp1), isNull);
      expect(await trustStore.getPeer(sampleFp2), isNotNull);

      await trustStore.clearAll();
      expect((await trustStore.getAllPeers()).isEmpty, isTrue);
    });
  });
}
