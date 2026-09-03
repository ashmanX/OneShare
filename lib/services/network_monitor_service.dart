import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Centralized Single Source of Truth for real-time Wi-Fi / Network Status across OneShare.
class NetworkMonitorService {
  NetworkMonitorService._();

  static final NetworkMonitorService instance = NetworkMonitorService._();

  static const MethodChannel _wifiControlChannel =
      MethodChannel('com.oneshare.app/wifi_control');
  static const EventChannel _wifiEventChannel =
      EventChannel('com.oneshare.app/wifi_events');

  /// Reactive notifier emitting real-time Wi-Fi status changes (true = Wi-Fi ON/Online, false = Wi-Fi OFF/Offline).
  final ValueNotifier<bool> isWifiOnNotifier = ValueNotifier<bool>(true);

  StreamSubscription<dynamic>? _wifiEventSubscription;
  bool _isMonitoring = false;
  bool _isNativeChannelActive = false;
  bool? _manualOverride;

  /// Current Wi-Fi status.
  bool get isWifiOn => isWifiOnNotifier.value;

  /// Optional override for testing or manual simulation of Wi-Fi state.
  void setWifiOverride(bool? overrideState) {
    _manualOverride = overrideState;
    if (kDebugMode) {
      debugPrint('[OneShare-WiFi] setWifiOverride: $overrideState');
    }
    if (overrideState != null) {
      _updateStatus(overrideState, source: 'manualOverride');
    } else {
      checkNetworkStatus();
    }
  }

  /// Toggles the current Wi-Fi status.
  void toggleWifiState() {
    setWifiOverride(!isWifiOn);
  }

  /// Starts real-time monitoring of Wi-Fi / network interfaces.
  void startMonitoring() {
    if (_isMonitoring) return;
    _isMonitoring = true;

    if (kDebugMode) {
      debugPrint(
          '[OneShare-WiFi] startMonitoring called on ${defaultTargetPlatform.name}');
    }

    // 1. Listen to native platform push events (CoreWLAN on macOS, WifiManager BroadcastReceiver on Android)
    try {
      _wifiEventSubscription =
          _wifiEventChannel.receiveBroadcastStream().listen(
        (event) {
          if (_manualOverride != null) return;
          if (event is bool) {
            _isNativeChannelActive = true;
            _updateStatus(event, source: 'nativeEventStream');
          }
        },
        onError: (error) {
          if (kDebugMode) {
            debugPrint('[OneShare-WiFi] native stream error: $error');
          }
          _isNativeChannelActive = false;
        },
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[OneShare-WiFi] failed to connect native stream: $e');
      }
      _isNativeChannelActive = false;
    }

    // 2. Query initial status
    checkNetworkStatus();
  }

  /// Stops real-time monitoring.
  void stopMonitoring() {
    _wifiEventSubscription?.cancel();
    _wifiEventSubscription = null;
    _isMonitoring = false;
  }

  void _updateStatus(bool newStatus, {required String source}) {
    final prev = isWifiOnNotifier.value;
    if (prev != newStatus) {
      if (kDebugMode) {
        debugPrint(
            '[OneShare-WiFi] Event source=$source | previousState=$prev -> newState=$newStatus | platform=${defaultTargetPlatform.name}');
      }
      isWifiOnNotifier.value = newStatus;
    }
  }

  /// Queries active Wi-Fi status from native channel (or socket fallback in unit tests) to update [isWifiOnNotifier].
  Future<bool> checkNetworkStatus() async {
    if (_manualOverride != null) {
      _updateStatus(_manualOverride!, source: 'manualOverride');
      return _manualOverride!;
    }

    // 1. Attempt native check first
    try {
      final nativeStatus =
          await _wifiControlChannel.invokeMethod<bool>('getWifiStatus');
      if (nativeStatus != null) {
        _isNativeChannelActive = true;
        _updateStatus(nativeStatus, source: 'nativeMethodChannel');
        return nativeStatus;
      }
    } catch (_) {
      // Platform channel unavailable (e.g. unit tests or unsupported environment)
    }

    // 2. If native channel is active, do NOT overwrite with socket heuristics
    if (_isNativeChannelActive) {
      return isWifiOnNotifier.value;
    }

    // 3. Fallback for non-native test environments
    bool activeNetworkFound = false;
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final interface in interfaces) {
        final name = interface.name.toLowerCase();
        // Ignore loopback, virtual tunnel, vpn, docker, dummy interfaces
        if (name.startsWith('lo') ||
            name.startsWith('utun') ||
            name.startsWith('tun') ||
            name.startsWith('tap') ||
            name.startsWith('ppp') ||
            name.startsWith('vbox') ||
            name.startsWith('docker') ||
            name.startsWith('dummy')) {
          continue;
        }

        for (final address in interface.addresses) {
          final addrStr = address.address;
          if (!address.isLoopback &&
              !address.isLinkLocal &&
              addrStr != '127.0.0.1' &&
              addrStr != '0.0.0.0' &&
              !addrStr.startsWith('169.254.')) {
            activeNetworkFound = true;
            break;
          }
        }
        if (activeNetworkFound) break;
      }
    } catch (_) {
      activeNetworkFound = false;
    }

    _updateStatus(activeNetworkFound, source: 'socketFallback');
    return activeNetworkFound;
  }
}
