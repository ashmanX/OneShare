import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oneshare/services/crypto/canonical_encoding.dart';
import 'package:oneshare/services/crypto/control_message_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SecretKey ctrlKey;
  late ControlMessageChannel senderChannel;
  late ControlMessageChannel receiverChannel;
  const transferId = 'test-transfer-ctrl-001';

  setUp(() async {
    final rawKeyBytes = Uint8List.fromList(List.generate(32, (i) => (i * 13) % 256));
    ctrlKey = SecretKey(rawKeyBytes);

    // Sender sends to receiver, receiver receives from sender
    senderChannel = ControlMessageChannel(
      transferId: transferId,
      direction: 'sender_to_receiver',
      ctrlKey: ctrlKey,
    );
    receiverChannel = ControlMessageChannel(
      transferId: transferId,
      direction: 'sender_to_receiver',
      ctrlKey: ctrlKey,
    );
  });

  group('Canonical JSON serialization', () {
    test('canonicalJson sorts keys deterministically and removes whitespace', () {
      final map1 = {
        'z': 1,
        'a': 'hello',
        'm': {'nested_b': 2, 'nested_a': 1},
      };
      final map2 = {
        'a': 'hello',
        'm': {'nested_a': 1, 'nested_b': 2},
        'z': 1,
      };
      expect(
        CanonicalEncoding.canonicalJson(map1),
        CanonicalEncoding.canonicalJson(map2),
      );
      expect(
        CanonicalEncoding.canonicalJson(map1),
        '{"a":"hello","m":{"nested_a":1,"nested_b":2},"z":1}',
      );
    });
  });

  group('Phase 6 Checkpoint: ControlMessageChannel tests', () {
    test('Valid HMAC + sequence accepted as executeNew', () async {
      final initialPayload = {
        'transferId': transferId,
        'senderDeviceId': 'device-alpha',
      };

      final signedMsg = await senderChannel.signControlMessage(initialPayload);
      expect(signedMsg['e2ee_ctrl'], isNotNull);
      final ctrl = signedMsg['e2ee_ctrl'] as Map<String, dynamic>;
      expect(ctrl['seq'], 1);
      expect(ctrl['direction'], 'sender_to_receiver');
      expect(ctrl['mac'], isNotNull);

      final eval = await receiverChannel.evaluateIncomingControlMessage(
        fullBody: signedMsg,
      );
      expect(eval.status, ControlEvaluationStatus.executeNew);
      expect(eval.isOk, isTrue);

      // Record success
      final responsePayload = {'status': 'cancellation_acknowledged'};
      receiverChannel.recordSuccess(
        seq: ctrl['seq'] as int,
        mac: Uint8List.fromList(base64Decode(ctrl['mac'] as String)),
        response: responsePayload,
      );

      expect(receiverChannel.expectedNextSeq, 2);
    });

    test('Retransmitted message within 16-entry window returns original cached ACK without re-executing', () async {
      final initialPayload = {'transferId': transferId, 'action': 'cancel'};
      final signedMsg = await senderChannel.signControlMessage(initialPayload);
      final ctrl = signedMsg['e2ee_ctrl'] as Map<String, dynamic>;

      final eval1 = await receiverChannel.evaluateIncomingControlMessage(
        fullBody: signedMsg,
      );
      expect(eval1.status, ControlEvaluationStatus.executeNew);

      final responsePayload = {'status': 'cancellation_acknowledged', 'counter': 1};
      receiverChannel.recordSuccess(
        seq: ctrl['seq'] as int,
        mac: Uint8List.fromList(base64Decode(ctrl['mac'] as String)),
        response: responsePayload,
      );

      // Immediate retransmission of identical message
      final eval2 = await receiverChannel.evaluateIncomingControlMessage(
        fullBody: signedMsg,
      );
      expect(eval2.status, ControlEvaluationStatus.idempotentReplay);
      expect(eval2.cachedResponse, responsePayload);
    });

    test('Delayed retransmission after intervening messages returns correct cached ACK', () async {
      final msg1 = await senderChannel.signControlMessage({'transferId': transferId, 'fileId': 'f1'});
      final ctrl1 = msg1['e2ee_ctrl'] as Map<String, dynamic>;
      receiverChannel.recordSuccess(
        seq: ctrl1['seq'] as int,
        mac: Uint8List.fromList(base64Decode(ctrl1['mac'] as String)),
        response: {'status': 'f1_cancelled'},
      );

      final msg2 = await senderChannel.signControlMessage({'transferId': transferId, 'fileId': 'f2'});
      final ctrl2 = msg2['e2ee_ctrl'] as Map<String, dynamic>;
      receiverChannel.recordSuccess(
        seq: ctrl2['seq'] as int,
        mac: Uint8List.fromList(base64Decode(ctrl2['mac'] as String)),
        response: {'status': 'f2_cancelled'},
      );

      // Delayed retry of msg1 arrives after msg2
      final retryEval1 = await receiverChannel.evaluateIncomingControlMessage(fullBody: msg1);
      expect(retryEval1.status, ControlEvaluationStatus.idempotentReplay);
      expect(retryEval1.cachedResponse, {'status': 'f1_cancelled'});

      // Delayed retry of msg2
      final retryEval2 = await receiverChannel.evaluateIncomingControlMessage(fullBody: msg2);
      expect(retryEval2.status, ControlEvaluationStatus.idempotentReplay);
      expect(retryEval2.cachedResponse, {'status': 'f2_cancelled'});
    });

    test('Modified message with duplicate seq rejected (401 Unauthorized / MAC mismatch)', () async {
      final msg1 = await senderChannel.signControlMessage({'transferId': transferId, 'fileId': 'f1'});
      final ctrl1 = msg1['e2ee_ctrl'] as Map<String, dynamic>;
      receiverChannel.recordSuccess(
        seq: ctrl1['seq'] as int,
        mac: Uint8List.fromList(base64Decode(ctrl1['mac'] as String)),
        response: {'status': 'f1_cancelled'},
      );

      // Attacker attempts to replay seq: 1 with modified body
      final tamperedMsg = {
        'transferId': transferId,
        'fileId': 'f_malicious',
        'e2ee_ctrl': {
          'seq': ctrl1['seq'],
          'direction': 'sender_to_receiver',
          'mac': ctrl1['mac'], // mac was for fileId: f1, not f_malicious
        },
      };

      final eval = await receiverChannel.evaluateIncomingControlMessage(fullBody: tamperedMsg);
      expect(eval.status, ControlEvaluationStatus.error);
      expect(eval.statusCode, 401);
      expect(eval.errorCode, 'INVALID_CONTROL_MAC');
    });

    test('Expired message below expectedNextSeq and outside 16-entry window rejected (409 Conflict)', () async {
      // Send and record 17 messages to overflow 16-entry cache
      Map<String, dynamic>? firstMessage;
      for (int i = 1; i <= 17; i++) {
        final msg = await senderChannel.signControlMessage({'transferId': transferId, 'counter': i});
        if (i == 1) {
          firstMessage = msg;
        }
        final ctrl = msg['e2ee_ctrl'] as Map<String, dynamic>;
        receiverChannel.recordSuccess(
          seq: ctrl['seq'] as int,
          mac: Uint8List.fromList(base64Decode(ctrl['mac'] as String)),
          response: {'ack': i},
        );
      }

      expect(receiverChannel.expectedNextSeq, 18);

      // Retry of message 1 (which has been evicted from 16-entry cache)
      final eval = await receiverChannel.evaluateIncomingControlMessage(fullBody: firstMessage!);
      expect(eval.status, ControlEvaluationStatus.error);
      expect(eval.statusCode, 409);
      expect(eval.errorCode, 'DUPLICATE_OR_EXPIRED_SEQUENCE');

      // But message 2 (still within 16 entries) is recognized as idempotent replay
      // Note: Since cache size is 16, entries 2..17 are present
      final msg2 = {
        'transferId': transferId,
        'counter': 2,
        'e2ee_ctrl': {
          'seq': 2,
          'direction': 'sender_to_receiver',
          'mac': base64Encode(await senderChannel.computeMac(
            seq: 2,
            bodyWithoutCtrl: {'transferId': transferId, 'counter': 2},
          )),
        }
      };
      final eval2 = await receiverChannel.evaluateIncomingControlMessage(fullBody: msg2);
      expect(eval2.status, ControlEvaluationStatus.idempotentReplay);
    });

    test('Gap in seq rejected (400 Bad Request)', () async {
      // expectedNextSeq is 1, but sender sends seq 2
      final msgWithGap = {
        'transferId': transferId,
        'action': 'cancel',
        'e2ee_ctrl': {
          'seq': 2,
          'direction': 'sender_to_receiver',
          'mac': base64Encode(await senderChannel.computeMac(
            seq: 2,
            bodyWithoutCtrl: {'transferId': transferId, 'action': 'cancel'},
          )),
        }
      };

      final eval = await receiverChannel.evaluateIncomingControlMessage(fullBody: msgWithGap);
      expect(eval.status, ControlEvaluationStatus.error);
      expect(eval.statusCode, 400);
      expect(eval.errorCode, 'SEQUENCE_GAP');
    });

    test('Missing e2ee_ctrl block rejected with 401 INVALID_CONTROL_MAC', () async {
      final unauthenticatedMsg = {
        'transferId': transferId,
        'action': 'cancel',
      };

      final eval = await receiverChannel.evaluateIncomingControlMessage(fullBody: unauthenticatedMsg);
      expect(eval.status, ControlEvaluationStatus.error);
      expect(eval.statusCode, 401);
      expect(eval.errorCode, 'INVALID_CONTROL_MAC');
    });

    test('Wrong direction label rejected with 401 INVALID_CONTROL_MAC', () async {
      final msg = await senderChannel.signControlMessage({'transferId': transferId, 'action': 'cancel'});
      final ctrl = msg['e2ee_ctrl'] as Map<String, dynamic>;
      ctrl['direction'] = 'receiver_to_sender'; // Inverted direction

      final eval = await receiverChannel.evaluateIncomingControlMessage(fullBody: msg);
      expect(eval.status, ControlEvaluationStatus.error);
      expect(eval.statusCode, 401);
      expect(eval.errorCode, 'INVALID_CONTROL_MAC');
    });
  });
}
