import 'package:flutter_test/flutter_test.dart';
import 'package:oneshare/services/network_monitor_service.dart';

void main() {
  test('NetworkMonitorService singleton instance exists and has initial state',
      () {
    final service = NetworkMonitorService.instance;
    expect(service, isNotNull);
    expect(service.isWifiOnNotifier.value, isNotNull);
  });

  test('NetworkMonitorService notifier updates subscribers', () async {
    final service = NetworkMonitorService.instance;
    bool? observedStatus;

    void listener() {
      observedStatus = service.isWifiOn;
    }

    service.isWifiOnNotifier.addListener(listener);

    service.isWifiOnNotifier.value = false;
    expect(observedStatus, isFalse);

    service.isWifiOnNotifier.value = true;
    expect(observedStatus, isTrue);

    service.isWifiOnNotifier.removeListener(listener);
  });
}
