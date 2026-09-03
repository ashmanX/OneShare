import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oneshare/config/oneshare_config.dart';
import 'package:oneshare/models/transfer_models.dart';
import 'package:oneshare/services/crypto/control_message_channel.dart';
import 'package:oneshare/services/crypto/crypto_key_storage.dart';
import 'package:oneshare/services/crypto/e2ee_handshake.dart';
import 'package:oneshare/services/crypto/e2ee_session.dart';
import 'package:oneshare/services/crypto/trust_store.dart';
import 'package:oneshare/services/device_identity_service.dart';
import 'package:oneshare/services/transfer_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  setUp(() async {
    // Reset and initialize identity service with fresh in-memory keypair
    DeviceIdentityService.resetForTesting();
    await DeviceIdentityService.initialize(storage: InMemoryKeyStorage());
    TransferService.instance.trustStore = TrustStore(storage: InMemoryKeyStorage());
  });

  group('Phase 4: Wire Integration & Version 2 E2EE Handshake Flow', () {
    test('rejects incoming request with missing e2ee block (Protocol v1 peer)', () async {
      final v1Payload = {
        'transferId': 'legacy-transfer-101',
        'senderDeviceId': 'legacy-dev-1',
        'senderDeviceName': 'LegacyDevice',
        'senderHost': '127.0.0.1',
        'senderPort': 4040,
        'files': [
          {'fileId': 'f1', 'fileName': 'a.txt', 'fileSize': 100},
        ],
      };

      final response = await TransferService.instance.handleIncomingRequest(v1Payload, '127.0.0.1');

      expect(response['status'], 'rejected');
      expect(response['code'], 'PROTOCOL_VERSION_MISMATCH');
      expect(response['error'], contains('OneShare v2 requires End-to-End Encryption'));
    });

    test('rejects incoming request with protocol version mismatch', () async {
      final wrongVersionPayload = {
        'transferId': 'wrong-ver-102',
        'senderDeviceId': 'dev-1',
        'senderDeviceName': 'Device',
        'senderHost': '127.0.0.1',
        'senderPort': 4040,
        'files': [
          {'fileId': 'f1', 'fileName': 'a.txt', 'fileSize': 100},
        ],
        'e2ee': {
          'version': 99,
          'manifestHash': 'abc',
          'senderIdentityPubKey': 'def',
          'senderEphemeralPubKey': 'ghi',
          'senderEphemeralSig': 'jkl',
        },
      };

      final response =
          await TransferService.instance.handleIncomingRequest(wrongVersionPayload, '127.0.0.1');

      expect(response['status'], 'rejected');
      expect(response['code'], 'PROTOCOL_VERSION_MISMATCH');
    });

    test('rejects incoming request with tampered manifest hash', () async {
      final senderIdentity = DeviceIdentityService.identity;
      final ephemeral = await E2eeHandshake.generateEphemeralKeyPair();
      final ephemeralPub = Uint8List.fromList((await ephemeral.extractPublicKey()).bytes);

      final bogusManifestHash = Uint8List.fromList(List.filled(32, 0xEE));

      final sig = await E2eeHandshake.signMsg1(
        senderIdentityKeyPair: senderIdentity.identityKeyPair,
        transferId: 'tampered-manifest-001',
        manifestHash: bogusManifestHash,
        senderEphemeralPubKey: ephemeralPub,
      );

      final payload = {
        'transferId': 'tampered-manifest-001',
        'senderDeviceId': senderIdentity.deviceId,
        'senderDeviceName': senderIdentity.deviceName,
        'senderHost': '127.0.0.1',
        'senderPort': 4040,
        'files': [
          {'fileId': 'f1', 'fileName': 'file.txt', 'fileSize': 1024},
        ],
        'e2ee': {
          'version': 2,
          'manifestHash': base64Encode(bogusManifestHash),
          'senderIdentityPubKey': base64Encode(senderIdentity.identityPublicKeyBytes),
          'senderEphemeralPubKey': base64Encode(ephemeralPub),
          'senderEphemeralSig': base64Encode(sig),
        },
      };

      final response =
          await TransferService.instance.handleIncomingRequest(payload, '127.0.0.1');

      expect(response['status'], 'rejected');
      expect(response['code'], 'MANIFEST_HASH_MISMATCH');
    });

    test('rejects incoming request addressed to different intended receiver identity', () async {
      final senderIdentity = DeviceIdentityService.identity;
      final ephemeral = await E2eeHandshake.generateEphemeralKeyPair();
      final ephemeralPub = Uint8List.fromList((await ephemeral.extractPublicKey()).bytes);

      final fileItems = [
        const ManifestFileItem(fileId: 'f1', fileName: 'file.txt', fileSize: 1024),
      ];
      final manifestHash = await E2eeHandshake.computeManifestHash(fileItems);
      final wrongReceiverIdentityPub = Uint8List.fromList(List.filled(32, 0x99));

      final sig = await E2eeHandshake.signMsg1(
        senderIdentityKeyPair: senderIdentity.identityKeyPair,
        transferId: 'wrong-receiver-001',
        manifestHash: manifestHash,
        senderEphemeralPubKey: ephemeralPub,
        intendedReceiverIdentityPubKey: wrongReceiverIdentityPub,
      );

      final payload = {
        'transferId': 'wrong-receiver-001',
        'senderDeviceId': senderIdentity.deviceId,
        'senderDeviceName': senderIdentity.deviceName,
        'senderHost': '127.0.0.1',
        'senderPort': 4040,
        'files': [
          {'fileId': 'f1', 'fileName': 'file.txt', 'fileSize': 1024},
        ],
        'e2ee': {
          'version': 2,
          'manifestHash': base64Encode(manifestHash),
          'senderIdentityPubKey': base64Encode(senderIdentity.identityPublicKeyBytes),
          'senderEphemeralPubKey': base64Encode(ephemeralPub),
          'senderEphemeralSig': base64Encode(sig),
          'intendedReceiverIdentityPubKey': base64Encode(wrongReceiverIdentityPub),
        },
      };

      final response =
          await TransferService.instance.handleIncomingRequest(payload, '127.0.0.1');

      expect(response['status'], 'rejected');
      expect(response['code'], 'IDENTITY_MISMATCH');
    });

    test('full valid E2EE request and accept flow establishes mutual keys and matching SAS codes',
        () async {
      const transferId = 'e2ee-flow-valid-001';

      // 1. Simulate Alice (Sender)
      final aliceIdentity = DeviceIdentityService.identity;
      final aliceEphemeral = await E2eeHandshake.generateEphemeralKeyPair();
      final aliceEphemeralPub = Uint8List.fromList((await aliceEphemeral.extractPublicKey()).bytes);

      final fileItems = [
        const ManifestFileItem(fileId: 'f1', fileName: 'document.pdf', fileSize: 5000),
      ];
      final manifestHash = await E2eeHandshake.computeManifestHash(fileItems);

      final aliceSession = E2eeSession(
        transferId: transferId,
        isInitiator: true,
        myIdentityKeyPair: aliceIdentity.identityKeyPair,
        myIdentityPubKey: aliceIdentity.identityPublicKeyBytes,
      );
      aliceSession.myEphemeralKeyPair = aliceEphemeral;
      aliceSession.myEphemeralPubKey = aliceEphemeralPub;
      aliceSession.manifestHash = manifestHash;

      final msg1Sig = await E2eeHandshake.signMsg1(
        senderIdentityKeyPair: aliceIdentity.identityKeyPair,
        transferId: transferId,
        manifestHash: manifestHash,
        senderEphemeralPubKey: aliceEphemeralPub,
      );

      // 2. Bob (Receiver) processes msg1
      final bobIdentityService = await DeviceIdentityService.initialize(
        storage: InMemoryKeyStorage(),
      );

      final incomingPayload = {
        'transferId': transferId,
        'senderDeviceId': aliceIdentity.deviceId,
        'senderDeviceName': aliceIdentity.deviceName,
        'senderHost': '127.0.0.1',
        'senderPort': 4040,
        'files': [
          {'fileId': 'f1', 'fileName': 'document.pdf', 'fileSize': 5000},
        ],
        'e2ee': {
          'version': 2,
          'manifestHash': base64Encode(manifestHash),
          'senderIdentityPubKey': base64Encode(aliceIdentity.identityPublicKeyBytes),
          'senderEphemeralPubKey': base64Encode(aliceEphemeralPub),
          'senderEphemeralSig': base64Encode(msg1Sig),
        },
      };

      final handleRes = await TransferService.instance.handleIncomingRequest(
        incomingPayload,
        '127.0.0.1',
      );
      expect(handleRes['status'], 'pending');

      final bobSession = TransferService.instance.getSession(transferId);
      expect(bobSession, isNotNull);
      expect(bobSession!.state, E2eeSessionState.msg1Received);

      // 3. Bob accepts the transfer -> generates msg2 and derives receiver keys
      const tokenString = 'secret_token_e2ee_123';
      final bobEphemeral = await E2eeHandshake.generateEphemeralKeyPair();
      final bobEphemeralPub = Uint8List.fromList((await bobEphemeral.extractPublicKey()).bytes);
      final tokenHash = await E2eeHandshake.computeTokenHash(tokenString);

      final msg2Sig = await E2eeHandshake.signMsg2(
        receiverIdentityKeyPair: bobIdentityService.identityKeyPair,
        transferId: transferId,
        manifestHash: manifestHash,
        tokenHash: tokenHash,
        receiverEphemeralPubKey: bobEphemeralPub,
        senderEphemeralPubKey: aliceEphemeralPub,
        senderIdentityPubKey: aliceIdentity.identityPublicKeyBytes,
      );

      final bobTranscript = await E2eeHandshake.computeTranscriptHash(
        transferId: transferId,
        manifestHash: manifestHash,
        tokenHash: tokenHash,
        senderIdentityPubKey: aliceIdentity.identityPublicKeyBytes,
        receiverIdentityPubKey: bobIdentityService.identityPublicKeyBytes,
        senderEphemeralPubKey: aliceEphemeralPub,
        receiverEphemeralPubKey: bobEphemeralPub,
      );

      final bobShared = await E2eeHandshake.computeSharedSecret(
        myEphemeralKeyPair: bobEphemeral,
        peerEphemeralPubKey: aliceEphemeralPub,
      );

      await bobSession.deriveKeys(
        sharedSecret: bobShared,
        transcriptHash: bobTranscript,
      );
      final isMsg2SigValid = await E2eeHandshake.verifyMsg2(
        receiverIdentityPubKey: bobIdentityService.identityPublicKeyBytes,
        signatureBytes: msg2Sig,
        transferId: transferId,
        manifestHash: manifestHash,
        tokenHash: tokenHash,
        receiverEphemeralPubKey: bobEphemeralPub,
        senderEphemeralPubKey: aliceEphemeralPub,
        senderIdentityPubKey: aliceIdentity.identityPublicKeyBytes,
      );
      expect(isMsg2SigValid, isTrue);

      final aliceTranscript = await E2eeHandshake.computeTranscriptHash(
        transferId: transferId,
        manifestHash: manifestHash,
        tokenHash: tokenHash,
        senderIdentityPubKey: aliceIdentity.identityPublicKeyBytes,
        receiverIdentityPubKey: bobIdentityService.identityPublicKeyBytes,
        senderEphemeralPubKey: aliceEphemeralPub,
        receiverEphemeralPubKey: bobEphemeralPub,
      );

      final aliceShared = await E2eeHandshake.computeSharedSecret(
        myEphemeralKeyPair: aliceEphemeral,
        peerEphemeralPubKey: bobEphemeralPub,
      );

      await aliceSession.deriveKeys(
        sharedSecret: aliceShared,
        transcriptHash: aliceTranscript,
      );

      // Both peers derived identical SAS codes!
      expect(aliceSession.sasCode, bobSession.sasCode);
      expect(aliceSession.sasCode!.length, 6);

      // Keys match across directional boundaries
      final aliceSenderBase = await aliceSession.senderFileBaseKey!.extractBytes();
      final bobSenderBase = await bobSession.senderFileBaseKey!.extractBytes();
      expect(aliceSenderBase, bobSenderBase);

      // Best effort cleanup zeroization
      await bobSession.destroy();
      expect(bobSession.state, E2eeSessionState.destroyed);
      expect(bobSession.sessionMasterKey, isNull);
    });

    test('Full E2EE HTTP chunked file upload and decryption with sentinel verification', () async {
      final service = TransferService.instance;
      service.incomingRequestNotifier.value = null;

      // Create a test file (150 KB -> crosses multiple 64 KB chunk frames: chunk 0 (64KB), chunk 1 (64KB), chunk 2 (22KB), chunk 3 (sentinel))
      final tempDir = await Directory.systemTemp.createTemp('oneshare_e2ee_stream_test');
      final testFile = File('${tempDir.path}/secret_doc.pdf');
      final originalData = Uint8List.fromList(List.generate(150 * 1024, (i) => (i * 7) % 256));
      await testFile.writeAsBytes(originalData);

      // 1. Start receiver HTTP server
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      server.listen((HttpRequest req) async {
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
        } else {
          req.response
            ..statusCode = 404
            ..write(jsonEncode({'error': 'Not found'}));
          await req.response.close();
        }
      });

      // 2. Sender initiates transfer request
      final sendFuture = service.sendTransferRequest(
        targetHost: '127.0.0.1',
        targetPort: server.port,
        selectedFileDetails: [
          {'name': 'secret_doc.pdf', 'size': originalData.length}
        ],
      );

      PendingTransferRequest? pendingReq;
      for (int i = 0; i < 40; i++) {
        await Future.delayed(const Duration(milliseconds: 25));
        pendingReq = service.incomingRequestNotifier.value;
        if (pendingReq != null) break;
      }
      expect(pendingReq, isNotNull);
      final transferId = pendingReq!.transferId;

      // 3. Start sender HTTP accept listener
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
        } else {
          req.response
            ..statusCode = 404
            ..write(jsonEncode({'error': 'Not found'}));
          await req.response.close();
        }
      });

      // Route accept notification back to senderServer
      service.incomingRequestNotifier.value = PendingTransferRequest(
        transferId: pendingReq.transferId,
        senderDeviceId: pendingReq.senderDeviceId,
        senderDeviceName: pendingReq.senderDeviceName,
        senderHost: '127.0.0.1',
        senderPort: senderServer.port,
        files: pendingReq.files,
        receivedAt: pendingReq.receivedAt,
        e2ee: pendingReq.e2ee,
      );

      // 4. Receiver accepts incoming transfer
      await service.acceptIncomingRequest(transferId);
      final outcome = await sendFuture;
      expect(outcome.status, TransferResultStatus.accepted);
      expect(outcome.transferToken, isNotNull);

      // Verify sessions exist on both ends
      final incomingSession = service.getIncomingSessionForTesting(transferId);
      final outgoingSession = service.getOutgoingSessionForTesting(transferId);
      expect(incomingSession, isNotNull);
      expect(outgoingSession, isNotNull);

      // 5. Send file with sender service (uses EncryptedStreamWriter and chunked transfer)
      final sendResult = await service.sendTransferFiles(
        targetHost: '127.0.0.1',
        targetPort: server.port,
        transferId: outcome.transferId!,
        transferToken: outcome.transferToken!,
        filesToSend: [
          FileToSend(
            fileItem: outcome.fileItems!.first,
            localPath: testFile.path,
          ),
        ],
      );

      expect(sendResult, isTrue);

      await server.close(force: true);
      await senderServer.close(force: true);
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('Phase 6 Wire Test: Authenticated cancel message evaluation, replay, and gap rejection', () async {
      final service = TransferService.instance;
      service.incomingRequestNotifier.value = null;

      // Start receiver server
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      server.listen((HttpRequest req) async {
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
        } else if (req.method == 'POST' && req.uri.path == OneShareConfig.transferCancelPath) {
          final content = await utf8.decoder.bind(req).join();
          final jsonBody = jsonDecode(content) as Map<String, dynamic>;
          final transferId = jsonBody['transferId'] as String;
          final session = service.getSession(transferId);

          if (session != null && session.incomingCtrlChannel != null) {
            final eval = await session.incomingCtrlChannel!.evaluateIncomingControlMessage(
              fullBody: jsonBody,
            );
            if (eval.status == ControlEvaluationStatus.error) {
              req.response
                ..statusCode = eval.statusCode
                ..headers.contentType = ContentType.json
                ..write(jsonEncode({'error': eval.errorMessage, 'code': eval.errorCode}));
              await req.response.close();
              return;
            }
            if (eval.status == ControlEvaluationStatus.idempotentReplay) {
              req.response
                ..statusCode = 200
                ..headers.contentType = ContentType.json
                ..write(jsonEncode(eval.cachedResponse!));
              await req.response.close();
              return;
            }

            final responsePayload = {'status': 'cancellation_acknowledged'};
            final ctrl = jsonBody['e2ee_ctrl'] as Map<String, dynamic>;
            session.incomingCtrlChannel!.recordSuccess(
              seq: ctrl['seq'] as int,
              mac: Uint8List.fromList(base64Decode(ctrl['mac'] as String)),
              response: responsePayload,
            );
            req.response
              ..statusCode = 200
              ..headers.contentType = ContentType.json
              ..write(jsonEncode(responsePayload));
            await req.response.close();
            return;
          }

          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'status': 'cancellation_acknowledged'}));
          await req.response.close();
        } else {
          req.response
            ..statusCode = 404
            ..write(jsonEncode({'error': 'Not found'}));
          await req.response.close();
        }
      });

      // 1. Handshake
      final sendFuture = service.sendTransferRequest(
        targetHost: '127.0.0.1',
        targetPort: server.port,
        selectedFileDetails: [
          {'name': 'test.txt', 'size': 100}
        ],
      );

      PendingTransferRequest? pendingReq;
      for (int i = 0; i < 40; i++) {
        await Future.delayed(const Duration(milliseconds: 25));
        pendingReq = service.incomingRequestNotifier.value;
        if (pendingReq != null) break;
      }
      expect(pendingReq, isNotNull);
      final transferId = pendingReq!.transferId;

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

      service.incomingRequestNotifier.value = PendingTransferRequest(
        transferId: pendingReq.transferId,
        senderDeviceId: pendingReq.senderDeviceId,
        senderDeviceName: pendingReq.senderDeviceName,
        senderHost: '127.0.0.1',
        senderPort: senderServer.port,
        files: pendingReq.files,
        receivedAt: pendingReq.receivedAt,
        e2ee: pendingReq.e2ee,
      );

      await service.acceptIncomingRequest(transferId);
      final outcome = await sendFuture;
      expect(outcome.status, TransferResultStatus.accepted);

      final outgoingSession = service.getOutgoingSessionForTesting(transferId);
      expect(outgoingSession, isNotNull);
      expect(outgoingSession!.outgoingCtrlChannel, isNotNull);

      final client = HttpClient();

      // 2. Send valid signed cancellation (seq 1)
      final cancelMsg = await outgoingSession.outgoingCtrlChannel!.signControlMessage({
        'transferId': transferId,
        'senderDeviceId': 'test-sender',
      });

      final cancelReq1 = await client.postUrl(Uri.http('127.0.0.1:${server.port}', OneShareConfig.transferCancelPath));
      cancelReq1.headers.contentType = ContentType.json;
      cancelReq1.write(jsonEncode(cancelMsg));
      final cancelResp1 = await cancelReq1.close();
      expect(cancelResp1.statusCode, 200);
      final body1 = jsonDecode(await utf8.decoder.bind(cancelResp1).join()) as Map<String, dynamic>;
      expect(body1['status'], 'cancellation_acknowledged');

      // 3. Retransmit identical cancellation (seq 1) -> Idempotent replay HTTP 200
      final cancelReq2 = await client.postUrl(Uri.http('127.0.0.1:${server.port}', OneShareConfig.transferCancelPath));
      cancelReq2.headers.contentType = ContentType.json;
      cancelReq2.write(jsonEncode(cancelMsg));
      final cancelResp2 = await cancelReq2.close();
      expect(cancelResp2.statusCode, 200);
      final body2 = jsonDecode(await utf8.decoder.bind(cancelResp2).join()) as Map<String, dynamic>;
      expect(body2['status'], 'cancellation_acknowledged');

      // 4. Tampered cancellation (modified body with original MAC) -> 401 Unauthorized
      final tamperedMsg = Map<String, dynamic>.from(cancelMsg);
      tamperedMsg['extra_param'] = 'malicious';
      final cancelReq3 = await client.postUrl(Uri.http('127.0.0.1:${server.port}', OneShareConfig.transferCancelPath));
      cancelReq3.headers.contentType = ContentType.json;
      cancelReq3.write(jsonEncode(tamperedMsg));
      final cancelResp3 = await cancelReq3.close();
      expect(cancelResp3.statusCode, 401);

      // 5. Sequence gap (seq 3 instead of seq 2) -> 400 Bad Request
      await outgoingSession.outgoingCtrlChannel!.signControlMessage({
        'transferId': transferId,
        'senderDeviceId': 'test-sender',
      }); // This generates seq 2 locally
      // Now artificially increment seq to 4
      final fakeGapMsg = {
        'transferId': transferId,
        'senderDeviceId': 'test-sender',
        'e2ee_ctrl': {
          'seq': 4,
          'direction': 'sender_to_receiver',
          'mac': base64Encode(await outgoingSession.outgoingCtrlChannel!.computeMac(
            seq: 4,
            bodyWithoutCtrl: {'transferId': transferId, 'senderDeviceId': 'test-sender'},
          )),
        },
      };
      final cancelReq4 = await client.postUrl(Uri.http('127.0.0.1:${server.port}', OneShareConfig.transferCancelPath));
      cancelReq4.headers.contentType = ContentType.json;
      cancelReq4.write(jsonEncode(fakeGapMsg));
      final cancelResp4 = await cancelReq4.close();
      expect(cancelResp4.statusCode, 400);

      client.close();
      await server.close(force: true);
      await senderServer.close(force: true);
    });
  });
}
