import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:oneshare/config/oneshare_config.dart';
import 'package:oneshare/services/crypto/control_message_channel.dart';
import 'package:oneshare/services/device_identity_service.dart';
import 'package:oneshare/services/transfer_service.dart';

class OneShareHttpServer {
  OneShareHttpServer({DeviceIdentity? identity})
      : _identity = identity ?? DeviceIdentityService.identity;

  final DeviceIdentity _identity;
  HttpServer? _server;

  bool get isRunning => _server != null;
  int get port => _server?.port ?? OneShareConfig.port;

  Future<void> start() async {
    if (_server != null) {
      if (kDebugMode) {
        debugPrint(
            '[OneShare HttpServer] Server already running on port ${_server!.port}');
      }
      return;
    }

    try {
      final server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        OneShareConfig.port,
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
        final jsonBody = await _readJsonBody(request);
        if (kDebugMode) {
          debugPrint(
              '[OneShare Timestamp] ANDROID REQUEST PARSED transferId=${jsonBody['transferId']} time=${DateTime.now().toIso8601String()}');
        }
        final clientIp =
            request.connectionInfo?.remoteAddress.address ?? '127.0.0.1';
        final responseMap = await TransferService.instance
            .handleIncomingRequest(jsonBody, clientIp);

        final statusCode = responseMap['status'] == 'rejected'
            ? HttpStatus.conflict
            : HttpStatus.ok;

        final responseJson = jsonEncode(responseMap);
        if (kDebugMode) {
          debugPrint(
              '[OneShare HttpServer] Handshake response (status: $statusCode): $responseJson');
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
        final jsonBody = await _readJsonBody(request);
        if (kDebugMode) {
          debugPrint(
              '[OneShare HttpServer] Parsed transfer accept JSON body: $jsonBody');
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
        final jsonBody = await _readJsonBody(request);
        if (kDebugMode) {
          debugPrint(
              '[OneShare HttpServer] Parsed transfer reject JSON body: $jsonBody');
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
        final jsonBody = await _readJsonBody(request);
        if (kDebugMode) {
          debugPrint(
              '[OneShare HttpServer] Parsed transfer cancel JSON body: $jsonBody');
        }

        final transferId = jsonBody['transferId'] as String?;
        if (transferId == null) {
          request.response
            ..statusCode = HttpStatus.badRequest
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'error': 'Missing transferId'}));
          await request.response.close();
          return;
        }

        final session = TransferService.instance.getSession(transferId);
        if (session != null && session.incomingCtrlChannel != null) {
          final eval = await session.incomingCtrlChannel!.evaluateIncomingControlMessage(
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

          if (eval.status == ControlEvaluationStatus.idempotentReplay) {
            request.response
              ..statusCode = HttpStatus.ok
              ..headers.contentType = ContentType.json
              ..write(jsonEncode(eval.cachedResponse!));
            await request.response.close();
            return;
          }

          // Execute new authenticated cancellation
          final responsePayload = {'status': 'cancellation_acknowledged'};
          final ctrl = jsonBody['e2ee_ctrl'] as Map<String, dynamic>;
          final seq = ctrl['seq'] as int;
          final macBytes = base64Decode(ctrl['mac'] as String);
          session.incomingCtrlChannel!.recordSuccess(
            seq: seq,
            mac: Uint8List.fromList(macBytes),
            response: responsePayload,
          );

          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(responsePayload));
          await request.response.close();

          await TransferService.instance.handleCancelNotification(transferId);
          return;
        }

        // Pre-handshake or non-E2EE cancel
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
        final jsonBody = await _readJsonBody(request);
        if (kDebugMode) {
          debugPrint(
              '[OneShare HttpServer] Parsed transfer file cancel JSON body: $jsonBody');
        }

        final transferId = jsonBody['transferId'] as String?;
        final fileId = jsonBody['fileId'] as String?;
        if (transferId == null || fileId == null) {
          request.response
            ..statusCode = HttpStatus.badRequest
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'error': 'Missing transferId or fileId'}));
          await request.response.close();
          return;
        }

        final session = TransferService.instance.getSession(transferId);
        if (session != null && session.incomingCtrlChannel != null) {
          final eval = await session.incomingCtrlChannel!.evaluateIncomingControlMessage(
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

          if (eval.status == ControlEvaluationStatus.idempotentReplay) {
            request.response
              ..statusCode = HttpStatus.ok
              ..headers.contentType = ContentType.json
              ..write(jsonEncode(eval.cachedResponse!));
            await request.response.close();
            return;
          }

          // Execute new authenticated file cancellation
          final responsePayload = {'status': 'file_cancellation_acknowledged'};
          final ctrl = jsonBody['e2ee_ctrl'] as Map<String, dynamic>;
          final seq = ctrl['seq'] as int;
          final macBytes = base64Decode(ctrl['mac'] as String);
          session.incomingCtrlChannel!.recordSuccess(
            seq: seq,
            mac: Uint8List.fromList(macBytes),
            response: responsePayload,
          );

          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(responsePayload));
          await request.response.close();

          await TransferService.instance.handleCancelFileNotification(transferId, fileId);
          return;
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

  Future<Map<String, dynamic>> _readJsonBody(HttpRequest request) async {
    try {
      final content = await utf8.decoder.bind(request).join();
      if (kDebugMode) {
        debugPrint(
            '[OneShare Timestamp] ANDROID REQUEST BODY READ COMPLETE bytes=${content.length} time=${DateTime.now().toIso8601String()}');
      }
      if (content.isEmpty) return {};
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
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
