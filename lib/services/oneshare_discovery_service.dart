import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:oneshare/config/oneshare_config.dart';
import 'package:oneshare/services/device_identity_service.dart';

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

class OneShareDiscoveryService {
  static const MethodChannel _controlChannel =
      MethodChannel('com.example.oneshare/nsd_control');

  static const EventChannel _eventChannel =
      EventChannel('com.example.oneshare/nsd_events');

  StreamSubscription? _eventSubscription;

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3);

  final ValueNotifier<List<DiscoveredDevice>> discoveredDevicesNotifier =
      ValueNotifier<List<DiscoveredDevice>>([]);

  final Map<String, DiscoveredDevice> _discoveredDevices = {};

  final Map<String, String> _serviceNameToDeviceId = {};

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
              '[OneShare Timestamp] ANDROID advertising: restarted after resume (name=$deviceName, port=$port)');
        } else {
          debugPrint(
              '[OneShare Timestamp] ANDROID advertising: started (name=$deviceName, port=$port)');
        }
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('OneShare discovery: startAdvertising failed: $error');
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
            '[OneShare Timestamp] ANDROID advertising: stopped (name=$_lastAdvertisedName, port=$_lastAdvertisedPort)');
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('OneShare discovery: stopAdvertising failed: $error');
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
        debugPrint('[OneShare Timestamp] ANDROID discovery: started');
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('OneShare discovery: startDiscovery failed: $error');
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
        debugPrint('[OneShare Timestamp] ANDROID discovery: stopped');
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('OneShare discovery: stopDiscovery failed: $error');
      }
    }
  }

  void clearDiscoveredDevices() {
    _discoveredDevices.clear();
    discoveredDevicesNotifier.value = [];
  }

  Future<void> _handleEvent(dynamic event) async {
    if (event is! Map) {
      if (kDebugMode) debugPrint('OneShare discovery: invalid event: $event');
      return;
    }

    final eventType = event['event'] as String?;

    if (kDebugMode) debugPrint('OneShare discovery: received event $event');

    if (eventType == 'resolved') {
      final host = event['host'] as String?;
      final port = event['port'] as int?;

      if (host == null || port == null) {
        if (kDebugMode) {
          debugPrint(
            'OneShare discovery: invalid resolved event: $event',
          );
        }
        return;
      }

      if (kDebugMode) {
        debugPrint(
          'OneShare discovery: resolved $host:$port',
        );
      }

      final verifiedDevice =
          await _verifyAndGetDeviceInfo(host, port);

      if (verifiedDevice == null) {
        if (kDebugMode) {
          debugPrint(
            'OneShare discovery: verification FAILED '
            'for $host:$port',
          );
        }
        return;
      }

      if (kDebugMode) {
        debugPrint(
          'OneShare discovery: verified '
          '${verifiedDevice.deviceName} '
          '${verifiedDevice.deviceId}',
        );
      }

      final selfId = DeviceIdentityService.identity.deviceId;

      if (verifiedDevice.deviceId == selfId) {
        if (kDebugMode) {
          debugPrint(
            'OneShare discovery: ignoring self '
            '${verifiedDevice.deviceId}',
          );
        }
        return;
      }

      _discoveredDevices[verifiedDevice.deviceId] = verifiedDevice;
      _serviceNameToDeviceId[verifiedDevice.deviceName] = verifiedDevice.deviceId;

      if (kDebugMode) {
        debugPrint(
          'OneShare discovery: adding '
          '${verifiedDevice.deviceName}',
        );
      }

      discoveredDevicesNotifier.value =
          _discoveredDevices.values.toList();

      if (kDebugMode) {
        debugPrint(
          'OneShare discovery: total devices = '
          '${discoveredDevicesNotifier.value.length}',
        );
      }
    } else if (eventType == 'lost') {
      final serviceName = event['serviceName'] as String?;

      if (serviceName != null) {
        if (kDebugMode) {
          debugPrint(
            'OneShare discovery: service lost $serviceName',
          );
        }

        final lostDeviceId = _serviceNameToDeviceId.remove(serviceName);
        if (lostDeviceId != null) {
          _discoveredDevices.remove(lostDeviceId);
        } else {
          _discoveredDevices.removeWhere(
            (_, device) => device.deviceName == serviceName,
          );
        }

        discoveredDevicesNotifier.value =
            _discoveredDevices.values.toList();

        if (kDebugMode) {
          debugPrint(
            'OneShare discovery: total devices = '
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
        OneShareConfig.infoPath,
      );

      if (kDebugMode) {
        debugPrint(
          'OneShare discovery: requesting $uri',
        );
      }

      final request = await _client.getUrl(uri);

      final response =
          await request.close().timeout(
                const Duration(seconds: 3),
              );

      if (kDebugMode) {
        debugPrint(
          'OneShare discovery: /info status '
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
          'OneShare discovery: /info response '
          '$responseBody',
        );
      }

      final json =
          jsonDecode(responseBody) as Map<String, dynamic>;

      if (json['appName'] != OneShareConfig.appName ||
          json['protocolVersion'] !=
              OneShareConfig.protocolVersion) {
        if (kDebugMode) {
          debugPrint(
            'OneShare discovery: metadata mismatch '
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
            'OneShare discovery: missing deviceId/deviceName',
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
          'OneShare discovery: verification exception '
          '$host:$port -> $error',
        );
      }
      return null;
    }
  }
}
