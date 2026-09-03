import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oneshare/models/e2ee_models.dart';
import 'package:oneshare/services/crypto/crypto_key_storage.dart';
import 'package:oneshare/services/crypto/trust_store.dart';

void main() {
  late InMemoryKeyStorage storage;
  late TrustStore trustStore;

  final samplePubKey1 = Uint8List.fromList(List.generate(32, (i) => i + 1));
  late String sampleFp1;

  final samplePubKey2 = Uint8List.fromList(List.generate(32, (i) => i + 33));
  late String sampleFp2;

  setUp(() async {
    final hash1 = await Sha256().hash(samplePubKey1);
    sampleFp1 = hash1.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    final hash2 = await Sha256().hash(samplePubKey2);
    sampleFp2 = hash2.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

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

    test('findCandidatePeers correctly resolves unique verified peer and flags ambiguous matches', () async {
      // 1. Peer 1 is manuallyVerified
      await trustStore.markManuallyVerified(
        fingerprint: sampleFp1,
        identityPublicKeyBytes: samplePubKey1,
        deviceName: 'Alice Phone',
        deviceId: 'dev-alice-01',
      );

      // Query by deviceId finds unique verified peer
      final candidates1 = await trustStore.findCandidatePeers(deviceId: 'dev-alice-01');
      expect(candidates1.length, 1);
      expect(candidates1.first.fingerprint, sampleFp1);
      expect(candidates1.first.trustLevel, TrustLevel.manuallyVerified);

      // 2. Peer 2 has the same deviceName 'Alice Phone' but different deviceId and fingerprint
      await trustStore.recordPeerEncounter(
        fingerprint: sampleFp2,
        identityPublicKeyBytes: samplePubKey2,
        deviceName: 'Alice Phone',
        deviceId: 'dev-alice-02',
      );

      // Query by deviceName returns multiple candidates (ambiguous match)
      final candidatesByName = await trustStore.findCandidatePeers(deviceName: 'Alice Phone');
      expect(candidatesByName.length, 2);

      // Query by non-existent deviceId returns empty list
      final candidatesEmpty = await trustStore.findCandidatePeers(deviceId: 'unknown-id');
      expect(candidatesEmpty.isEmpty, isTrue);
    });

    test('TrustStore.load rejects duplicate fingerprint in trust index', () async {
      await storage.write(
        key: TrustStore.kTrustIndexKey,
        value: jsonEncode([sampleFp1, sampleFp1]),
      );
      expect(
        () => trustStore.load(),
        throwsA(isA<TrustCorruptedException>()),
      );
    });

    test('TrustStore.load rejects peer record where SHA-256 of public key does not match fingerprint', () async {
      // Index references sampleFp1
      await storage.write(
        key: TrustStore.kTrustIndexKey,
        value: jsonEncode([sampleFp1]),
      );
      // But record has samplePubKey2 (which hashes to sampleFp2, mismatching sampleFp1)
      final recordJson = jsonEncode(PeerRecord(
        fingerprint: sampleFp1,
        identityPublicKeyBytes: samplePubKey2,
        deviceName: 'Mismatch Peer',
        deviceId: 'dev-mismatch',
        trustLevel: TrustLevel.unverifiedSeen,
        firstSeen: DateTime.now(),
        lastSeen: DateTime.now(),
      ).toJson());
      await storage.write(
        key: '${TrustStore.kTrustStorePrefix}$sampleFp1',
        value: recordJson,
      );

      expect(
        () => trustStore.load(),
        throwsA(isA<TrustCorruptedException>()),
      );
    });
  });
}
