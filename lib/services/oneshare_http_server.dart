import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'package:oneshare/config/oneshare_config.dart';
import 'package:oneshare/services/crypto/control_message_channel.dart';
import 'package:oneshare/services/crypto/log_sanitizer.dart';
import 'package:oneshare/services/device_identity_service.dart';
import 'package:oneshare/services/transfer_service.dart';

class _PayloadTooLargeException implements Exception {
  const _PayloadTooLargeException();
}

class _MalformedJsonException implements Exception {
  const _MalformedJsonException();
}

class OneShareHttpServer {
  OneShareHttpServer({DeviceIdentity? identity})
      : _identity = identity ?? DeviceIdentityService.identity;

  static const int kMaxRequestJsonBytes = 65536; // 64 KB
  static const int kMaxAcceptJsonBytes = 16384;  // 16 KB
  static const int kMaxRejectJsonBytes = 4096;   // 4 KB
  static const int kMaxCancelJsonBytes = 4096;   // 4 KB

  final DeviceIdentity _identity;
  HttpServer? _server;

  bool get isRunning => _server != null;
  int get port => _server?.port ?? OneShareConfig.port;

  Future<void> start({int? port}) async {
    if (_server != null) {
      if (kDebugMode) {
        debugPrint(
            '[OneShare HttpServer] Server already running on port ${_server!.port}');
      }
      return;
    }

    try {
      final bindPort = port ?? OneShareConfig.port;
      final server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        bindPort,
        shared: true,
      );
      server.idleTimeout = null;

      server.listen(_handleRequest);
      _server = server;
      final localAddress = await _findLocalWifiAddress();
      if (kDebugMode) {
        debugPrint(
            '[OneShare HttpServer] Server started listening on 0.0.0.0:${server.port} (local Wi-Fi IP: ${localAddress?.address})');
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[OneShare HttpServer] Failed to start server: $e\n$st');
      }
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
    if (kDebugMode) {
      debugPrint('[OneShare HttpServer] Server stopped');
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (kDebugMode) {
      debugPrint(
          '[OneShare Timestamp] ANDROID REQUEST SOCKET/HTTP RECEIVED path=${request.uri.path} time=${DateTime.now().toIso8601String()}');
    }

    try {
      if (request.method == 'GET' &&
          request.uri.path == OneShareConfig.infoPath) {
        await _handleInfo(request);
        return;
      }

      if (request.method == 'POST' &&
          request.uri.path == OneShareConfig.transferRequestPath) {
        if (kDebugMode) {
          debugPrint(
              '[OneShare Timestamp] ANDROID REQUEST BODY READ START path=${request.uri.path} time=${DateTime.now().toIso8601String()}');
        }
        final jsonBody = await _readBoundedJsonBody(
          request,
          maxBytes: kMaxRequestJsonBytes,
        );
        if (kDebugMode) {
          debugPrint(
              '[OneShare Timestamp] ANDROID REQUEST PARSED transferId=${jsonBody['transferId']} time=${DateTime.now().toIso8601String()}');
        }
        final clientIp =
            request.connectionInfo?.remoteAddress.address ?? '127.0.0.1';
        final responseMap = await TransferService.instance
            .handleIncomingRequest(jsonBody, clientIp);

        final statusCode = responseMap['status'] == 'rejected'
            ? (responseMap['code'] == 'IDENTITY_MISMATCH'
                ? HttpStatus.forbidden
                : HttpStatus.conflict)
            : HttpStatus.ok;

        final responseJson = jsonEncode(responseMap);
        if (kDebugMode) {
          debugPrint(
              '[OneShare HttpServer] Handshake response sent (status: $statusCode, transferId: ${LogSanitizer.truncateId(jsonBody['transferId'] as String?)})');
        }

        request.response
          ..statusCode = statusCode
          ..headers.contentType = ContentType.json
          ..write(responseJson);
        await request.response.close();
        return;
      }

      if (request.method == 'POST' &&
          request.uri.path == OneShareConfig.transferAcceptPath) {
        final jsonBody = await _readBoundedJsonBody(
          request,
          maxBytes: kMaxAcceptJsonBytes,
        );
        if (kDebugMode) {
          debugPrint(
              '[OneShare HttpServer] Received transfer accept for transferId: ${LogSanitizer.truncateId(jsonBody['transferId'] as String?)}');
        }
        final wasLive = await TransferService.instance.handleAcceptResponse(jsonBody);
        if (wasLive) {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'status': 'accepted_acknowledged'}));
        } else {
          if (kDebugMode) {
            debugPrint(
                '[OneShare HttpServer] Transfer accept arrived after sender timeout — responding 410 Gone');
          }
          request.response
            ..statusCode = HttpStatus.gone
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({
              'status': 'expired',
              'error': 'Sender is no longer waiting',
              'code': 'REQUEST_EXPIRED',
            }));
        }
        await request.response.close();
        return;
      }

      if (request.method == 'POST' &&
          request.uri.path == OneShareConfig.transferRejectPath) {
        final jsonBody = await _readBoundedJsonBody(
          request,
          maxBytes: kMaxRejectJsonBytes,
        );
        if (kDebugMode) {
          debugPrint(
              '[OneShare HttpServer] Received transfer reject for transferId: ${LogSanitizer.truncateId(jsonBody['transferId'] as String?)}');
        }
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'status': 'rejection_acknowledged'}));
        await request.response.close();

        TransferService.instance.handleRejectResponse(jsonBody);
        return;
      }

      if (request.method == 'POST' &&
          request.uri.path == OneShareConfig.transferCancelPath) {
        final jsonBody = await _readBoundedJsonBody(
          request,
          maxBytes: kMaxCancelJsonBytes,
        );
        if (kDebugMode) {
          debugPrint(
              '[OneShare HttpServer] Received transfer cancel for transferId: ${LogSanitizer.truncateId(jsonBody['transferId'] as String?)}');
        }

        final transferId = jsonBody['transferId'] as String?;
        if (transferId == null || transferId.isEmpty) {
          request.response
            ..statusCode = HttpStatus.badRequest
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({
              'error': 'Missing transferId',
              'code': 'MISSING_TRANSFER_ID',
            }));
          await request.response.close();
          return;
        }

        // Unknown transfer check: reject unknown transfer IDs without side effects
        if (!TransferService.instance.isKnownTransfer(transferId)) {
          request.response
            ..statusCode = HttpStatus.notFound
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({
              'error': 'Transfer not found: $transferId',
              'code': 'TRANSFER_NOT_FOUND',
            }));
          await request.response.close();
          return;
        }

        final session = TransferService.instance.getSession(transferId);
        final hasCompletedHandshake =
            TransferService.instance.hasCompletedHandshake(transferId);

        // Strict Post-Handshake Rule:
        // Any transfer that completed handshake requires valid e2ee_ctrl authentication.
        if (hasCompletedHandshake || (session != null && session.incomingCtrlChannel != null)) {
          if (!jsonBody.containsKey('e2ee_ctrl')) {
            request.response
              ..statusCode = HttpStatus.unauthorized
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({
                'error': 'Missing control authentication on post-handshake transfer',
                'code': 'MISSING_CONTROL_AUTH',
              }));
            await request.response.close();
            return;
          }

          if (session == null || session.incomingCtrlChannel == null) {
            // Session has been destroyed/cleaned up already after handshake
            // Still require authentication, cannot re-execute on dead session
            request.response
              ..statusCode = HttpStatus.conflict
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({
                'error': 'Session already terminated',
                'code': 'DUPLICATE_OR_EXPIRED_SEQUENCE',
              }));
            await request.response.close();
            return;
          }

          try {
            final eval = await TransferService.instance.handleAuthenticatedCancelNotification(
              transferId: transferId,
              fullBody: jsonBody,
            );

            if (eval.status == ControlEvaluationStatus.error) {
              request.response
                ..statusCode = eval.statusCode
                ..headers.contentType = ContentType.json
                ..write(jsonEncode({
                  'error': eval.errorMessage,
                  'code': eval.errorCode,
                }));
              await request.response.close();
              return;
            }

            request.response
              ..statusCode = HttpStatus.ok
              ..headers.contentType = ContentType.json
              ..write(jsonEncode(eval.cachedResponse ?? {'status': 'cancellation_acknowledged'}));
            await request.response.close();
            return;
          } catch (e) {
            if (kDebugMode) {
              debugPrint('[OneShare HttpServer] Error executing authenticated cancel: $e');
            }
            request.response
              ..statusCode = HttpStatus.internalServerError
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({
                'error': 'Internal error processing cancellation',
                'code': 'CONTROL_EXECUTION_FAILED',
              }));
            await request.response.close();
            return;
          }
        }

        // Pre-handshake cancel (only for known pre-handshake transfers)
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'status': 'cancellation_acknowledged'}));
        await request.response.close();

        await TransferService.instance.handleCancelNotification(transferId);
        return;
      }

      if (request.method == 'POST' &&
          request.uri.path == OneShareConfig.transferCancelFilePath) {
        final jsonBody = await _readBoundedJsonBody(
          request,
          maxBytes: kMaxCancelJsonBytes,
        );
        if (kDebugMode) {
          debugPrint(
              '[OneShare HttpServer] Parsed transfer file cancel JSON body: $jsonBody');
        }

        final transferId = jsonBody['transferId'] as String?;
        final fileId = jsonBody['fileId'] as String?;
        if (transferId == null || transferId.isEmpty || fileId == null || fileId.isEmpty) {
          request.response
            ..statusCode = HttpStatus.badRequest
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({
              'error': 'Missing transferId or fileId',
              'code': 'MISSING_TRANSFER_OR_FILE_ID',
            }));
          await request.response.close();
          return;
        }

        // Unknown transfer check
        if (!TransferService.instance.isKnownTransfer(transferId)) {
          request.response
            ..statusCode = HttpStatus.notFound
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({
              'error': 'Transfer not found: $transferId',
              'code': 'TRANSFER_NOT_FOUND',
            }));
          await request.response.close();
          return;
        }

        final session = TransferService.instance.getSession(transferId);
        final hasCompletedHandshake =
            TransferService.instance.hasCompletedHandshake(transferId);

        if (hasCompletedHandshake || (session != null && session.incomingCtrlChannel != null)) {
          if (!jsonBody.containsKey('e2ee_ctrl')) {
            request.response
              ..statusCode = HttpStatus.unauthorized
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({
                'error': 'Missing control authentication on post-handshake file cancellation',
                'code': 'MISSING_CONTROL_AUTH',
              }));
            await request.response.close();
            return;
          }

          if (session == null || session.incomingCtrlChannel == null) {
            request.response
              ..statusCode = HttpStatus.conflict
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({
                'error': 'Session already terminated',
                'code': 'DUPLICATE_OR_EXPIRED_SEQUENCE',
              }));
            await request.response.close();
            return;
          }

          try {
            final eval = await TransferService.instance.handleAuthenticatedCancelFileNotification(
              transferId: transferId,
              fileId: fileId,
              fullBody: jsonBody,
            );

            if (eval.status == ControlEvaluationStatus.error) {
              request.response
                ..statusCode = eval.statusCode
                ..headers.contentType = ContentType.json
                ..write(jsonEncode({
                  'error': eval.errorMessage,
                  'code': eval.errorCode,
                }));
              await request.response.close();
              return;
            }

            request.response
              ..statusCode = HttpStatus.ok
              ..headers.contentType = ContentType.json
              ..write(jsonEncode(eval.cachedResponse ?? {'status': 'file_cancellation_acknowledged'}));
            await request.response.close();
            return;
          } catch (e) {
            if (kDebugMode) {
              debugPrint('[OneShare HttpServer] Error executing authenticated cancel-file: $e');
            }
            request.response
              ..statusCode = HttpStatus.internalServerError
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({
                'error': 'Internal error processing file cancellation',
                'code': 'CONTROL_EXECUTION_FAILED',
              }));
            await request.response.close();
            return;
          }
        }

        // Pre-handshake or non-E2EE file cancel
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'status': 'file_cancellation_acknowledged'}));
        await request.response.close();

        await TransferService.instance.handleCancelFileNotification(transferId, fileId);
        return;
      }

      if (request.method == 'POST' &&
          request.uri.path == OneShareConfig.transferFilePath) {
        await TransferService.instance.handleIncomingFileUpload(request);
        return;
      }

      if (kDebugMode) {
        debugPrint(
            '[OneShare HttpServer] Unrecognized endpoint ${request.method} ${request.uri.path}');
      }
      request.response
        ..statusCode = HttpStatus.notFound
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'error': 'Not found', 'code': 'NOT_FOUND'}));
      await request.response.close();
    } on _PayloadTooLargeException catch (_) {
      await _sendHttpError(
        request,
        HttpStatus.requestEntityTooLarge,
        'Payload exceeds maximum allowed size',
        'PAYLOAD_TOO_LARGE',
      );
    } on _MalformedJsonException catch (_) {
      await _sendHttpError(
        request,
        HttpStatus.badRequest,
        'Malformed or non-object JSON body',
        'MALFORMED_JSON',
      );
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint(
            '[OneShare HttpServer] Error handling request ${request.uri.path}: $e\n$st');
      }
      if (!request.response.headers.chunkedTransferEncoding) {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      }
    }
  }

  Future<Map<String, dynamic>> _readBoundedJsonBody(
    HttpRequest request, {
    required int maxBytes,
  }) async {
    final builder = BytesBuilder(copy: false);
    int totalBytes = 0;

    await for (final chunk in request) {
      totalBytes += chunk.length;
      if (totalBytes > maxBytes) {
        throw const _PayloadTooLargeException();
      }
      builder.add(chunk);
    }

    final bytes = builder.takeBytes();
    if (kDebugMode) {
      debugPrint(
          '[OneShare Timestamp] ANDROID REQUEST BODY READ COMPLETE bytes=${bytes.length} time=${DateTime.now().toIso8601String()}');
    }

    if (bytes.isEmpty) return {};

    final String content;
    try {
      content = utf8.decode(bytes);
    } catch (_) {
      throw const _MalformedJsonException();
    }

    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) {
        throw const _MalformedJsonException();
      }
      return decoded;
    } catch (e) {
      if (e is _MalformedJsonException) rethrow;
      throw const _MalformedJsonException();
    }
  }

  Future<void> _sendHttpError(
    HttpRequest request,
    int statusCode,
    String message,
    String code,
  ) async {
    request.response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({
        'error': message,
        'code': code,
      }));
    await request.response.close();
  }

  Future<void> _handleInfo(HttpRequest request) async {
    final body = jsonEncode({
      'protocolVersion': OneShareConfig.protocolVersion,
      'deviceId': _identity.deviceId,
      'deviceName': _identity.deviceName,
      'appName': OneShareConfig.appName,
      'port': OneShareConfig.port,
    });

    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(body);
    await request.response.close();
  }

  Future<InternetAddress?> _findLocalWifiAddress() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: false,
    );

    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (address.isLoopback) {
          continue;
        }
        if (_isPrivateAddress(address)) {
          return address;
        }
      }
    }

    return null;
  }

  bool _isPrivateAddress(InternetAddress address) {
    final parts = address.address.split('.');
    if (parts.length != 4) {
      return false;
    }

    final octets = parts.map(int.parse).toList();
    if (octets[0] == 10) {
      return true;
    }
    if (octets[0] == 192 && octets[1] == 168) {
      return true;
    }
    if (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) {
      return true;
    }

    return false;
  }
}
