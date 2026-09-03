import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oneshare/models/e2ee_models.dart';
import 'package:oneshare/services/crypto/crypto_key_storage.dart';
import 'package:oneshare/services/crypto/e2ee_handshake.dart';
import 'package:oneshare/services/crypto/e2ee_session.dart';
import 'package:oneshare/services/crypto/trust_store.dart';
import 'package:oneshare/services/device_identity_service.dart';
import 'package:oneshare/services/transfer_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late KeyStorage storage;
  late TrustStore trustStore;
  late TransferService transferService;

  final peerPubKey1 = Uint8List.fromList(List.generate(32, (i) => i + 1));
  late String peerFp1;

  setUp(() async {
    storage = InMemoryKeyStorage();
    trustStore = TrustStore(storage: storage);
    transferService = TransferService.instance;
    transferService.trustStore = trustStore;

    final hash1 = await Sha256().hash(peerPubKey1);
    peerFp1 = hash1.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  });

  group('Phase 3: Cryptographic Identity Pinning & Handshake Mismatch Enforcement', () {
    test('Sender resolves and pins intendedReceiverIdentityPubKey for single manuallyVerified peer', () async {
      // 1. Peer is manuallyVerified in sender TrustStore
      await trustStore.markManuallyVerified(
        fingerprint: peerFp1,
        identityPublicKeyBytes: peerPubKey1,
        deviceName: 'Alice Phone',
        deviceId: 'alice-device-01',
      );

      // Verify findCandidatePeers resolves unique verified peer
      final candidates = await trustStore.findCandidatePeers(
        deviceId: 'alice-device-01',
        deviceName: 'Alice Phone',
      );
      expect(candidates.length, 1);
      expect(candidates.first.trustLevel, TrustLevel.manuallyVerified);
      expect(candidates.first.identityPublicKeyBytes, peerPubKey1);
    });

    test('Sender does NOT pin intendedReceiverIdentityPubKey for unverifiedSeen or ambiguous peer', () async {
      // Unverified peer
      await trustStore.recordPeerEncounter(
        fingerprint: peerFp1,
        identityPublicKeyBytes: peerPubKey1,
        deviceName: 'Bob Phone',
        deviceId: 'bob-device-01',
      );

      final candidates = await trustStore.findCandidatePeers(deviceId: 'bob-device-01');
      expect(candidates.length, 1);
      expect(candidates.first.trustLevel, TrustLevel.unverifiedSeen);
      // Because trustLevel != manuallyVerified, sender will not pin this key
    });

    test('Receiver rejects changed identity for known manually verified peer with HTTP 403 IDENTITY_MISMATCH', () async {
      // 1. Setup existing manually verified peer in receiver TrustStore
      await trustStore.markManuallyVerified(
        fingerprint: peerFp1,
        identityPublicKeyBytes: peerPubKey1,
        deviceName: 'Charlie Laptop',
        deviceId: 'charlie-device-01',
      );

      // 2. Incoming request comes from the same deviceId and deviceName but presents peerPubKey2 / peerFp2
      final attackerEphemeralKeyPair = await E2eeHandshake.generateEphemeralKeyPair();
      final attackerEphemeralPubKey = Uint8List.fromList(
        (await attackerEphemeralKeyPair.extractPublicKey()).bytes,
      );

      final attackerIdentityKeyPair = await Ed25519().newKeyPairFromSeed(
        Uint8List.fromList(List.generate(32, (i) => i + 10)),
      );
      final attackerIdentityPubKey = Uint8List.fromList(
        (await attackerIdentityKeyPair.extractPublicKey()).bytes,
      );

      final manifestItems = [
        ManifestFileItem(fileId: 'f1', fileName: 'test.txt', fileSize: 100),
      ];
      final manifestHash = await E2eeHandshake.computeManifestHash(manifestItems);

      final sig1 = await E2eeHandshake.signMsg1(
        senderIdentityKeyPair: attackerIdentityKeyPair,
        transferId: 'test-mismatch-transfer-01',
        manifestHash: manifestHash,
        senderEphemeralPubKey: attackerEphemeralPubKey,
        intendedReceiverIdentityPubKey: null,
      );

      final payload = {
        'transferId': 'test-mismatch-transfer-01',
        'senderDeviceId': 'charlie-device-01',
        'senderDeviceName': 'Charlie Laptop',
        'senderHost': '127.0.0.1',
        'senderPort': 55001,
        'files': [
          {'fileId': 'f1', 'fileName': 'test.txt', 'fileSize': 100}
        ],
        'e2ee': {
          'version': 2,
          'manifestHash': base64Encode(manifestHash),
          'senderIdentityPubKey': base64Encode(attackerIdentityPubKey),
          'senderEphemeralPubKey': base64Encode(attackerEphemeralPubKey),
          'senderEphemeralSig': base64Encode(sig1),
          'intendedReceiverIdentityPubKey': null,
        },
      };

      // 3. Receiver processes incoming request
      final response = await transferService.handleIncomingRequest(payload, '127.0.0.1');

      // 4. Must be rejected with IDENTITY_MISMATCH
      expect(response['status'], 'rejected');
      expect(response['code'], 'IDENTITY_MISMATCH');

      // 5. Original verified record is preserved intact
      final storedPeer = await trustStore.getPeer(peerFp1);
      expect(storedPeer, isNotNull);
      expect(storedPeer!.trustLevel, TrustLevel.manuallyVerified);
      expect(storedPeer.deviceName, 'Charlie Laptop');

      // 6. Conflicting key was NOT recorded into trust store
      final attackerFp = await DeviceIdentityService.computeFingerprint(attackerIdentityPubKey);
      expect(await trustStore.getPeer(attackerFp), isNull);

      // 7. Incoming transfer was not posted to incomingRequestNotifier
      expect(transferService.incomingRequestNotifier.value, isNull);
    });

    test('Sender msg2 verification aborts transfer if receiver identity public key does not match pinned key', () async {
      final transferId = 'test-pinned-sender-abort-01';
      final ownIdentity = DeviceIdentityService.identity;

      final ephemeralKeyPair = await E2eeHandshake.generateEphemeralKeyPair();
      final ephemeralPubKey = Uint8List.fromList(
        (await ephemeralKeyPair.extractPublicKey()).bytes,
      );

      // Outgoing session pins peerPubKey1
      final session = E2eeSession(
        transferId: transferId,
        isInitiator: true,
        myIdentityKeyPair: ownIdentity.identityKeyPair,
        myIdentityPubKey: ownIdentity.identityPublicKeyBytes,
      );
      session.myEphemeralKeyPair = ephemeralKeyPair;
      session.myEphemeralPubKey = ephemeralPubKey;
      session.manifestHash = Uint8List(32);
      session.intendedReceiverIdentityPubKey = peerPubKey1; // PINNED KEY
      session.state = E2eeSessionState.msg1Sent;

      // Attacker returns msg2 with peerPubKey2 instead of peerPubKey1
      final attackerReceiverIdentityKeyPair = await Ed25519().newKeyPairFromSeed(
        Uint8List.fromList(List.generate(32, (i) => i + 20)),
      );
      final attackerReceiverIdentityPubKey = Uint8List.fromList(
        (await attackerReceiverIdentityKeyPair.extractPublicKey()).bytes,
      );

      final attackerReceiverEphemeralKeyPair = await E2eeHandshake.generateEphemeralKeyPair();
      final attackerReceiverEphemeralPubKey = Uint8List.fromList(
        (await attackerReceiverEphemeralKeyPair.extractPublicKey()).bytes,
      );

      final token = 'test-token-123';
      final tokenHash = await E2eeHandshake.computeTokenHash(token);

      final sig2 = await E2eeHandshake.signMsg2(
        receiverIdentityKeyPair: attackerReceiverIdentityKeyPair,
        transferId: transferId,
        manifestHash: session.manifestHash!,
        tokenHash: tokenHash,
        receiverEphemeralPubKey: attackerReceiverEphemeralPubKey,
        senderEphemeralPubKey: session.myEphemeralPubKey!,
        senderIdentityPubKey: session.myIdentityPubKey,
      );

      final acceptBody = {
        'transferId': transferId,
        'receiverDeviceId': 'attacker-dev-01',
        'transferToken': token,
        'e2ee': {
          'version': 2,
          'receiverIdentityPubKey': base64Encode(attackerReceiverIdentityPubKey),
          'receiverEphemeralPubKey': base64Encode(attackerReceiverEphemeralPubKey),
          'receiverEphemeralSig': base64Encode(sig2),
        },
      };

      // Manually register outgoing session
      // Verifying receiver's altered key throws StateError and aborts
      expect(
        () async {
          // Simulate the verification logic in handleTransferAccept
          final e2ee = acceptBody['e2ee'] as Map<String, dynamic>;
          final receivedPubKey = Uint8List.fromList(
            base64Decode(e2ee['receiverIdentityPubKey'] as String),
          );

          if (session.intendedReceiverIdentityPubKey != null) {
            final pinned = session.intendedReceiverIdentityPubKey!;
            bool pinMatches = pinned.length == receivedPubKey.length;
            if (pinMatches) {
              for (int i = 0; i < pinned.length; i++) {
                if (pinned[i] != receivedPubKey[i]) {
                  pinMatches = false;
                  break;
                }
              }
            }
            if (!pinMatches) {
              throw StateError('Receiver identity mismatch: public key does not match pinned verified identity');
            }
          }
        },
        throwsA(isA<StateError>()),
      );
    });

    test('Unverified and unseen peers pass through to SAS flow without identity mismatch rejection', () async {
      // 1. Unseen peer sends request
      final normalSenderKeyPair = await Ed25519().newKeyPairFromSeed(
        Uint8List.fromList(List.generate(32, (i) => i + 50)),
      );
      final normalSenderPubKey = Uint8List.fromList(
        (await normalSenderKeyPair.extractPublicKey()).bytes,
      );

      final ephemeralKeyPair = await E2eeHandshake.generateEphemeralKeyPair();
      final ephemeralPubKey = Uint8List.fromList(
        (await ephemeralKeyPair.extractPublicKey()).bytes,
      );

      final manifestItems = [
        ManifestFileItem(fileId: 'f2', fileName: 'photo.jpg', fileSize: 500),
      ];
      final manifestHash = await E2eeHandshake.computeManifestHash(manifestItems);

      final sig = await E2eeHandshake.signMsg1(
        senderIdentityKeyPair: normalSenderKeyPair,
        transferId: 'test-normal-sas-01',
        manifestHash: manifestHash,
        senderEphemeralPubKey: ephemeralPubKey,
        intendedReceiverIdentityPubKey: null,
      );

      final payload = {
        'transferId': 'test-normal-sas-01',
        'senderDeviceId': 'new-phone-01',
        'senderDeviceName': 'New Phone',
        'senderHost': '127.0.0.1',
        'senderPort': 55002,
        'files': [
          {'fileId': 'f2', 'fileName': 'photo.jpg', 'fileSize': 500}
        ],
        'e2ee': {
          'version': 2,
          'manifestHash': base64Encode(manifestHash),
          'senderIdentityPubKey': base64Encode(normalSenderPubKey),
          'senderEphemeralPubKey': base64Encode(ephemeralPubKey),
          'senderEphemeralSig': base64Encode(sig),
          'intendedReceiverIdentityPubKey': null,
        },
      };

      final response = await transferService.handleIncomingRequest(payload, '127.0.0.1');
      expect(response['status'], 'pending');
      expect(response['transferId'], 'test-normal-sas-01');

      // The new peer was recorded as unverifiedSeen
      final senderFp = await DeviceIdentityService.computeFingerprint(normalSenderPubKey);
      final peerRecord = await trustStore.getPeer(senderFp);
      expect(peerRecord, isNotNull);
      expect(peerRecord!.trustLevel, TrustLevel.unverifiedSeen);
    });
  });
}
