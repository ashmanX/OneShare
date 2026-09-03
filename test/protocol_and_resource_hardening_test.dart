import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oneshare/config/oneshare_config.dart';
import 'package:oneshare/services/crypto/crypto_key_storage.dart';
import 'package:oneshare/services/crypto/encrypted_stream.dart';
import 'package:oneshare/services/crypto/trust_store.dart';
import 'package:oneshare/services/device_identity_service.dart';
import 'package:oneshare/services/oneshare_http_server.dart';
import 'package:oneshare/services/transfer_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late DeviceIdentity identity;
  late OneShareHttpServer server;
  late int serverPort;
  late HttpClient client;

  setUp(() async {
    final storage = InMemoryKeyStorage();
    identity = await DeviceIdentityService.initialize(storage: storage);
    final trustStore = TrustStore(storage: storage);
    TransferService.instance.trustStore = trustStore;

    server = OneShareHttpServer(identity: identity);
    await server.start(port: 0);
    serverPort = server.port;
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
  });

  group('Phase 5: HTTP Body Size Limits & 413 Handling', () {
    test('Request body exceeding 64 KB on /transfer/request returns HTTP 413 PAYLOAD_TOO_LARGE', () async {
      final uri = Uri.parse('http://127.0.0.1:$serverPort${OneShareConfig.transferRequestPath}');
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;

      // Create an oversized payload > 64 KB
      final largePadding = 'A' * (70 * 1024);
      final oversizedPayload = jsonEncode({
        'transferId': 'test-oversized-1',
        'padding': largePadding,
      });

      req.write(oversizedPayload);
      final resp = await req.close();
      final body = jsonDecode(await utf8.decodeStream(resp));

      expect(resp.statusCode, equals(HttpStatus.requestEntityTooLarge)); // 413
      expect(body['code'], equals('PAYLOAD_TOO_LARGE'));
    });

    test('Cancel body exceeding 4 KB on /transfer/cancel returns HTTP 413 PAYLOAD_TOO_LARGE', () async {
      final uri = Uri.parse('http://127.0.0.1:$serverPort${OneShareConfig.transferCancelPath}');
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;

      // Create an oversized payload > 4 KB
      final oversizedPayload = jsonEncode({
        'transferId': 'test-oversized-cancel',
        'padding': 'B' * 5000,
      });

      req.write(oversizedPayload);
      final resp = await req.close();
      final body = jsonDecode(await utf8.decodeStream(resp));

      expect(resp.statusCode, equals(HttpStatus.requestEntityTooLarge)); // 413
      expect(body['code'], equals('PAYLOAD_TOO_LARGE'));
    });

    test('Accept body exceeding 16 KB on /transfer/accept returns HTTP 413 PAYLOAD_TOO_LARGE', () async {
      final uri = Uri.parse('http://127.0.0.1:$serverPort${OneShareConfig.transferAcceptPath}');
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;

      final oversizedPayload = jsonEncode({
        'transferId': 'test-oversized-accept',
        'padding': 'C' * 20000,
      });

      req.write(oversizedPayload);
      final resp = await req.close();
      final body = jsonDecode(await utf8.decodeStream(resp));

      expect(resp.statusCode, equals(HttpStatus.requestEntityTooLarge)); // 413
      expect(body['code'], equals('PAYLOAD_TOO_LARGE'));
    });
  });

  group('Phase 5: Malformed JSON Rejection', () {
    test('Malformed JSON returns HTTP 400 MALFORMED_JSON instead of {}', () async {
      final uri = Uri.parse('http://127.0.0.1:$serverPort${OneShareConfig.transferRequestPath}');
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;

      // Truncated, invalid JSON
      req.write('{"transferId": "broken-json", "files": [');
      final resp = await req.close();
      final body = jsonDecode(await utf8.decodeStream(resp));

      expect(resp.statusCode, equals(HttpStatus.badRequest)); // 400
      expect(body['code'], equals('MALFORMED_JSON'));
    });

    test('Non-object JSON (e.g. JSON array) returns HTTP 400 MALFORMED_JSON', () async {
      final uri = Uri.parse('http://127.0.0.1:$serverPort${OneShareConfig.transferRequestPath}');
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;

      req.write('[1, 2, 3]');
      final resp = await req.close();
      final body = jsonDecode(await utf8.decodeStream(resp));

      expect(resp.statusCode, equals(HttpStatus.badRequest)); // 400
      expect(body['code'], equals('MALFORMED_JSON'));
    });
  });

  group('Phase 5: Protocol Version & Cryptographic Parameter Validation', () {
    test('Missing version in msg1 is rejected with PROTOCOL_VERSION_MISMATCH', () async {
      final outcome = await TransferService.instance.handleIncomingRequest({
        'transferId': 'v-test-missing',
        'senderDeviceId': 'dev1',
        'senderDeviceName': 'Device 1',
        'files': [
          {'fileId': 'f1', 'fileName': 'a.txt', 'fileSize': 100}
        ],
        'e2ee': {
          'manifestHash': base64Encode(Uint8List(32)),
          'senderIdentityPubKey': base64Encode(Uint8List(32)),
          'senderEphemeralPubKey': base64Encode(Uint8List(32)),
          'senderEphemeralSig': base64Encode(Uint8List(64)),
        }
      }, '127.0.0.1');

      expect(outcome['status'], equals('rejected'));
      expect(outcome['code'], equals('PROTOCOL_VERSION_MISMATCH'));
    });

    test('String version "2" in msg1 is rejected with PROTOCOL_VERSION_MISMATCH', () async {
      final outcome = await TransferService.instance.handleIncomingRequest({
        'transferId': 'v-test-string',
        'senderDeviceId': 'dev1',
        'senderDeviceName': 'Device 1',
        'files': [
          {'fileId': 'f1', 'fileName': 'a.txt', 'fileSize': 100}
        ],
        'e2ee': {
          'version': '2', // String instead of integer
          'manifestHash': base64Encode(Uint8List(32)),
          'senderIdentityPubKey': base64Encode(Uint8List(32)),
          'senderEphemeralPubKey': base64Encode(Uint8List(32)),
          'senderEphemeralSig': base64Encode(Uint8List(64)),
        }
      }, '127.0.0.1');

      expect(outcome['status'], equals('rejected'));
      expect(outcome['code'], equals('PROTOCOL_VERSION_MISMATCH'));
    });

    test('Non-v2 integer version (e.g. 1) in msg1 is rejected', () async {
      final outcome = await TransferService.instance.handleIncomingRequest({
        'transferId': 'v-test-v1',
        'senderDeviceId': 'dev1',
        'senderDeviceName': 'Device 1',
        'files': [
          {'fileId': 'f1', 'fileName': 'a.txt', 'fileSize': 100}
        ],
        'e2ee': {
          'version': 1,
          'manifestHash': base64Encode(Uint8List(32)),
          'senderIdentityPubKey': base64Encode(Uint8List(32)),
          'senderEphemeralPubKey': base64Encode(Uint8List(32)),
          'senderEphemeralSig': base64Encode(Uint8List(64)),
        }
      }, '127.0.0.1');

      expect(outcome['status'], equals('rejected'));
      expect(outcome['code'], equals('PROTOCOL_VERSION_MISMATCH'));
    });

    test('Invalid parameter byte length (31-byte key) is rejected with INVALID_HANDSHAKE', () async {
      final outcome = await TransferService.instance.handleIncomingRequest({
        'transferId': 'v-test-short-key',
        'senderDeviceId': 'dev1',
        'senderDeviceName': 'Device 1',
        'files': [
          {'fileId': 'f1', 'fileName': 'a.txt', 'fileSize': 100}
        ],
        'e2ee': {
          'version': 2,
          'manifestHash': base64Encode(Uint8List(32)),
          'senderIdentityPubKey': base64Encode(Uint8List(31)), // 31 bytes instead of 32
          'senderEphemeralPubKey': base64Encode(Uint8List(32)),
          'senderEphemeralSig': base64Encode(Uint8List(64)),
        }
      }, '127.0.0.1');

      expect(outcome['status'], equals('rejected'));
      expect(outcome['code'], equals('INVALID_HANDSHAKE'));
    });

    test('Invalid signature byte length (63-byte signature) is rejected with INVALID_HANDSHAKE', () async {
      final outcome = await TransferService.instance.handleIncomingRequest({
        'transferId': 'v-test-short-sig',
        'senderDeviceId': 'dev1',
        'senderDeviceName': 'Device 1',
        'files': [
          {'fileId': 'f1', 'fileName': 'a.txt', 'fileSize': 100}
        ],
        'e2ee': {
          'version': 2,
          'manifestHash': base64Encode(Uint8List(32)),
          'senderIdentityPubKey': base64Encode(Uint8List(32)),
          'senderEphemeralPubKey': base64Encode(Uint8List(32)),
          'senderEphemeralSig': base64Encode(Uint8List(63)), // 63 bytes instead of 64
        }
      }, '127.0.0.1');

      expect(outcome['status'], equals('rejected'));
      expect(outcome['code'], equals('INVALID_HANDSHAKE'));
    });

    test('Non-Base64 parameter string is rejected with INVALID_HANDSHAKE', () async {
      final outcome = await TransferService.instance.handleIncomingRequest({
        'transferId': 'v-test-not-base64',
        'senderDeviceId': 'dev1',
        'senderDeviceName': 'Device 1',
        'files': [
          {'fileId': 'f1', 'fileName': 'a.txt', 'fileSize': 100}
        ],
        'e2ee': {
          'version': 2,
          'manifestHash': 'not a base 64 string!!',
          'senderIdentityPubKey': base64Encode(Uint8List(32)),
          'senderEphemeralPubKey': base64Encode(Uint8List(32)),
          'senderEphemeralSig': base64Encode(Uint8List(64)),
        }
      }, '127.0.0.1');

      expect(outcome['status'], equals('rejected'));
      expect(outcome['code'], equals('INVALID_HANDSHAKE'));
    });
  });

  group('Phase 5: Transfer Resource & Metadata Limits', () {
    test('Batch exceeding 100 files is rejected with EXCESSIVE_FILE_COUNT', () async {
      final files = List.generate(
        101,
        (i) => {'fileId': 'f$i', 'fileName': 'file_$i.txt', 'fileSize': 100},
      );

      final outcome = await TransferService.instance.handleIncomingRequest({
        'transferId': 'res-test-too-many-files',
        'senderDeviceId': 'dev1',
        'senderDeviceName': 'Device 1',
        'files': files,
        'e2ee': {'version': 2}
      }, '127.0.0.1');

      expect(outcome['status'], equals('rejected'));
      expect(outcome['code'], equals('EXCESSIVE_FILE_COUNT'));
    });

    test('Empty file list is rejected with EMPTY_FILE_LIST', () async {
      final outcome = await TransferService.instance.handleIncomingRequest({
        'transferId': 'res-test-empty-files',
        'senderDeviceId': 'dev1',
        'senderDeviceName': 'Device 1',
        'files': <Map<String, dynamic>>[],
        'e2ee': {'version': 2}
      }, '127.0.0.1');

      expect(outcome['status'], equals('rejected'));
      expect(outcome['code'], equals('EMPTY_FILE_LIST'));
    });

    test('Filename exceeding 255 characters is rejected with INVALID_FILE_NAME', () async {
      final outcome = await TransferService.instance.handleIncomingRequest({
        'transferId': 'res-test-long-name',
        'senderDeviceId': 'dev1',
        'senderDeviceName': 'Device 1',
        'files': [
          {'fileId': 'f1', 'fileName': 'A' * 256, 'fileSize': 100}
        ],
        'e2ee': {'version': 2}
      }, '127.0.0.1');

      expect(outcome['status'], equals('rejected'));
      expect(outcome['code'], equals('INVALID_FILE_NAME'));
    });

    test('Filename with path traversal characters (/ or \\) is rejected with INVALID_FILE_NAME', () async {
      final outcome = await TransferService.instance.handleIncomingRequest({
        'transferId': 'res-test-traversal',
        'senderDeviceId': 'dev1',
        'senderDeviceName': 'Device 1',
        'files': [
          {'fileId': 'f1', 'fileName': '../../etc/passwd', 'fileSize': 100}
        ],
        'e2ee': {'version': 2}
      }, '127.0.0.1');

      expect(outcome['status'], equals('rejected'));
      expect(outcome['code'], equals('INVALID_FILE_NAME'));
    });

    test('File size exceeding 100 GB is rejected with EXCESSIVE_FILE_SIZE', () async {
      final outcome = await TransferService.instance.handleIncomingRequest({
        'transferId': 'res-test-oversized-file',
        'senderDeviceId': 'dev1',
        'senderDeviceName': 'Device 1',
        'files': [
          {'fileId': 'f1', 'fileName': 'huge.iso', 'fileSize': (100 * 1024 * 1024 * 1024) + 1}
        ],
        'e2ee': {'version': 2}
      }, '127.0.0.1');

      expect(outcome['status'], equals('rejected'));
      expect(outcome['code'], equals('EXCESSIVE_FILE_SIZE'));
    });
  });

  group('Phase 5: Nonce Overflow & Stream Parser Safety', () {
    test('EncryptedStreamWriter.buildNonce throws EncryptedStreamException on overflow', () {
      expect(
        () => EncryptedStreamWriter.buildNonce(-1),
        throwsA(isA<EncryptedStreamException>()),
      );
    });

    test('EncryptedStreamReader throws EncryptedStreamException on parser buffer overflow (>128 KB)', () async {
      final key = await Chacha20.poly1305Aead().newSecretKey();
      final reader = EncryptedStreamReader(
        fileKey: key,
        transferId: 'overflow-test',
        fileId: 'file-1',
      );

      // Feed a stream that never completes framing and exceeds 128 KB
      final corruptData = Uint8List(132 * 1024);
      final stream = Stream.value(corruptData);

      expect(
        () async {
          await for (final _ in reader.processStream(stream)) {}
        },
        throwsA(isA<EncryptedStreamException>().having(
          (e) => e.message,
          'message',
          contains('Parser buffer overflow'),
        )),
      );
    });
  });
}
