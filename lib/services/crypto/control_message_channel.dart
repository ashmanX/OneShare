import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:oneshare/services/crypto/canonical_encoding.dart';

/// Represents a cached processed control message response for idempotent retries.
class CachedControlResponse {
  const CachedControlResponse({
    required this.mac,
    required this.response,
  });

  final Uint8List mac;
  final Map<String, dynamic> response;
}

/// Result of evaluating an incoming authenticated control message.
class ControlMessageEvaluation {
  const ControlMessageEvaluation._({
    required this.status,
    this.cachedResponse,
    this.statusCode = 200,
    this.errorCode,
    this.errorMessage,
  });

  final ControlEvaluationStatus status;
  final Map<String, dynamic>? cachedResponse;
  final int statusCode;
  final String? errorCode;
  final String? errorMessage;

  factory ControlMessageEvaluation.executeNew() {
    return const ControlMessageEvaluation._(status: ControlEvaluationStatus.executeNew);
  }

  factory ControlMessageEvaluation.idempotentReplay(Map<String, dynamic> cachedResponse) {
    return ControlMessageEvaluation._(
      status: ControlEvaluationStatus.idempotentReplay,
      cachedResponse: cachedResponse,
      statusCode: 200,
    );
  }

  factory ControlMessageEvaluation.invalidMac([String message = 'Invalid control message MAC']) {
    return ControlMessageEvaluation._(
      status: ControlEvaluationStatus.error,
      statusCode: 401,
      errorCode: 'INVALID_CONTROL_MAC',
      errorMessage: message,
    );
  }

  factory ControlMessageEvaluation.duplicateOrExpired([String message = 'Duplicate or expired sequence']) {
    return ControlMessageEvaluation._(
      status: ControlEvaluationStatus.error,
      statusCode: 409,
      errorCode: 'DUPLICATE_OR_EXPIRED_SEQUENCE',
      errorMessage: message,
    );
  }

  factory ControlMessageEvaluation.sequenceGap([String message = 'Sequence gap detected']) {
    return ControlMessageEvaluation._(
      status: ControlEvaluationStatus.error,
      statusCode: 400,
      errorCode: 'SEQUENCE_GAP',
      errorMessage: message,
    );
  }

  bool get isOk => status == ControlEvaluationStatus.executeNew || status == ControlEvaluationStatus.idempotentReplay;
}

enum ControlEvaluationStatus {
  executeNew,
  idempotentReplay,
  error,
}

/// Manages authenticated control messages (HMAC-SHA256), sequential numbering,
/// and a bounded 16-entry idempotent retry cache for a specific direction.
class ControlMessageChannel {
  ControlMessageChannel({
    required this.transferId,
    required this.direction, // "sender_to_receiver" or "receiver_to_sender"
    required this.ctrlKey,
  });

  final String transferId;
  final String direction;
  final SecretKey ctrlKey;

  static final Hmac _hmacSha256 = Hmac.sha256();
  static const int kMaxCacheSize = 16;

  int _outgoingSeq = 0;
  int _expectedNextSeq = 1;

  /// Bounded FIFO/LRU cache mapping `seq -> CachedControlResponse`.
  final Map<int, CachedControlResponse> _recentHandledCache = {};

  int get nextOutgoingSeq => _outgoingSeq + 1;
  int get expectedNextSeq => _expectedNextSeq;

  /// Computes canonical macInput:
  /// `concat(encode_string("oneshare-e2ee-v2-ctrl"), encode_string(transferId), encode_string(direction), encode_uint64(seq), encode_string(canonicalJsonBody))`
  static Uint8List computeMacInput({
    required String transferId,
    required String direction,
    required int seq,
    required Map<String, dynamic> bodyWithoutCtrl,
  }) {
    final canonicalJson = CanonicalEncoding.canonicalJson(bodyWithoutCtrl);
    return CanonicalEncoding.concat([
      CanonicalEncoding.encodeString('oneshare-e2ee-v2-ctrl'),
      CanonicalEncoding.encodeString(transferId),
      CanonicalEncoding.encodeString(direction),
      CanonicalEncoding.encodeUint64(seq),
      CanonicalEncoding.encodeString(canonicalJson),
    ]);
  }

  /// Computes HMAC-SHA256 for a given control message body.
  Future<Uint8List> computeMac({
    required int seq,
    required Map<String, dynamic> bodyWithoutCtrl,
  }) async {
    final macInput = computeMacInput(
      transferId: transferId,
      direction: direction,
      seq: seq,
      bodyWithoutCtrl: bodyWithoutCtrl,
    );
    final macObj = await _hmacSha256.calculateMac(
      macInput,
      secretKey: ctrlKey,
    );
    return Uint8List.fromList(macObj.bytes);
  }

  /// Creates and attaches authenticated `e2ee_ctrl` to a control payload and increments `_outgoingSeq`.
  Future<Map<String, dynamic>> signControlMessage(Map<String, dynamic> payload) async {
    _outgoingSeq++;
    final currentSeq = _outgoingSeq;

    final bodyCopy = Map<String, dynamic>.from(payload)..remove('e2ee_ctrl');
    final macBytes = await computeMac(
      seq: currentSeq,
      bodyWithoutCtrl: bodyCopy,
    );

    final signed = Map<String, dynamic>.from(bodyCopy);
    signed['e2ee_ctrl'] = {
      'seq': currentSeq,
      'direction': direction,
      'mac': base64Encode(macBytes),
    };
    return signed;
  }

  /// Evaluates an incoming control message against sequencing, HMAC, and the 16-entry idempotent cache.
  Future<ControlMessageEvaluation> evaluateIncomingControlMessage({
    required Map<String, dynamic> fullBody,
  }) async {
    final ctrl = fullBody['e2ee_ctrl'] as Map<String, dynamic>?;
    if (ctrl == null) {
      return ControlMessageEvaluation.invalidMac('Missing e2ee_ctrl authentication block');
    }

    final seq = ctrl['seq'] as int?;
    final incomingDirection = ctrl['direction'] as String?;
    final macBase64 = ctrl['mac'] as String?;

    if (seq == null || incomingDirection == null || macBase64 == null) {
      return ControlMessageEvaluation.invalidMac('Malformed e2ee_ctrl block');
    }

    if (incomingDirection != direction) {
      return ControlMessageEvaluation.invalidMac('Invalid control direction: expected $direction, got $incomingDirection');
    }

    final Uint8List incomingMac;
    try {
      incomingMac = Uint8List.fromList(base64Decode(macBase64));
    } catch (_) {
      return ControlMessageEvaluation.invalidMac('Invalid base64 MAC in control message');
    }

    // 1. Verify HMAC
    final bodyCopy = Map<String, dynamic>.from(fullBody)..remove('e2ee_ctrl');
    final expectedMac = await computeMac(
      seq: seq,
      bodyWithoutCtrl: bodyCopy,
    );

    if (!_constantTimeEquals(incomingMac, expectedMac)) {
      return ControlMessageEvaluation.invalidMac();
    }

    // 2. Check recentHandledCache
    if (_recentHandledCache.containsKey(seq)) {
      final cached = _recentHandledCache[seq]!;
      if (_constantTimeEquals(incomingMac, cached.mac)) {
        return ControlMessageEvaluation.idempotentReplay(cached.response);
      } else {
        return ControlMessageEvaluation.invalidMac();
      }
    }

    // 3. Check sequence progression
    if (seq == _expectedNextSeq) {
      return ControlMessageEvaluation.executeNew();
    } else if (seq < _expectedNextSeq) {
      return ControlMessageEvaluation.duplicateOrExpired();
    } else {
      return ControlMessageEvaluation.sequenceGap();
    }
  }

  /// Records an executed control message's result in the idempotent cache and advances `_expectedNextSeq`.
  void recordSuccess({
    required int seq,
    required Uint8List mac,
    required Map<String, dynamic> response,
  }) {
    if (seq == _expectedNextSeq) {
      _expectedNextSeq = seq + 1;
    }

    _recentHandledCache[seq] = CachedControlResponse(
      mac: mac,
      response: response,
    );

    // Evict oldest if capacity exceeds 16 entries
    if (_recentHandledCache.length > kMaxCacheSize) {
      final oldestKey = _recentHandledCache.keys.first;
      _recentHandledCache.remove(oldestKey);
    }
  }

  /// Constant-time comparison of two byte arrays to prevent timing attacks.
  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
