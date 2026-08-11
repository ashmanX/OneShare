import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:droplan/config/droplan_config.dart';
import 'package:droplan/services/device_identity_service.dart';
import 'package:droplan/services/transfer_service.dart';

class DropLanHttpServer {
  DropLanHttpServer({DeviceIdentity? identity})
      : _identity = identity ?? DeviceIdentityService.identity;

  final DeviceIdentity _identity;
  HttpServer? _server;

  bool get isRunning => _server != null;
  int get port => _server?.port ?? DropLanConfig.port;

  Future<void> start() async {
    if (_server != null) {
      if (kDebugMode) {
        debugPrint(
            '[DropLAN HttpServer] Server already running on port ${_server!.port}');
      }
      return;
    }

    try {
      final server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        DropLanConfig.port,
        shared: true,
      );
      server.idleTimeout = null;

      server.listen(_handleRequest);
      _server = server;
      final localAddress = await _findLocalWifiAddress();
      if (kDebugMode) {
        debugPrint(
            '[DropLAN HttpServer] Server started listening on 0.0.0.0:${server.port} (local Wi-Fi IP: ${localAddress?.address})');
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[DropLAN HttpServer] Failed to start server: $e\n$st');
      }
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
    if (kDebugMode) {
      debugPrint('[DropLAN HttpServer] Server stopped');
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (kDebugMode) {
      debugPrint(
          '[DropLAN Timestamp] ANDROID REQUEST SOCKET/HTTP RECEIVED path=${request.uri.path} time=${DateTime.now().toIso8601String()}');
    }

    try {
      if (request.method == 'GET' &&
          request.uri.path == DropLanConfig.infoPath) {
        await _handleInfo(request);
        return;
      }

      if (request.method == 'POST' &&
          request.uri.path == DropLanConfig.transferRequestPath) {
        if (kDebugMode) {
          debugPrint(
              '[DropLAN Timestamp] ANDROID REQUEST BODY READ START path=${request.uri.path} time=${DateTime.now().toIso8601String()}');
        }
        final jsonBody = await _readJsonBody(request);
        if (kDebugMode) {
          debugPrint(
              '[DropLAN Timestamp] ANDROID REQUEST PARSED transferId=${jsonBody['transferId']} time=${DateTime.now().toIso8601String()}');
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
              '[DropLAN HttpServer] Handshake response (status: $statusCode): $responseJson');
        }

        request.response
          ..statusCode = statusCode
          ..headers.contentType = ContentType.json
          ..write(responseJson);
        await request.response.close();
        return;
      }

      if (request.method == 'POST' &&
          request.uri.path == DropLanConfig.transferAcceptPath) {
        final jsonBody = await _readJsonBody(request);
        if (kDebugMode) {
          debugPrint(
              '[DropLAN HttpServer] Parsed transfer accept JSON body: $jsonBody');
        }
        // BUG-05/06 FIX: handleAcceptResponse returns false when the sender's
        // transfer request has already timed out. In that case, respond with
        // HTTP 410 Gone so the receiver knows the request is stale and can
        // display a proper error rather than being silently stuck.
        final wasLive = TransferService.instance.handleAcceptResponse(jsonBody);
        if (wasLive) {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'status': 'accepted_acknowledged'}));
        } else {
          if (kDebugMode) {
            debugPrint(
                '[DropLAN HttpServer] Transfer accept arrived after sender timeout — responding 410 Gone');
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
          request.uri.path == DropLanConfig.transferRejectPath) {
        final jsonBody = await _readJsonBody(request);
        if (kDebugMode) {
          debugPrint(
              '[DropLAN HttpServer] Parsed transfer reject JSON body: $jsonBody');
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
          request.uri.path == DropLanConfig.transferCancelPath) {
        final jsonBody = await _readJsonBody(request);
        if (kDebugMode) {
          debugPrint(
              '[DropLAN HttpServer] Parsed transfer cancel JSON body: $jsonBody');
        }
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'status': 'cancellation_acknowledged'}));
        await request.response.close();

        final transferId = jsonBody['transferId'] as String?;
        if (transferId != null) {
          await TransferService.instance.handleCancelNotification(transferId);
        }
        return;
      }

      if (request.method == 'POST' &&
          request.uri.path == DropLanConfig.transferFilePath) {
        await TransferService.instance.handleIncomingFileUpload(request);
        return;
      }

      if (kDebugMode) {
        debugPrint(
            '[DropLAN HttpServer] Unrecognized endpoint ${request.method} ${request.uri.path}');
      }
      request.response
        ..statusCode = HttpStatus.notFound
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'error': 'Not found', 'code': 'NOT_FOUND'}));
      await request.response.close();
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint(
            '[DropLAN HttpServer] Error handling request ${request.uri.path}: $e\n$st');
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
            '[DropLAN Timestamp] ANDROID REQUEST BODY READ COMPLETE bytes=${content.length} time=${DateTime.now().toIso8601String()}');
      }
      if (content.isEmpty) return {};
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  Future<void> _handleInfo(HttpRequest request) async {
    final body = jsonEncode({
      'protocolVersion': DropLanConfig.protocolVersion,
      'deviceId': _identity.deviceId,
      'deviceName': _identity.deviceName,
      'appName': DropLanConfig.appName,
      'port': DropLanConfig.port,
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
