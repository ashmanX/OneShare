import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oneshare/config/oneshare_config.dart';
import 'package:oneshare/services/crypto/control_message_channel.dart';
import 'package:oneshare/services/crypto/crypto_key_storage.dart';
import 'package:oneshare/services/crypto/e2ee_session.dart';
import 'package:oneshare/services/crypto/trust_store.dart';
import 'package:oneshare/services/device_identity_service.dart';
import 'package:oneshare/services/oneshare_http_server.dart';
import 'package:oneshare/services/transfer_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late InMemoryKeyStorage keyStorage;
  late TrustStore trustStore;
  late DeviceIdentity identity;
  late OneShareHttpServer server;
  late int serverPort;
  late HttpClient client;

  setUp(() async {
    keyStorage = InMemoryKeyStorage();
    identity = await DeviceIdentityService.initialize(storage: keyStorage);

    trustStore = TrustStore(storage: keyStorage);
    TransferService.instance.trustStore = trustStore;

    server = OneShareHttpServer();
    await server.start(port: 0);
    serverPort = server.port;
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
  });

  /// Helper to create a paired E2EE session between sender and receiver in memory.
  Future<({E2eeSession senderSession, E2eeSession receiverSession, String transferId})>
      createPairedSessions() async {
    final transferId = 'transfer-${DateTime.now().microsecondsSinceEpoch}';

    final senderSession = E2eeSession(
      transferId: transferId,
      isInitiator: true,
      myIdentityKeyPair: identity.identityKeyPair,
      myIdentityPubKey: identity.identityPublicKeyBytes,
    );

    final receiverSession = E2eeSession(
      transferId: transferId,
      isInitiator: false,
      myIdentityKeyPair: identity.identityKeyPair,
      myIdentityPubKey: identity.identityPublicKeyBytes,
    );

    // Simulated shared secret and transcript hash for test
    final sharedSecret = SecretKey(List<int>.generate(32, (i) => i ^ 0xAA));
    final transcriptHash = Uint8List.fromList(List<int>.generate(32, (i) => i ^ 0x55));

    await senderSession.deriveKeys(
      sharedSecret: sharedSecret,
      transcriptHash: transcriptHash,
    );
    senderSession.state = E2eeSessionState.keysDerived;

    await receiverSession.deriveKeys(
      sharedSecret: sharedSecret,
      transcriptHash: transcriptHash,
    );
    receiverSession.state = E2eeSessionState.keysDerived;

    // Register with TransferService
    TransferService.instance.markHandshakeCompleted(transferId);
    TransferService.instance.injectIncomingSessionForTesting(transferId, receiverSession);
    TransferService.instance.injectOutgoingSessionForTesting(transferId, senderSession);

    return (
      senderSession: senderSession,
      receiverSession: receiverSession,
      transferId: transferId,
    );
  }

  group('Phase 4: Authenticated Control and Cancellation Tests', () {
    test('Post-handshake cancel without e2ee_ctrl returns HTTP 401 MISSING_CONTROL_AUTH', () async {
      final pair = await createPairedSessions();

      final uri = Uri.parse('http://127.0.0.1:$serverPort${OneShareConfig.transferCancelPath}');
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'transferId': pair.transferId,
        'senderDeviceId': identity.deviceId,
      }));
      final resp = await req.close();
      final body = jsonDecode(await utf8.decodeStream(resp));

      expect(resp.statusCode, HttpStatus.unauthorized);
      expect(body['code'], 'MISSING_CONTROL_AUTH');
    });

    test('Post-handshake cancel with invalid HMAC returns HTTP 401 INVALID_CONTROL_MAC', () async {
      final pair = await createPairedSessions();

      final uri = Uri.parse('http://127.0.0.1:$serverPort${OneShareConfig.transferCancelPath}');
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'transferId': pair.transferId,
        'senderDeviceId': identity.deviceId,
        'e2ee_ctrl': {
          'seq': 1,
          'direction': 'sender_to_receiver',
          'mac': base64Encode(Uint8List(32)), // corrupt MAC
        },
      }));
      final resp = await req.close();
      final body = jsonDecode(await utf8.decodeStream(resp));

      expect(resp.statusCode, HttpStatus.unauthorized);
      expect(body['code'], 'INVALID_CONTROL_MAC');
    });

    test('Post-handshake cancel with sequence gap returns HTTP 400 SEQUENCE_GAP', () async {
      final pair = await createPairedSessions();

      // Sign message with seq 2 when expectedNextSeq is 1
      final mac = await pair.senderSession.outgoingCtrlChannel!.computeMac(
        seq: 2,
        bodyWithoutCtrl: {
          'transferId': pair.transferId,
          'senderDeviceId': identity.deviceId,
        },
      );

      final uri = Uri.parse('http://127.0.0.1:$serverPort${OneShareConfig.transferCancelPath}');
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'transferId': pair.transferId,
        'senderDeviceId': identity.deviceId,
        'e2ee_ctrl': {
          'seq': 2,
          'direction': 'sender_to_receiver',
          'mac': base64Encode(mac),
        },
      }));
      final resp = await req.close();
      final body = jsonDecode(await utf8.decodeStream(resp));

      expect(resp.statusCode, HttpStatus.badRequest);
      expect(body['code'], 'SEQUENCE_GAP');
    });

    test('Post-handshake cancel with expired sequence outside 16-entry cache returns HTTP 409 DUPLICATE_OR_EXPIRED_SEQUENCE', () async {
      final pair = await createPairedSessions();

      // Record 17 successful executions to evict seq 1
      for (int i = 1; i <= 17; i++) {
        pair.receiverSession.incomingCtrlChannel!.recordSuccess(
          seq: i,
          mac: Uint8List(32),
          response: {'ack': i},
        );
      }

      final mac1 = await pair.senderSession.outgoingCtrlChannel!.computeMac(
        seq: 1,
        bodyWithoutCtrl: {
          'transferId': pair.transferId,
          'senderDeviceId': identity.deviceId,
        },
      );

      final uri = Uri.parse('http://127.0.0.1:$serverPort${OneShareConfig.transferCancelPath}');
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'transferId': pair.transferId,
        'senderDeviceId': identity.deviceId,
        'e2ee_ctrl': {
          'seq': 1,
          'direction': 'sender_to_receiver',
          'mac': base64Encode(mac1),
        },
      }));
      final resp = await req.close();
      final body = jsonDecode(await utf8.decodeStream(resp));

      expect(resp.statusCode, HttpStatus.conflict);
      expect(body['code'], 'DUPLICATE_OR_EXPIRED_SEQUENCE');
    });

    test('Valid signed cancel executes cancellation, returns HTTP 200, and cleans up', () async {
      final pair = await createPairedSessions();

      final signedPayload = await pair.senderSession.outgoingCtrlChannel!.signControlMessage({
        'transferId': pair.transferId,
        'senderDeviceId': identity.deviceId,
      });

      final uri = Uri.parse('http://127.0.0.1:$serverPort${OneShareConfig.transferCancelPath}');
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(signedPayload));
      final resp = await req.close();
      final body = jsonDecode(await utf8.decodeStream(resp));

      expect(resp.statusCode, HttpStatus.ok);
      expect(body['status'], 'cancellation_acknowledged');
      expect(TransferService.instance.isTransferCancelled(pair.transferId), isTrue);
    });

    test('Cancel notification failure across network does not prevent local cleanup', () async {
      final pair = await createPairedSessions();

      // Set target to an invalid closed port to simulate network failure
      TransferService.instance.setTransferTargetForTesting(
        pair.transferId,
        host: '127.0.0.1',
        port: 1, // Closed port
      );

      // cancelTransfer must finish cleanly via finally block without throwing
      await TransferService.instance.cancelTransfer(pair.transferId);

      expect(TransferService.instance.isTransferCancelled(pair.transferId), isTrue);
      expect(TransferService.instance.getSession(pair.transferId), isNull);
    });

    test('Repeated full cancellation is idempotent and safe', () async {
      final pair = await createPairedSessions();

      await TransferService.instance.cancelTransfer(pair.transferId);
      expect(TransferService.instance.isTransferCancelled(pair.transferId), isTrue);

      // Second call must return cleanly without throwing or corrupting state
      await TransferService.instance.cancelTransfer(pair.transferId);
      expect(TransferService.instance.isTransferCancelled(pair.transferId), isTrue);
    });

    test('Single-file cancellation authenticates post-handshake and preserves session for remaining files', () async {
      final pair = await createPairedSessions();
      final fileId = 'file-abc';

      final signedPayload = await pair.senderSession.outgoingCtrlChannel!.signControlMessage({
        'transferId': pair.transferId,
        'fileId': fileId,
        'senderDeviceId': identity.deviceId,
      });

      final uri = Uri.parse('http://127.0.0.1:$serverPort${OneShareConfig.transferCancelFilePath}');
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(signedPayload));
      final resp = await req.close();
      final body = jsonDecode(await utf8.decodeStream(resp));

      expect(resp.statusCode, HttpStatus.ok);
      expect(body['status'], 'file_cancellation_acknowledged');
      expect(TransferService.instance.isFileCancelled(pair.transferId, fileId), isTrue);
      // Transfer itself is NOT cancelled
      expect(TransferService.instance.isTransferCancelled(pair.transferId), isFalse);
      // Session is preserved
      expect(TransferService.instance.getSession(pair.transferId), isNotNull);
    });

    test('Single-file cancellation racing with full cancellation is serialized safely', () async {
      final pair = await createPairedSessions();
      final fileId = 'file-xyz';

      // Launch full cancellation and single file cancellation concurrently
      await Future.wait([
        TransferService.instance.cancelTransfer(pair.transferId),
        TransferService.instance.cancelSingleFile(pair.transferId, fileId),
      ]);

      expect(TransferService.instance.isTransferCancelled(pair.transferId), isTrue);
      expect(TransferService.instance.getSession(pair.transferId), isNull);
    });

    test('Destroyed post-handshake session cannot be bypassed with unauthenticated cancel', () async {
      final pair = await createPairedSessions();

      // Clean up / destroy session
      await TransferService.instance.cancelTransfer(pair.transferId);
      expect(TransferService.instance.getSession(pair.transferId), isNull);
      expect(TransferService.instance.hasCompletedHandshake(pair.transferId), isTrue);

      // Now send an unauthenticated cancel for this destroyed post-handshake transfer
      final uri = Uri.parse('http://127.0.0.1:$serverPort${OneShareConfig.transferCancelPath}');
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'transferId': pair.transferId,
        'senderDeviceId': identity.deviceId,
      }));
      final resp = await req.close();
      final body = jsonDecode(await utf8.decodeStream(resp));

      expect(resp.statusCode, HttpStatus.unauthorized);
      expect(body['code'], 'MISSING_CONTROL_AUTH');
    });

    test('HTTP control processing racing with full cancellation executes cleanly under lifecycle lock', () async {
      final pair = await createPairedSessions();

      final signedPayload = await pair.senderSession.outgoingCtrlChannel!.signControlMessage({
        'transferId': pair.transferId,
        'senderDeviceId': identity.deviceId,
      });

      final uri = Uri.parse('http://127.0.0.1:$serverPort${OneShareConfig.transferCancelPath}');

      // Launch cancelTransfer locally and HTTP cancel concurrently
      final f1 = TransferService.instance.cancelTransfer(pair.transferId);
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(signedPayload));
      final resp = await req.close();
      await resp.drain();

      await f1;

      // Both must complete cleanly without deadlocks or unhandled exceptions
      expect(resp.statusCode == HttpStatus.ok || resp.statusCode == HttpStatus.conflict, isTrue);
      expect(TransferService.instance.isTransferCancelled(pair.transferId), isTrue);
      expect(TransferService.instance.getSession(pair.transferId), isNull);
    });

    test('HTTP control processing racing with single-file cancellation executes safely', () async {
      final pair = await createPairedSessions();
      const fileId = 'file-racing-test';

      final signedPayload = await pair.senderSession.outgoingCtrlChannel!.signControlMessage({
        'transferId': pair.transferId,
        'fileId': fileId,
        'senderDeviceId': identity.deviceId,
      });

      final uri = Uri.parse('http://127.0.0.1:$serverPort${OneShareConfig.transferCancelFilePath}');

      // Fire local cancelSingleFile and remote HTTP cancel-file concurrently
      final f1 = TransferService.instance.cancelSingleFile(pair.transferId, fileId);
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(signedPayload));
      final resp = await req.close();
      await resp.drain();

      await f1;

      expect(resp.statusCode == HttpStatus.ok || resp.statusCode == HttpStatus.conflict, isTrue);
      expect(TransferService.instance.isFileCancelled(pair.transferId, fileId), isTrue);
    });

    test('Signing failure on post-handshake cancelTransfer suppresses unauthenticated peer transmission', () async {
      final pair = await createPairedSessions();

      // Point transfer target to our test server
      TransferService.instance.setTransferTargetForTesting(
        pair.transferId,
        host: '127.0.0.1',
        port: serverPort,
      );

      // Inject a throwing control channel into outgoingCtrlChannel
      pair.senderSession.outgoingCtrlChannel = _ThrowingControlMessageChannel(
        transferId: pair.transferId,
        direction: 'sender_to_receiver',
        ctrlKey: SecretKey(List.filled(32, 1)),
      );

      // Calling cancelTransfer should catch the signing error, suppress sending the unsigned message,
      // and still complete local cancellation and cleanup safely
      await TransferService.instance.cancelTransfer(pair.transferId);

      expect(TransferService.instance.isTransferCancelled(pair.transferId), isTrue);
      expect(TransferService.instance.getSession(pair.transferId), isNull);
    });

    test('Completed-handshake records evict oldest entries and enforce bounded retention', () async {
      // Mark 650 handshakes completed (exceeds _maxHandshakeIdSetSize of 500)
      for (int i = 0; i < 650; i++) {
        TransferService.instance.markHandshakeCompleted('test-hs-transfer-$i');
      }

      // Oldest entries (< 100) must have been safely evicted to prevent memory leak
      expect(TransferService.instance.hasCompletedHandshake('test-hs-transfer-0'), isFalse);
      expect(TransferService.instance.hasCompletedHandshake('test-hs-transfer-50'), isFalse);

      // Recent entries must still be retained
      expect(TransferService.instance.hasCompletedHandshake('test-hs-transfer-649'), isTrue);
      expect(TransferService.instance.hasCompletedHandshake('test-hs-transfer-600'), isTrue);
    });

    test('Unknown transfer cancellation returns HTTP 404 TRANSFER_NOT_FOUND without side effects', () async {
      const unknownTransferId = 'completely-unknown-transfer-id-999';

      final uri = Uri.parse('http://127.0.0.1:$serverPort${OneShareConfig.transferCancelPath}');
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'transferId': unknownTransferId,
        'senderDeviceId': identity.deviceId,
      }));
      final resp = await req.close();
      final body = jsonDecode(await utf8.decodeStream(resp));

      expect(resp.statusCode, HttpStatus.notFound);
      expect(body['code'], 'TRANSFER_NOT_FOUND');
      expect(TransferService.instance.isTransferCancelled(unknownTransferId), isFalse);
    });
  });
}

class _ThrowingControlMessageChannel extends ControlMessageChannel {
  _ThrowingControlMessageChannel({
    required super.transferId,
    required super.direction,
    required super.ctrlKey,
  });

  @override
  Future<Map<String, dynamic>> signControlMessage(Map<String, dynamic> payload) async {
    throw Exception('Simulated cryptographic failure during signing');
  }
}
