import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oneshare/services/crypto/crypto_key_storage.dart';
import 'package:oneshare/services/crypto/e2ee_session.dart';
import 'package:oneshare/services/crypto/log_sanitizer.dart';
import 'package:oneshare/services/crypto/trust_store.dart';
import 'package:oneshare/services/device_identity_service.dart';
import 'package:oneshare/services/transfer_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LogSanitizer Unit Tests', () {
    test('Redacts Bearer authorization header tokens', () {
      const raw = 'Request Header: authorization = Bearer tok_sec_12345678abcdef';
      final redacted = LogSanitizer.redact(raw);
      expect(redacted, contains('Bearer [REDACTED]'));
      expect(redacted.contains('tok_sec_12345678abcdef'), isFalse);
    });

    test('Redacts tok_sec_ secret transfer tokens', () {
      const raw = 'Validating token tok_sec_abcdef1234567890 for transfer';
      final redacted = LogSanitizer.redact(raw);
      expect(redacted, contains('[REDACTED_TOKEN]'));
      expect(redacted.contains('tok_sec_abcdef1234567890'), isFalse);
    });

    test('Redacts cryptographic keys and signatures in string logs', () {
      const raw = 'senderIdentityPubKey: dGVzdF9rZXlfYnl0ZXNfZXhhbXBsZQ==, receiverEphemeralSig: c2lnbmF0dXJl';
      final redacted = LogSanitizer.redact(raw);
      expect(redacted, contains('senderIdentityPubKey: [REDACTED]'));
      expect(redacted, contains('receiverEphemeralSig: [REDACTED]'));
    });

    test('Sanitizes filesystem paths to basename or <path>/basename', () {
      final sanitized = LogSanitizer.sanitizePath('/Users/alice/Downloads/secret_file.pdf');
      expect(sanitized, equals('<path>/secret_file.pdf'));
      expect(sanitized.contains('Users'), isFalse);
      expect(sanitized.contains('alice'), isFalse);
    });

    test('Recursively sanitizes JSON maps without mutating unknown public metadata', () {
      final payload = {
        'transferId': 'test-transfer-id-12345',
        'transferToken': 'tok_sec_secret',
        'e2ee': {
          'version': 2,
          'senderIdentityPubKey': 'dGVzdF9wdWJrZXk=',
          'senderEphemeralSig': 'c2lnbmF0dXJl',
        },
        'files': [
          {'fileName': 'report.pdf', 'fileSize': 1024}
        ],
      };

      final sanitized = LogSanitizer.sanitizeJson(payload) as Map<String, dynamic>;
      expect(sanitized['transferId'], equals('test-transfer-id-12345'));
      expect(sanitized['transferToken'], equals('[REDACTED]'));
      final e2ee = sanitized['e2ee'] as Map<String, dynamic>;
      expect(e2ee['version'], equals(2));
      expect(e2ee['senderIdentityPubKey'], equals('[REDACTED]'));
      expect(e2ee['senderEphemeralSig'], equals('[REDACTED]'));
      final files = sanitized['files'] as List;
      expect((files.first as Map)['fileName'], equals('report.pdf'));
    });

    test('Truncates transfer and device IDs to 8 characters with ellipsis', () {
      expect(LogSanitizer.truncateId('1234567890abcdef'), equals('12345678...'));
      expect(LogSanitizer.truncateId('short'), equals('short'));
      expect(LogSanitizer.truncateId(null), equals('<empty>'));
    });
  });

  group('Session Destruction & Zeroization Verification', () {
    test('E2eeSession.destroy zeroes all mutable byte buffers and sets state to destroyed', () async {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();

      final session = E2eeSession(
        isInitiator: true,
        transferId: 'test-destroy-session',
        myIdentityKeyPair: keyPair,
        myIdentityPubKey: Uint8List.fromList(List.filled(32, 1)),
      );

      session.myEphemeralKeyPair = keyPair;
      session.myEphemeralPubKey = Uint8List.fromList(List.filled(32, 2));
      session.peerIdentityPubKey = Uint8List.fromList(List.filled(32, 3));
      session.peerEphemeralPubKey = Uint8List.fromList(List.filled(32, 4));
      session.manifestHash = Uint8List.fromList(List.filled(32, 5));
      session.tokenHash = Uint8List.fromList(List.filled(32, 6));
      session.transcriptHash = Uint8List.fromList(List.filled(32, 7));
      session.sasBytes = Uint8List.fromList(List.filled(32, 8));

      final pubKeyRef = session.myEphemeralPubKey!;
      final sasRef = session.sasBytes!;

      expect(session.state, equals(E2eeSessionState.initial));
      await session.destroy();

      expect(session.state, equals(E2eeSessionState.destroyed));
      expect(session.myEphemeralKeyPair, isNull);
      expect(session.myEphemeralPubKey, isNull);
      expect(session.peerEphemeralPubKey, isNull);
      expect(session.peerIdentityPubKey, isNull);
      expect(session.manifestHash, isNull);
      expect(session.tokenHash, isNull);
      expect(session.transcriptHash, isNull);
      expect(session.sasBytes, isNull);

      // Verify accessible byte buffers were zeroed
      expect(pubKeyRef.every((b) => b == 0), isTrue);
      expect(sasRef.every((b) => b == 0), isTrue);
    });
  });

  group('Device Identity Reset & Compromise Recovery', () {
    test('resetIdentity generates a fresh keypair, persists it, and wipes TrustStore', () async {
      final storage = InMemoryKeyStorage();
      final trustStore = TrustStore(storage: storage);

      // 1. Initialize identity
      final originalIdentity = await DeviceIdentityService.initialize(storage: storage);
      expect(originalIdentity.deviceId, isNotEmpty);
      final originalFingerprint = originalIdentity.fingerprint;

      // 2. Pair a mock peer in TrustStore
      final mockPeerKey = Uint8List.fromList(List.filled(32, 9));
      final actualHash = await Sha256().hash(mockPeerKey);
      final validPeerFp = actualHash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      await trustStore.recordPeerEncounter(
        fingerprint: validPeerFp,
        identityPublicKeyBytes: mockPeerKey,
        deviceName: 'Trusted Peer',
        deviceId: 'peer-device-1',
      );
      expect(await trustStore.getPeer(validPeerFp), isNotNull);

      // 3. Trigger compromise recovery / identity reset
      final freshIdentity = await DeviceIdentityService.resetIdentity(
        storage: storage,
        trustStore: trustStore,
      );

      // 4. Verify new cryptographic identity was generated
      expect(freshIdentity.fingerprint, isNot(equals(originalFingerprint)));
      expect(freshIdentity.deviceId, isNot(equals(originalIdentity.deviceId)));

      // 5. Verify TrustStore was purged completely
      final remainingTrust = await trustStore.getAllPeers();
      expect(remainingTrust.isEmpty, isTrue);
    });
  });

  group('TransferService Error Sanitization', () {
    test('handleIncomingRequest returns generic error on corrupted E2EE handshake', () async {
      final storage = InMemoryKeyStorage();
      await DeviceIdentityService.initialize(storage: storage);

      final transferService = TransferService.instance;

      final corruptedPayload = {
        'transferId': 'test-fail-handshake',
        'senderDeviceId': 'sender-dev-1',
        'senderDeviceName': 'Alice Device',
        'senderHost': '127.0.0.1',
        'senderPort': 8080,
        'files': [
          {'fileId': 'f1', 'fileName': 'test.txt', 'fileSize': 100}
        ],
        'totalSize': 100,
        'e2ee': {
          'version': 2,
          'manifestHash': 'bad-base64!',
          'senderIdentityPubKey': 'bad-base64!',
          'senderEphemeralPubKey': 'bad-base64!',
          'senderEphemeralSig': 'bad-base64!',
        },
      };

      final response = await transferService.handleIncomingRequest(
        corruptedPayload,
        '127.0.0.1',
      );

      expect(response['status'], equals('rejected'));
      expect(response['code'], equals('INVALID_HANDSHAKE'));
      expect(response['error'], equals('Invalid Base64 encoding in cryptographic parameters'));
      // Ensure no raw exception stack or unparsed keys leak in error message
      expect(response['error'].toString().contains('FormatException'), isFalse);
    });
  });
}
