import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oneshare/config/oneshare_config.dart';
import 'package:oneshare/models/transfer_models.dart';
import 'package:oneshare/services/crypto/crypto_key_storage.dart';
import 'package:oneshare/services/crypto/e2ee_handshake.dart';
import 'package:oneshare/services/crypto/e2ee_session.dart';
import 'package:oneshare/services/crypto/encrypted_stream.dart';
import 'package:oneshare/services/crypto/trust_store.dart';
import 'package:oneshare/services/device_identity_service.dart';
import 'package:oneshare/services/transfer_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  setUp(() async {
    DeviceIdentityService.resetForTesting();
    await DeviceIdentityService.initialize(storage: InMemoryKeyStorage());
    TransferService.instance.trustStore = TrustStore(storage: InMemoryKeyStorage());
  });

  group('Phase 8: End-to-End E2EE Integration & Adversary Security Suite', () {
    test('E2E Full Loopback: Request -> Accept -> Multi-File Encrypted Streaming -> Verified SAS Match', () async {
      final service = TransferService.instance;
      service.incomingRequestNotifier.value = null;

      final tempDir = await Directory.systemTemp.createTemp('oneshare_p8_e2e_');
      final file1 = File('${tempDir.path}/doc1.txt');
      final file2 = File('${tempDir.path}/doc2.bin');
      await file1.writeAsString('Hello secure world file 1 payload!');
      await file2.writeAsBytes(List<int>.generate(80000, (i) => (i * 7) % 256));

      // Setup receiver HTTP server
      final receiverServer = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      receiverServer.listen((HttpRequest req) async {
        if (req.method == 'POST' && req.uri.path == OneShareConfig.transferRequestPath) {
          final content = await utf8.decoder.bind(req).join();
          final json = jsonDecode(content) as Map<String, dynamic>;
          final res = await service.handleIncomingRequest(json, '127.0.0.1');
          final statusCode = res['status'] == 'rejected' ? 409 : 200;
          req.response
            ..statusCode = statusCode
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(res));
          await req.response.close();
        } else if (req.method == 'POST' && req.uri.path == OneShareConfig.transferFilePath) {
          await service.handleIncomingFileUpload(req);
        }
      });

      // Setup sender HTTP callback server
      final senderServer = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      senderServer.listen((HttpRequest req) async {
        if (req.uri.path == OneShareConfig.transferAcceptPath) {
          final content = await utf8.decoder.bind(req).join();
          await service.handleAcceptResponse(jsonDecode(content) as Map<String, dynamic>);
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'status': 'accepted_acknowledged'}));
          await req.response.close();
        }
      });

      // 1. Sender initiates transfer request
      final sendFuture = service.sendTransferRequest(
        targetHost: '127.0.0.1',
        targetPort: receiverServer.port,
        senderPort: senderServer.port,
        selectedFileDetails: [
          {'name': 'doc1.txt', 'size': await file1.length()},
          {'name': 'doc2.bin', 'size': await file2.length()},
        ],
      );

      // Wait for receiver notification
      PendingTransferRequest? pendingReq;
      for (int i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        pendingReq = service.incomingRequestNotifier.value;
        if (pendingReq != null) break;
      }
      expect(pendingReq, isNotNull);
      expect(pendingReq!.files.length, 2);

      // 2. Receiver accepts transfer request
      await service.acceptIncomingRequest(pendingReq.transferId);
      final outcome = await sendFuture;

      expect(outcome.status, TransferResultStatus.accepted);
      expect(outcome.transferToken, isNotNull);

      // Verify sessions exist and derive exact matching SAS codes
      final incomingSession = service.getIncomingSessionForTesting(pendingReq.transferId);
      final outgoingSession = service.getOutgoingSessionForTesting(pendingReq.transferId);
      expect(incomingSession, isNotNull);
      expect(outgoingSession, isNotNull);
      expect(incomingSession!.sasCode, isNotNull);
      expect(outgoingSession!.sasCode, isNotNull);
      expect(incomingSession.sasCode, equals(outgoingSession.sasCode));

      // 3. Sender streams both encrypted files
      final sendResult = await service.sendTransferFiles(
        targetHost: '127.0.0.1',
        targetPort: receiverServer.port,
        transferId: outcome.transferId!,
        transferToken: outcome.transferToken!,
        filesToSend: [
          FileToSend(fileItem: outcome.fileItems![0], localPath: file1.path),
          FileToSend(fileItem: outcome.fileItems![1], localPath: file2.path),
        ],
      );

      expect(sendResult, isTrue);

      await receiverServer.close(force: true);
      await senderServer.close(force: true);
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('Adversary MITM: Ephemeral key substitution in msg1 produces signature failure', () async {
      final senderIdentity = DeviceIdentityService.identity;
      final realEphemeral = await E2eeHandshake.generateEphemeralKeyPair();
      final realEphemeralPub = Uint8List.fromList((await realEphemeral.extractPublicKey()).bytes);

      final files = [
        const ManifestFileItem(fileId: 'f1', fileName: 'test.bin', fileSize: 1024),
      ];
      final manifestHash = await E2eeHandshake.computeManifestHash(files);

      const transferId = 'mitm-eph-001';
      final sig = await E2eeHandshake.signMsg1(
        senderIdentityKeyPair: senderIdentity.identityKeyPair,
        transferId: transferId,
        manifestHash: manifestHash,
        senderEphemeralPubKey: realEphemeralPub,
      );

      // MITM attacker substitutes a different ephemeral public key
      final fakeEphemeral = await E2eeHandshake.generateEphemeralKeyPair();
      final fakeEphemeralPub = Uint8List.fromList((await fakeEphemeral.extractPublicKey()).bytes);

      final tamperedPayload = {
        'transferId': transferId,
        'senderDeviceId': 'dev-sender',
        'senderDeviceName': 'Sender',
        'senderHost': '127.0.0.1',
        'senderPort': 5000,
        'files': [
          {'fileId': 'f1', 'fileName': 'test.bin', 'fileSize': 1024},
        ],
        'e2ee': {
          'version': 2,
          'manifestHash': base64Encode(manifestHash),
          'senderIdentityPubKey': base64Encode(senderIdentity.identityPublicKeyBytes),
          'senderEphemeralPubKey': base64Encode(fakeEphemeralPub), // Tampered!
          'senderEphemeralSig': base64Encode(sig),
        },
      };

      final response = await TransferService.instance.handleIncomingRequest(tamperedPayload, '127.0.0.1');
      expect(response['status'], 'rejected');
      expect(response['code'], 'INVALID_SIGNATURE');
    });

    test('Adversary MITM: Identity key substitution in msg1 produces signature failure', () async {
      final senderIdentity = DeviceIdentityService.identity;
      final ephemeral = await E2eeHandshake.generateEphemeralKeyPair();
      final ephemeralPub = Uint8List.fromList((await ephemeral.extractPublicKey()).bytes);

      final files = [
        const ManifestFileItem(fileId: 'f1', fileName: 'test.bin', fileSize: 1024),
      ];
      final manifestHash = await E2eeHandshake.computeManifestHash(files);

      const transferId = 'mitm-ident-002';
      final sig = await E2eeHandshake.signMsg1(
        senderIdentityKeyPair: senderIdentity.identityKeyPair,
        transferId: transferId,
        manifestHash: manifestHash,
        senderEphemeralPubKey: ephemeralPub,
      );

      // MITM attacker substitutes an arbitrary identity public key
      final fakeIdentityKeyPair = await Ed25519().newKeyPair();
      final fakeIdentityPub = Uint8List.fromList((await fakeIdentityKeyPair.extractPublicKey()).bytes);

      final tamperedPayload = {
        'transferId': transferId,
        'senderDeviceId': 'dev-sender',
        'senderDeviceName': 'Sender',
        'senderHost': '127.0.0.1',
        'senderPort': 5000,
        'files': [
          {'fileId': 'f1', 'fileName': 'test.bin', 'fileSize': 1024},
        ],
        'e2ee': {
          'version': 2,
          'manifestHash': base64Encode(manifestHash),
          'senderIdentityPubKey': base64Encode(fakeIdentityPub), // Tampered!
          'senderEphemeralPubKey': base64Encode(ephemeralPub),
          'senderEphemeralSig': base64Encode(sig),
        },
      };

      final response = await TransferService.instance.handleIncomingRequest(tamperedPayload, '127.0.0.1');
      expect(response['status'], 'rejected');
      expect(response['code'], 'INVALID_SIGNATURE');
    });

    test('Adversary MITM: Independent key generation produces diverging SAS codes', () async {
      final aliceIdentity = await Ed25519().newKeyPair();
      final aliceIdentityPub = Uint8List.fromList((await aliceIdentity.extractPublicKey()).bytes);
      final aliceEphemeral = await X25519().newKeyPair();
      final aliceEphemeralPub = Uint8List.fromList((await aliceEphemeral.extractPublicKey()).bytes);

      final bobIdentity = await Ed25519().newKeyPair();
      final bobIdentityPub = Uint8List.fromList((await bobIdentity.extractPublicKey()).bytes);
      final bobEphemeral = await X25519().newKeyPair();
      final bobEphemeralPub = Uint8List.fromList((await bobEphemeral.extractPublicKey()).bytes);

      // MITM attacker Eve
      final eveIdentity = await Ed25519().newKeyPair();
      final eveIdentityPub = Uint8List.fromList((await eveIdentity.extractPublicKey()).bytes);
      final eveEphemeral = await X25519().newKeyPair();
      final eveEphemeralPub = Uint8List.fromList((await eveEphemeral.extractPublicKey()).bytes);

      final files = [const ManifestFileItem(fileId: 'f1', fileName: 'file.dat', fileSize: 100)];
      final manifestHash = await E2eeHandshake.computeManifestHash(files);
      final tokenHash = await E2eeHandshake.computeTokenHash('token-abc');
      const transferId = 'mitm-sas-003';

      // 1. Alice connects to Eve
      final aliceSession = E2eeSession(
        transferId: transferId,
        isInitiator: true,
        myIdentityKeyPair: aliceIdentity,
        myIdentityPubKey: aliceIdentityPub,
      );
      final aliceTranscript = await E2eeHandshake.computeTranscriptHash(
        transferId: transferId,
        manifestHash: manifestHash,
        tokenHash: tokenHash,
        senderIdentityPubKey: aliceIdentityPub,
        receiverIdentityPubKey: eveIdentityPub,
        senderEphemeralPubKey: aliceEphemeralPub,
        receiverEphemeralPubKey: eveEphemeralPub,
      );
      final aliceShared = await E2eeHandshake.computeSharedSecret(
        myEphemeralKeyPair: aliceEphemeral,
        peerEphemeralPubKey: eveEphemeralPub,
      );
      await aliceSession.deriveKeys(
        sharedSecret: aliceShared,
        transcriptHash: aliceTranscript,
      );

      // 2. Eve connects to Bob
      final bobSession = E2eeSession(
        transferId: transferId,
        isInitiator: false,
        myIdentityKeyPair: bobIdentity,
        myIdentityPubKey: bobIdentityPub,
      );
      final bobTranscript = await E2eeHandshake.computeTranscriptHash(
        transferId: transferId,
        manifestHash: manifestHash,
        tokenHash: tokenHash,
        senderIdentityPubKey: eveIdentityPub,
        receiverIdentityPubKey: bobIdentityPub,
        senderEphemeralPubKey: eveEphemeralPub,
        receiverEphemeralPubKey: bobEphemeralPub,
      );
      final bobShared = await E2eeHandshake.computeSharedSecret(
        myEphemeralKeyPair: bobEphemeral,
        peerEphemeralPubKey: eveEphemeralPub,
      );
      await bobSession.deriveKeys(
        sharedSecret: bobShared,
        transcriptHash: bobTranscript,
      );

      // Crucial security invariant: Alice and Bob MUST derive different SAS codes!
      expect(aliceSession.sasCode, isNotNull);
      expect(bobSession.sasCode, isNotNull);
      expect(aliceSession.sasCode, isNot(equals(bobSession.sasCode)));
    });

    test('Ciphertext Bit-Flip Attack: EncryptedStreamReader detects Poly1305 MAC failure', () async {
      final algorithm = Chacha20.poly1305Aead();
      final secretKey = await algorithm.newSecretKey();
      const transferId = 'bit-flip-stream-001';
      const fileId = 'flip-fid';

      final writer = EncryptedStreamWriter(
        fileKey: secretKey,
        transferId: transferId,
        fileId: fileId,
      );
      final reader = EncryptedStreamReader(
        fileKey: secretKey,
        transferId: transferId,
        fileId: fileId,
      );

      final plaintext = utf8.encode('Top secret business report');
      final chunkFrame = await writer.encryptChunk(plaintext);
      final sentinelFrame = await writer.writeSentinel();

      // Corrupt a byte in the encrypted chunk
      final tamperedChunk = Uint8List.fromList(chunkFrame);
      tamperedChunk[10] ^= 0x01; // flip bit

      final stream = Stream<List<int>>.fromIterable([tamperedChunk, sentinelFrame]);

      expect(
        () => reader.processStream(stream).toList(),
        throwsA(isA<EncryptedStreamException>().having(
          (e) => e.message,
          'message',
          contains('AEAD authentication failed'),
        )),
      );
    });

    test('Truncated Stream Attack: EncryptedStreamReader detects missing EOF sentinel', () async {
      final algorithm = Chacha20.poly1305Aead();
      final secretKey = await algorithm.newSecretKey();
      const transferId = 'truncated-stream-002';
      const fileId = 'trunc-fid';

      final writer = EncryptedStreamWriter(
        fileKey: secretKey,
        transferId: transferId,
        fileId: fileId,
      );
      final reader = EncryptedStreamReader(
        fileKey: secretKey,
        transferId: transferId,
        fileId: fileId,
      );

      final plaintext = utf8.encode('Incomplete data stream');
      final chunkFrame = await writer.encryptChunk(plaintext);

      // Omit sentinel
      final stream = Stream<List<int>>.fromIterable([chunkFrame]);

      expect(
        () => reader.processStream(stream).toList(),
        throwsA(isA<EncryptedStreamException>().having(
          (e) => e.message,
          'message',
          contains('Stream truncated: stream ended before sentinel chunk was verified'),
        )),
      );
    });

    test('Concurrent Send & Receive: Independent simultaneous sessions operate without collision', () async {
      final sessionA = E2eeSession(
        transferId: 'concurrent-transfer-A',
        isInitiator: true,
        myIdentityKeyPair: DeviceIdentityService.identity.identityKeyPair,
        myIdentityPubKey: DeviceIdentityService.identity.identityPublicKeyBytes,
      );
      final sessionB = E2eeSession(
        transferId: 'concurrent-transfer-B',
        isInitiator: false,
        myIdentityKeyPair: DeviceIdentityService.identity.identityKeyPair,
        myIdentityPubKey: DeviceIdentityService.identity.identityPublicKeyBytes,
      );

      final ephA = await X25519().newKeyPair();
      final ephB = await X25519().newKeyPair();

      final ephPeerA = await X25519().newKeyPair();
      final ephPeerB = await X25519().newKeyPair();
      final ephPeerAPub = Uint8List.fromList((await ephPeerA.extractPublicKey()).bytes);
      final ephPeerBPub = Uint8List.fromList((await ephPeerB.extractPublicKey()).bytes);

      final sharedA = await E2eeHandshake.computeSharedSecret(
        myEphemeralKeyPair: ephA,
        peerEphemeralPubKey: ephPeerAPub,
      );
      final sharedB = await E2eeHandshake.computeSharedSecret(
        myEphemeralKeyPair: ephB,
        peerEphemeralPubKey: ephPeerBPub,
      );

      final transcriptA = Uint8List(32)..fillRange(0, 32, 0xAA);
      final transcriptB = Uint8List(32)..fillRange(0, 32, 0xBB);

      sessionA.myEphemeralKeyPair = ephA;
      sessionA.myEphemeralPubKey = Uint8List.fromList((await ephA.extractPublicKey()).bytes);
      sessionA.peerEphemeralPubKey = ephPeerAPub;
      sessionA.peerIdentityPubKey = Uint8List(32);
      sessionA.manifestHash = Uint8List(32);

      sessionB.myEphemeralKeyPair = ephB;
      sessionB.myEphemeralPubKey = Uint8List.fromList((await ephB.extractPublicKey()).bytes);
      sessionB.peerEphemeralPubKey = ephPeerBPub;
      sessionB.peerIdentityPubKey = Uint8List(32);
      sessionB.manifestHash = Uint8List(32);

      await sessionA.deriveKeys(sharedSecret: sharedA, transcriptHash: transcriptA);
      await sessionB.deriveKeys(sharedSecret: sharedB, transcriptHash: transcriptB);

      expect(sessionA.sasCode, isNotNull);
      expect(sessionB.sasCode, isNotNull);
      expect(sessionA.sasCode, isNot(equals(sessionB.sasCode)));

      final keyA = await (await sessionA.deriveFileKeyForId('file-1')).extractBytes();
      final keyB = await (await sessionB.deriveFileKeyForId('file-1')).extractBytes();
      expect(keyA, isNot(equals(keyB)));

      await sessionA.destroy();
      await sessionB.destroy();
    });
  });
}
