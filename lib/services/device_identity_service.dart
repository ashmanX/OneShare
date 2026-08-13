import 'dart:math';

class DeviceIdentity {
  const DeviceIdentity({
    required this.deviceId,
    required this.deviceName,
  });

  final String deviceId;
  final String deviceName;
}

class DeviceIdentityService {
  DeviceIdentityService._();

  static DeviceIdentity? _identity;

  static DeviceIdentity get identity {
    return _identity ??= _createIdentity();
  }

  static DeviceIdentity _createIdentity() {
    return DeviceIdentity(
      deviceId: _generateUuidV4(),
      deviceName: _generateDeviceName(),
    );
  }

  static String _generateDeviceName() {
    final suffix = Random().nextInt(9000) + 1000;
    return 'OneShare-$suffix';
  }

  static String _generateUuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));

    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    String hex(int value) => value.toRadixString(16).padLeft(2, '0');

    final parts = bytes.map(hex).toList();
    return '${parts.sublist(0, 4).join()}-'
        '${parts.sublist(4, 6).join()}-'
        '${parts.sublist(6, 8).join()}-'
        '${parts.sublist(8, 10).join()}-'
        '${parts.sublist(10, 16).join()}';
  }
}
