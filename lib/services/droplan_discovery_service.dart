import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:droplan/config/droplan_config.dart';
import 'package:droplan/services/device_identity_service.dart';

class DiscoveredDevice {
  const DiscoveredDevice({
    required this.deviceId,
    required this.deviceName,
    required this.host,
    required this.port,
    required this.lastSeen,
  });

  final String deviceId;
  final String deviceName;
  final String host;
  final int port;
  final DateTime lastSeen;

  DiscoveredDevice copyWith({
    String? deviceName,
    String? host,
    int? port,
    DateTime? lastSeen,
  }) {
    return DiscoveredDevice(
      deviceId: deviceId,
      deviceName: deviceName ?? this.deviceName,
      host: host ?? this.host,
      port: port ?? this.port,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }
}

class DropLanDiscoveryService {
  static const MethodChannel _controlChannel =
      MethodChannel('com.example.droplan/nsd_control');
  static const EventChannel _eventChannel =
      EventChannel('com.example.droplan/nsd_events');

  StreamSubscription? _eventSubscription;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3);

  final ValueNotifier<List<DiscoveredDevice>> discoveredDevicesNotifier =
      ValueNotifier([]);
  final Map<String, DiscoveredDevice> _discoveredDevices = {};

  Future<void> startAdvertising(String deviceName, int port) async {
    if (!Platform.isAndroid) return;
    try {
      await _controlChannel.invokeMethod('startAdvertising', {
        'deviceName': deviceName,
        'port': port,
      });
    } catch (_) {}
  }

  Future<void> stopAdvertising() async {
    if (!Platform.isAndroid) return;
    try {
      await _controlChannel.invokeMethod('stopAdvertising');
    } catch (_) {}
  }

  Future<void> startDiscovery() async {
    if (!Platform.isAndroid) return;
    _eventSubscription ??=
        _eventChannel.receiveBroadcastStream().listen(_handleEvent);
    try {
      await _controlChannel.invokeMethod('startDiscovery');
    } catch (_) {}
  }

  Future<void> stopDiscovery() async {
    if (!Platform.isAndroid) return;
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    try {
      await _controlChannel.invokeMethod('stopDiscovery');
    } catch (_) {}
  }

  void clearDiscoveredDevices() {
    _discoveredDevices.clear();
    discoveredDevicesNotifier.value = [];
  }

  Future<void> _handleEvent(dynamic event) async {
    if (event is! Map) return;

    final eventType = event['event'] as String?;
    if (eventType == 'resolved') {
      final host = event['host'] as String?;
      final port = event['port'] as int?;
      if (host == null || port == null) return;

      final verifiedDevice = await _verifyAndGetDeviceInfo(host, port);
      if (verifiedDevice == null) return;

      final selfId = DeviceIdentityService.identity.deviceId;
      if (verifiedDevice.deviceId == selfId) {
        // Ignore self loopback
        return;
      }

      // Authoritative peer keying by deviceId
      _discoveredDevices[verifiedDevice.deviceId] = verifiedDevice;
      discoveredDevicesNotifier.value = _discoveredDevices.values.toList();
    } else if (eventType == 'lost') {
      final serviceName = event['serviceName'] as String?;
      if (serviceName != null) {
        _discoveredDevices.removeWhere(
          (_, device) => device.deviceName == serviceName,
        );
        discoveredDevicesNotifier.value = _discoveredDevices.values.toList();
      }
    }
  }

  Future<DiscoveredDevice?> _verifyAndGetDeviceInfo(
      String host, int port) async {
    try {
      final uri = Uri.http('$host:$port', DropLanConfig.infoPath);
      final request = await _client.getUrl(uri);
      final response =
          await request.close().timeout(const Duration(seconds: 3));

      if (response.statusCode != HttpStatus.ok) return null;

      final responseBody = await response.transform(utf8.decoder).join();
      final json = jsonDecode(responseBody) as Map<String, dynamic>;

      if (json['appName'] != DropLanConfig.appName ||
          json['protocolVersion'] != DropLanConfig.protocolVersion) {
        return null;
      }

      final deviceId = json['deviceId'] as String?;
      final deviceName = json['deviceName'] as String?;

      if (deviceId == null ||
          deviceId.isEmpty ||
          deviceName == null ||
          deviceName.isEmpty) {
        return null;
      }

      return DiscoveredDevice(
        deviceId: deviceId,
        deviceName: deviceName,
        host: host,
        port: port,
        lastSeen: DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }
}
