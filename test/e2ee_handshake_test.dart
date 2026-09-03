import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oneshare/services/crypto/e2ee_handshake.dart';
import 'package:oneshare/services/crypto/e2ee_session.dart';
import 'package:oneshare/services/crypto/sas_verification.dart';

void main() {
  final ed25519 = Ed25519();

  late SimpleKeyPair aliceIdentityKey;
  late Uint8List aliceIdentityPub;
  late SimpleKeyPair bobIdentityKey;
  late Uint8List bobIdentityPub;

  setUp(() async {
    aliceIdentityKey = await ed25519.newKeyPair();
    aliceIdentityPub = Uint8List.fromList((await aliceIdentityKey.extractPublicKey()).bytes);

    bobIdentityKey = await ed25519.newKeyPair();
    bobIdentityPub = Uint8List.fromList((await bobIdentityKey.extractPublicKey()).bytes);
  });

  group('E2eeHandshake & Manifest Integrity', () {
    test('canonical manifestHash is invariant to file declaration ordering', () async {
      final f1 = ManifestFileItem(fileId: 'file-b', fileName: 'doc.pdf', fileSize: 1024);
      final f2 = ManifestFileItem(fileId: 'file-a', fileName: 'pic.png', fileSize: 2048);

      final hashOrder1 = await E2eeHandshake.computeManifestHash([f1, f2]);
      final hashOrder2 = await E2eeHandshake.computeManifestHash([f2, f1]);

      expect(hashOrder1, hashOrder2);
      expect(hashOrder1.length, 32);
    });

    test('manifestHash changes if any fileId, fileName, or fileSize changes', () async {
      final base = [
        const ManifestFileItem(fileId: 'f1', fileName: 'file.txt', fileSize: 100),
      ];
      final tamperedName = [
        const ManifestFileItem(fileId: 'f1', fileName: 'evil.txt', fileSize: 100),
      ];
      final tamperedSize = [
        const ManifestFileItem(fileId: 'f1', fileName: 'file.txt', fileSize: 999),
      ];
      final tamperedId = [
        const ManifestFileItem(fileId: 'f2', fileName: 'file.txt', fileSize: 100),
      ];

      final baseHash = await E2eeHandshake.computeManifestHash(base);
      expect(await E2eeHandshake.computeManifestHash(tamperedName), isNot(equals(baseHash)));
      expect(await E2eeHandshake.computeManifestHash(tamperedSize), isNot(equals(baseHash)));
      expect(await E2eeHandshake.computeManifestHash(tamperedId), isNot(equals(baseHash)));
    });

    test('msg1 signing and verification roundtrip with intended receiver binding', () async {
      const transferId = 'trans-1234';
      final manifestHash = Uint8List.fromList(List.filled(32, 0xAA));
      final aliceEphemeralKey = await E2eeHandshake.generateEphemeralKeyPair();
      final aliceEphemeralPub =
          Uint8List.fromList((await aliceEphemeralKey.extractPublicKey()).bytes);

      // Sign with Bob as intended receiver
      final sig = await E2eeHandshake.signMsg1(
        senderIdentityKeyPair: aliceIdentityKey,
        transferId: transferId,
        manifestHash: manifestHash,
        senderEphemeralPubKey: aliceEphemeralPub,
        intendedReceiverIdentityPubKey: bobIdentityPub,
      );

      // Verify valid signature
      final valid = await E2eeHandshake.verifyMsg1(
        senderIdentityPubKey: aliceIdentityPub,
        signatureBytes: sig,
        transferId: transferId,
        manifestHash: manifestHash,
        senderEphemeralPubKey: aliceEphemeralPub,
        intendedReceiverIdentityPubKey: bobIdentityPub,
      );
      expect(valid, isTrue);

      // Rejects tampered transferId
      expect(
        await E2eeHandshake.verifyMsg1(
          senderIdentityPubKey: aliceIdentityPub,
          signatureBytes: sig,
          transferId: 'trans-tampered',
          manifestHash: manifestHash,
          senderEphemeralPubKey: aliceEphemeralPub,
          intendedReceiverIdentityPubKey: bobIdentityPub,
        ),
        isFalse,
      );

      // Rejects tampered manifestHash
      expect(
        await E2eeHandshake.verifyMsg1(
          senderIdentityPubKey: aliceIdentityPub,
          signatureBytes: sig,
          transferId: transferId,
          manifestHash: Uint8List.fromList(List.filled(32, 0xBB)),
          senderEphemeralPubKey: aliceEphemeralPub,
          intendedReceiverIdentityPubKey: bobIdentityPub,
        ),
        isFalse,
      );

      // Rejects when relayed to a different receiver
      final charlieKey = await ed25519.newKeyPair();
      final charliePub = Uint8List.fromList((await charlieKey.extractPublicKey()).bytes);
      expect(
        await E2eeHandshake.verifyMsg1(
          senderIdentityPubKey: aliceIdentityPub,
          signatureBytes: sig,
          transferId: transferId,
          manifestHash: manifestHash,
          senderEphemeralPubKey: aliceEphemeralPub,
          intendedReceiverIdentityPubKey: charliePub,
        ),
        isFalse,
      );
    });

    test('msg2 signing and verification roundtrip', () async {
      const transferId = 'trans-1234';
      final manifestHash = Uint8List.fromList(List.filled(32, 0x11));
      const transferToken = 'tok_sec_sample123';
      final tokenHash = await E2eeHandshake.computeTokenHash(transferToken);

      final aliceEphemeralKey = await E2eeHandshake.generateEphemeralKeyPair();
      final aliceEphemeralPub =
          Uint8List.fromList((await aliceEphemeralKey.extractPublicKey()).bytes);

      final bobEphemeralKey = await E2eeHandshake.generateEphemeralKeyPair();
      final bobEphemeralPub =
          Uint8List.fromList((await bobEphemeralKey.extractPublicKey()).bytes);

      final sig2 = await E2eeHandshake.signMsg2(
        receiverIdentityKeyPair: bobIdentityKey,
        transferId: transferId,
        manifestHash: manifestHash,
        tokenHash: tokenHash,
        receiverEphemeralPubKey: bobEphemeralPub,
        senderEphemeralPubKey: aliceEphemeralPub,
        senderIdentityPubKey: aliceIdentityPub,
      );

      final valid = await E2eeHandshake.verifyMsg2(
        receiverIdentityPubKey: bobIdentityPub,
        signatureBytes: sig2,
        transferId: transferId,
        manifestHash: manifestHash,
        tokenHash: tokenHash,
        receiverEphemeralPubKey: bobEphemeralPub,
        senderEphemeralPubKey: aliceEphemeralPub,
        senderIdentityPubKey: aliceIdentityPub,
      );
      expect(valid, isTrue);

      // Rejects tampered tokenHash
      final wrongTokenHash = await E2eeHandshake.computeTokenHash('wrong_token');
      expect(
        await E2eeHandshake.verifyMsg2(
          receiverIdentityPubKey: bobIdentityPub,
          signatureBytes: sig2,
          transferId: transferId,
          manifestHash: manifestHash,
          tokenHash: wrongTokenHash,
          receiverEphemeralPubKey: bobEphemeralPub,
          senderEphemeralPubKey: aliceEphemeralPub,
          senderIdentityPubKey: aliceIdentityPub,
        ),
        isFalse,
      );
    });

    test('full mutual handshake derives identical keys and matching SAS codes on both peers',
        () async {
      const transferId = 'mutual-transfer-001';
      final manifestHash = Uint8List.fromList(List.filled(32, 0x42));
      const transferToken = 'tok_sec_mutual_test';
      final tokenHash = await E2eeHandshake.computeTokenHash(transferToken);

      // 1. Initiator (Alice) generates ephemeral key
      final aliceSession = E2eeSession(
        transferId: transferId,
        isInitiator: true,
        myIdentityKeyPair: aliceIdentityKey,
        myIdentityPubKey: aliceIdentityPub,
      );
      final aliceEphemeralKey = await E2eeHandshake.generateEphemeralKeyPair();
      final aliceEphemeralPub =
          Uint8List.fromList((await aliceEphemeralKey.extractPublicKey()).bytes);
      aliceSession.myEphemeralKeyPair = aliceEphemeralKey;
      aliceSession.myEphemeralPubKey = aliceEphemeralPub;

      // 2. Responder (Bob) generates ephemeral key
      final bobSession = E2eeSession(
        transferId: transferId,
        isInitiator: false,
        myIdentityKeyPair: bobIdentityKey,
        myIdentityPubKey: bobIdentityPub,
      );
      final bobEphemeralKey = await E2eeHandshake.generateEphemeralKeyPair();
      final bobEphemeralPub =
          Uint8List.fromList((await bobEphemeralKey.extractPublicKey()).bytes);
      bobSession.myEphemeralKeyPair = bobEphemeralKey;
      bobSession.myEphemeralPubKey = bobEphemeralPub;

      // 3. Both peers compute transcript hash
      final aliceTranscriptHash = await E2eeHandshake.computeTranscriptHash(
        transferId: transferId,
        manifestHash: manifestHash,
        tokenHash: tokenHash,
        senderIdentityPubKey: aliceIdentityPub,
        receiverIdentityPubKey: bobIdentityPub,
        senderEphemeralPubKey: aliceEphemeralPub,
        receiverEphemeralPubKey: bobEphemeralPub,
      );

      final bobTranscriptHash = await E2eeHandshake.computeTranscriptHash(
        transferId: transferId,
        manifestHash: manifestHash,
        tokenHash: tokenHash,
        senderIdentityPubKey: aliceIdentityPub,
        receiverIdentityPubKey: bobIdentityPub,
        senderEphemeralPubKey: aliceEphemeralPub,
        receiverEphemeralPubKey: bobEphemeralPub,
      );
      expect(aliceTranscriptHash, bobTranscriptHash);

      // 4. Compute X25519 shared secret
      final aliceShared = await E2eeHandshake.computeSharedSecret(
        myEphemeralKeyPair: aliceEphemeralKey,
        peerEphemeralPubKey: bobEphemeralPub,
      );
      final bobShared = await E2eeHandshake.computeSharedSecret(
        myEphemeralKeyPair: bobEphemeralKey,
        peerEphemeralPubKey: aliceEphemeralPub,
      );

      final aliceSecretBytes = await aliceShared.extractBytes();
      final bobSecretBytes = await bobShared.extractBytes();
      expect(aliceSecretBytes, bobSecretBytes);

      // 5. Derive session keys on both sides
      await aliceSession.deriveKeys(
        sharedSecret: aliceShared,
        transcriptHash: aliceTranscriptHash,
      );
      await bobSession.deriveKeys(
        sharedSecret: bobShared,
        transcriptHash: bobTranscriptHash,
      );

      // Master keys match
      expect(
        await aliceSession.sessionMasterKey!.extractBytes(),
        await bobSession.sessionMasterKey!.extractBytes(),
      );

      // Directional keys align
      expect(
        await aliceSession.senderFileBaseKey!.extractBytes(),
        await bobSession.senderFileBaseKey!.extractBytes(),
      );
      expect(
        await aliceSession.receiverFileBaseKey!.extractBytes(),
        await bobSession.receiverFileBaseKey!.extractBytes(),
      );
      expect(
        await aliceSession.senderCtrlKey!.extractBytes(),
        await bobSession.senderCtrlKey!.extractBytes(),
      );
      expect(
        await aliceSession.receiverCtrlKey!.extractBytes(),
        await bobSession.receiverCtrlKey!.extractBytes(),
      );

      // Base keys differ across directions (reflection attack resistance)
      expect(
        await aliceSession.senderFileBaseKey!.extractBytes(),
        isNot(equals(await aliceSession.receiverFileBaseKey!.extractBytes())),
      );

      // SAS codes match exactly on both sides
      expect(aliceSession.sasCode, isNotNull);
      expect(aliceSession.sasCode!.length, 6);
      expect(aliceSession.sasCode, bobSession.sasCode);

      // Formatted SAS code check
      expect(SasVerification.formatSasCode(aliceSession.sasCode!).length, 7);

      // 6. Per-file subkeys derived from fileId match
      const file1Id = 'file-id-abc-123';
      final aliceFile1Key = await aliceSession.deriveFileKeyForId(file1Id);
      final bobFile1Key = await bobSession.deriveIncomingFileKeyForId(file1Id);
      expect(
        await aliceFile1Key.extractBytes(),
        await bobFile1Key.extractBytes(),
      );

      // Different fileId derives distinct key
      const file2Id = 'file-id-xyz-999';
      final aliceFile2Key = await aliceSession.deriveFileKeyForId(file2Id);
      expect(
        await aliceFile1Key.extractBytes(),
        isNot(equals(await aliceFile2Key.extractBytes())),
      );

      // 7. Cleanup & Zeroization
      await aliceSession.destroy();
      expect(aliceSession.state, E2eeSessionState.destroyed);
      expect(aliceSession.sessionMasterKey, isNull);
    });
  });
}
