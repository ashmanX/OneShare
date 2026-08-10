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
      ValueNotifier<List<DiscoveredDevice>>([]);

  final Map<String, DiscoveredDevice> _discoveredDevices = {};

  Future startAdvertising(String deviceName, int port) async {
    if (!Platform.isAndroid && !Platform.isMacOS) {
      return;
    }

    try {
      await _controlChannel.invokeMethod('startAdvertising', {
        'deviceName': deviceName,
        'port': port,
      });
    } catch (error) {
      print('DropLAN discovery: startAdvertising failed: $error');
    }
  }

  Future stopAdvertising() async {
    if (!Platform.isAndroid && !Platform.isMacOS) {
      return;
    }

    try {
      await _controlChannel.invokeMethod('stopAdvertising');
    } catch (error) {
      print('DropLAN discovery: stopAdvertising failed: $error');
    }
  }

  Future startDiscovery() async {
    if (!Platform.isAndroid && !Platform.isMacOS) {
      return;
    }

    _eventSubscription ??=
        _eventChannel.receiveBroadcastStream().listen(_handleEvent);

    try {
      await _controlChannel.invokeMethod('startDiscovery');
    } catch (error) {
      print('DropLAN discovery: startDiscovery failed: $error');
    }
  }

  Future stopDiscovery() async {
    if (!Platform.isAndroid && !Platform.isMacOS) {
      return;
    }

    await _eventSubscription?.cancel();
    _eventSubscription = null;

    try {
      await _controlChannel.invokeMethod('stopDiscovery');
    } catch (error) {
      print('DropLAN discovery: stopDiscovery failed: $error');
    }
  }

  void clearDiscoveredDevices() {
    _discoveredDevices.clear();
    discoveredDevicesNotifier.value = [];
  }

  Future<void> _handleEvent(dynamic event) async {
    if (event is! Map) {
      print('DropLAN discovery: invalid event: $event');
      return;
    }

    final eventType = event['event'] as String?;

    print('DropLAN discovery: received event $event');

    if (eventType == 'resolved') {
      final host = event['host'] as String?;
      final port = event['port'] as int?;

      if (host == null || port == null) {
        print(
          'DropLAN discovery: invalid resolved event: $event',
        );
        return;
      }

      print(
        'DropLAN discovery: resolved $host:$port',
      );

      final verifiedDevice =
          await _verifyAndGetDeviceInfo(host, port);

      if (verifiedDevice == null) {
        print(
          'DropLAN discovery: verification FAILED '
          'for $host:$port',
        );
        return;
      }

      print(
        'DropLAN discovery: verified '
        '${verifiedDevice.deviceName} '
        '${verifiedDevice.deviceId}',
      );

      final selfId = DeviceIdentityService.identity.deviceId;

      if (verifiedDevice.deviceId == selfId) {
        print(
          'DropLAN discovery: ignoring self '
          '${verifiedDevice.deviceId}',
        );
        return;
      }

      _discoveredDevices[verifiedDevice.deviceId] =
          verifiedDevice;

      print(
        'DropLAN discovery: adding '
        '${verifiedDevice.deviceName}',
      );

      discoveredDevicesNotifier.value =
          _discoveredDevices.values.toList();

      print(
        'DropLAN discovery: total devices = '
        '${discoveredDevicesNotifier.value.length}',
      );
    } else if (eventType == 'lost') {
      final serviceName = event['serviceName'] as String?;

      if (serviceName != null) {
        print(
          'DropLAN discovery: service lost $serviceName',
        );

        _discoveredDevices.removeWhere(
          (_, device) => device.deviceName == serviceName,
        );

        discoveredDevicesNotifier.value =
            _discoveredDevices.values.toList();

        print(
          'DropLAN discovery: total devices = '
          '${discoveredDevicesNotifier.value.length}',
        );
      }
    }
  }

  Future<DiscoveredDevice?> _verifyAndGetDeviceInfo(
    String host,
    int port,
  ) async {
    try {
      final uri = Uri.http(
        '$host:$port',
        DropLanConfig.infoPath,
      );

      print(
        'DropLAN discovery: requesting $uri',
      );

      final request = await _client.getUrl(uri);

      final response =
          await request.close().timeout(
                const Duration(seconds: 3),
              );

      print(
        'DropLAN discovery: /info status '
        '${response.statusCode}',
      );

      if (response.statusCode != HttpStatus.ok) {
        return null;
      }

      final responseBody =
          await response.transform(utf8.decoder).join();

      print(
        'DropLAN discovery: /info response '
        '$responseBody',
      );

      final json =
          jsonDecode(responseBody) as Map<String, dynamic>;

      if (json['appName'] != DropLanConfig.appName ||
          json['protocolVersion'] !=
              DropLanConfig.protocolVersion) {
        print(
          'DropLAN discovery: metadata mismatch '
          'appName=${json['appName']} '
          'protocolVersion=${json['protocolVersion']}',
        );
        return null;
      }

      final deviceId = json['deviceId'] as String?;
      final deviceName = json['deviceName'] as String?;

      if (deviceId == null ||
          deviceId.isEmpty ||
          deviceName == null ||
          deviceName.isEmpty) {
        print(
          'DropLAN discovery: missing deviceId/deviceName',
        );
        return null;
      }

      return DiscoveredDevice(
        deviceId: deviceId,
        deviceName: deviceName,
        host: host,
        port: port,
        lastSeen: DateTime.now(),
      );
    } catch (error) {
      print(
        'DropLAN discovery: verification exception '
        '$host:$port -> $error',
      );
      return null;
    }
  }
}