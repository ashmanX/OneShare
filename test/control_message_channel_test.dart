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

    test('Two concurrent duplicate controls execute business action exactly once', () async {
      final msg = await senderChannel.signControlMessage({'transferId': transferId, 'action': 'cancel'});

      int executionCount = 0;
      final results = await Future.wait([
        receiverChannel.processIncomingControlMessage(
          fullBody: msg,
          action: () async {
            executionCount++;
            await Future.delayed(const Duration(milliseconds: 20));
            return {'status': 'cancellation_acknowledged'};
          },
        ),
        receiverChannel.processIncomingControlMessage(
          fullBody: msg,
          action: () async {
            executionCount++;
            await Future.delayed(const Duration(milliseconds: 20));
            return {'status': 'cancellation_acknowledged'};
          },
        ),
      ]);

      expect(executionCount, 1, reason: 'Business callback must be executed exactly once for duplicate requests');
      expect(results[0].status, ControlEvaluationStatus.idempotentReplay);
      expect(results[1].status, ControlEvaluationStatus.idempotentReplay);
      expect(results[0].cachedResponse, {'status': 'cancellation_acknowledged'});
      expect(results[1].cachedResponse, {'status': 'cancellation_acknowledged'});
      expect(receiverChannel.expectedNextSeq, 2);
    });

    test('Business callback failure leaves sequence retryable and does not advance expectedNextSeq', () async {
      final msg = await senderChannel.signControlMessage({'transferId': transferId, 'action': 'cancel'});

      expect(receiverChannel.expectedNextSeq, 1);

      // Attempt 1: Business action throws an exception
      bool threw = false;
      try {
        await receiverChannel.processIncomingControlMessage(
          fullBody: msg,
          action: () async {
            throw StateError('Simulated DB/IO failure');
          },
        );
      } catch (e) {
        threw = true;
      }
      expect(threw, isTrue);

      // Verify channel state: sequence did NOT advance and nothing was cached
      expect(receiverChannel.expectedNextSeq, 1);

      // Attempt 2: Retry with the EXACT SAME valid message and sequence
      int retryExecuted = 0;
      final retryEval = await receiverChannel.processIncomingControlMessage(
        fullBody: msg,
        action: () async {
          retryExecuted++;
          return {'status': 'cancellation_acknowledged_retry'};
        },
      );

      expect(retryExecuted, 1);
      expect(retryEval.status, ControlEvaluationStatus.idempotentReplay);
      expect(retryEval.cachedResponse, {'status': 'cancellation_acknowledged_retry'});
      expect(receiverChannel.expectedNextSeq, 2);
    });

    test('Concurrent controls with different sequence numbers cannot bypass ordering', () async {
      final msgSeq1 = await senderChannel.signControlMessage({'transferId': transferId, 'seqOrder': 1});
      final msgSeq2 = await senderChannel.signControlMessage({'transferId': transferId, 'seqOrder': 2});

      // Launch seq 2 slightly before or concurrent with seq 1
      final results = await Future.wait([
        receiverChannel.processIncomingControlMessage(
          fullBody: msgSeq2,
          action: () async => {'ack': 2},
        ),
        receiverChannel.processIncomingControlMessage(
          fullBody: msgSeq1,
          action: () async => {'ack': 1},
        ),
      ]);

      // One must be a sequence gap error (400) because seq 2 ran before seq 1 advanced expectedNextSeq
      final seq2Result = results[0];
      expect(seq2Result.status, ControlEvaluationStatus.error);
      expect(seq2Result.statusCode, 400);
      expect(seq2Result.errorCode, 'SEQUENCE_GAP');

      final seq1Result = results[1];
      expect(seq1Result.status, ControlEvaluationStatus.idempotentReplay);
      expect(seq1Result.cachedResponse, {'ack': 1});
      expect(receiverChannel.expectedNextSeq, 2);
    });
  });
}
