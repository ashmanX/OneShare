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

  bool _isAdvertising = false;
  bool _isDiscovering = false;
  String? _lastAdvertisedName;
  int? _lastAdvertisedPort;

  bool get isAdvertising => _isAdvertising;
  bool get isDiscovering => _isDiscovering;

  Future<void> startAdvertising(String deviceName, int port,
      {bool isResume = false}) async {
    if (!Platform.isAndroid && !Platform.isMacOS) {
      return;
    }

    if (_isAdvertising &&
        _lastAdvertisedName == deviceName &&
        _lastAdvertisedPort == port &&
        !isResume) {
      return;
    }

    _lastAdvertisedName = deviceName;
    _lastAdvertisedPort = port;

    try {
      await _controlChannel.invokeMethod('startAdvertising', {
        'deviceName': deviceName,
        'port': port,
      });
      _isAdvertising = true;
      if (kDebugMode) {
        if (isResume) {
          debugPrint(
              '[DropLAN Timestamp] ANDROID advertising: restarted after resume (name=$deviceName, port=$port)');
        } else {
          debugPrint(
              '[DropLAN Timestamp] ANDROID advertising: started (name=$deviceName, port=$port)');
        }
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('DropLAN discovery: startAdvertising failed: $error');
      }
    }
  }

  Future<void> stopAdvertising() async {
    if (!Platform.isAndroid && !Platform.isMacOS) {
      return;
    }

    try {
      await _controlChannel.invokeMethod('stopAdvertising');
      _isAdvertising = false;
      if (kDebugMode &&
          _lastAdvertisedName != null &&
          _lastAdvertisedPort != null) {
        debugPrint(
            '[DropLAN Timestamp] ANDROID advertising: stopped (name=$_lastAdvertisedName, port=$_lastAdvertisedPort)');
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('DropLAN discovery: stopAdvertising failed: $error');
      }
    }
  }

  Future<void> startDiscovery() async {
    if (!Platform.isAndroid && !Platform.isMacOS) {
      return;
    }

    if (_isDiscovering) {
      return;
    }

    _eventSubscription ??=
        _eventChannel.receiveBroadcastStream().listen(_handleEvent);

    try {
      await _controlChannel.invokeMethod('startDiscovery');
      _isDiscovering = true;
      if (kDebugMode) {
        debugPrint('[DropLAN Timestamp] ANDROID discovery: started');
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('DropLAN discovery: startDiscovery failed: $error');
      }
    }
  }

  Future<void> stopDiscovery() async {
    if (!Platform.isAndroid && !Platform.isMacOS) {
      return;
    }

    await _eventSubscription?.cancel();
    _eventSubscription = null;

    try {
      await _controlChannel.invokeMethod('stopDiscovery');
      _isDiscovering = false;
      if (kDebugMode) {
        debugPrint('[DropLAN Timestamp] ANDROID discovery: stopped');
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('DropLAN discovery: stopDiscovery failed: $error');
      }
    }
  }

  void clearDiscoveredDevices() {
    _discoveredDevices.clear();
    discoveredDevicesNotifier.value = [];
  }

  Future<void> _handleEvent(dynamic event) async {
    if (event is! Map) {
      if (kDebugMode) debugPrint('DropLAN discovery: invalid event: $event');
      return;
    }

    final eventType = event['event'] as String?;

    if (kDebugMode) debugPrint('DropLAN discovery: received event $event');

    if (eventType == 'resolved') {
      final host = event['host'] as String?;
      final port = event['port'] as int?;

      if (host == null || port == null) {
        if (kDebugMode) {
          debugPrint(
            'DropLAN discovery: invalid resolved event: $event',
          );
        }
        return;
      }

      if (kDebugMode) {
        debugPrint(
          'DropLAN discovery: resolved $host:$port',
        );
      }

      final verifiedDevice =
          await _verifyAndGetDeviceInfo(host, port);

      if (verifiedDevice == null) {
        if (kDebugMode) {
          debugPrint(
            'DropLAN discovery: verification FAILED '
            'for $host:$port',
          );
        }
        return;
      }

      if (kDebugMode) {
        debugPrint(
          'DropLAN discovery: verified '
          '${verifiedDevice.deviceName} '
          '${verifiedDevice.deviceId}',
        );
      }

      final selfId = DeviceIdentityService.identity.deviceId;

      if (verifiedDevice.deviceId == selfId) {
        if (kDebugMode) {
          debugPrint(
            'DropLAN discovery: ignoring self '
            '${verifiedDevice.deviceId}',
          );
        }
        return;
      }

      _discoveredDevices[verifiedDevice.deviceId] =
          verifiedDevice;

      if (kDebugMode) {
        debugPrint(
          'DropLAN discovery: adding '
          '${verifiedDevice.deviceName}',
        );
      }

      discoveredDevicesNotifier.value =
          _discoveredDevices.values.toList();

      if (kDebugMode) {
        debugPrint(
          'DropLAN discovery: total devices = '
          '${discoveredDevicesNotifier.value.length}',
        );
      }
    } else if (eventType == 'lost') {
      final serviceName = event['serviceName'] as String?;

      if (serviceName != null) {
        if (kDebugMode) {
          debugPrint(
            'DropLAN discovery: service lost $serviceName',
          );
        }

        _discoveredDevices.removeWhere(
          (_, device) => device.deviceName == serviceName,
        );

        discoveredDevicesNotifier.value =
            _discoveredDevices.values.toList();

        if (kDebugMode) {
          debugPrint(
            'DropLAN discovery: total devices = '
            '${discoveredDevicesNotifier.value.length}',
          );
        }
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

      if (kDebugMode) {
        debugPrint(
          'DropLAN discovery: requesting $uri',
        );
      }

      final request = await _client.getUrl(uri);

      final response =
          await request.close().timeout(
                const Duration(seconds: 3),
              );

      if (kDebugMode) {
        debugPrint(
          'DropLAN discovery: /info status '
          '${response.statusCode}',
        );
      }

      if (response.statusCode != HttpStatus.ok) {
        return null;
      }

      final responseBody =
          await response.transform(utf8.decoder).join();

      if (kDebugMode) {
        debugPrint(
          'DropLAN discovery: /info response '
          '$responseBody',
        );
      }

      final json =
          jsonDecode(responseBody) as Map<String, dynamic>;

      if (json['appName'] != DropLanConfig.appName ||
          json['protocolVersion'] !=
              DropLanConfig.protocolVersion) {
        if (kDebugMode) {
          debugPrint(
            'DropLAN discovery: metadata mismatch '
            'appName=${json['appName']} '
            'protocolVersion=${json['protocolVersion']}',
          );
        }
        return null;
      }

      final deviceId = json['deviceId'] as String?;
      final deviceName = json['deviceName'] as String?;

      if (deviceId == null ||
          deviceId.isEmpty ||
          deviceName == null ||
          deviceName.isEmpty) {
        if (kDebugMode) {
          debugPrint(
            'DropLAN discovery: missing deviceId/deviceName',
          );
        }
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
      if (kDebugMode) {
        debugPrint(
          'DropLAN discovery: verification exception '
          '$host:$port -> $error',
        );
      }
      return null;
    }
  }
}