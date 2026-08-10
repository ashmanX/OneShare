import 'dart:convert';
import 'dart:io';

import 'package:droplan/config/droplan_config.dart';
import 'package:droplan/services/device_identity_service.dart';
import 'package:droplan/services/transfer_service.dart';

class DropLanHttpServer {
  DropLanHttpServer({DeviceIdentity? identity})
      : _identity = identity ?? DeviceIdentityService.identity;

  final DeviceIdentity _identity;
  HttpServer? _server;

  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) {
      return;
    }

    final localAddress = await _findLocalWifiAddress();
    if (localAddress == null) {
      return;
    }

    final server = await HttpServer.bind(
      localAddress,
      DropLanConfig.port,
      shared: true,
    );

    server.listen(_handleRequest);
    _server = server;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.method == 'GET' &&
          request.uri.path == DropLanConfig.infoPath) {
        await _handleInfo(request);
        return;
      }

      if (request.method == 'POST' &&
          request.uri.path == DropLanConfig.transferRequestPath) {
        final jsonBody = await _readJsonBody(request);
        final clientIp =
            request.connectionInfo?.remoteAddress.address ?? '127.0.0.1';
        final responseMap = await TransferService.instance
            .handleIncomingRequest(jsonBody, clientIp);

        final statusCode = responseMap['status'] == 'rejected'
            ? HttpStatus.conflict
            : HttpStatus.ok;

        request.response
          ..statusCode = statusCode
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(responseMap));
        await request.response.close();
        return;
      }

      if (request.method == 'POST' &&
          request.uri.path == DropLanConfig.transferAcceptPath) {
        final jsonBody = await _readJsonBody(request);
        TransferService.instance.handleAcceptResponse(jsonBody);

        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'status': 'accepted_acknowledged'}));
        await request.response.close();
        return;
      }

      if (request.method == 'POST' &&
          request.uri.path == DropLanConfig.transferRejectPath) {
        final jsonBody = await _readJsonBody(request);
        TransferService.instance.handleRejectResponse(jsonBody);

        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'status': 'rejection_acknowledged'}));
        await request.response.close();
        return;
      }

      if (request.method == 'POST' &&
          request.uri.path == DropLanConfig.transferFilePath) {
        await TransferService.instance.handleIncomingFileUpload(request);
        return;
      }

      request.response
        ..statusCode = HttpStatus.notFound
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'error': 'Not found', 'code': 'NOT_FOUND'}));
      await request.response.close();
    } catch (_) {
      if (!request.response.headers.chunkedTransferEncoding) {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      }
    }
  }

  Future<Map<String, dynamic>> _readJsonBody(HttpRequest request) async {
    try {
      final content = await utf8.decoder.bind(request).join();
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
