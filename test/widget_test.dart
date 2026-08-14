import 'package:flutter_test/flutter_test.dart';
import 'package:oneshare/main.dart';
import 'package:oneshare/services/network_monitor_service.dart';

void main() {
  testWidgets('OneShare UI renders correctly with default Wi-Fi ON state',
      (WidgetTester tester) async {
    NetworkMonitorService.instance.isWifiOnNotifier.value = true;
    await tester.pumpWidget(const OneShareApp());
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('OneShare'), findsOneWidget);
    expect(find.text('Share files wirelessly with nearby devices.'),
        findsOneWidget);
    expect(find.text('Select Files to Send'), findsOneWidget);
    expect(find.text('Online'), findsOneWidget);
    expect(find.text('Scanning for nearby devices'), findsOneWidget);
    expect(find.text('Nearby Devices'), findsOneWidget);
  });

  testWidgets(
      'Real-time Wi-Fi status changes dynamically between Online and Offline',
      (WidgetTester tester) async {
    NetworkMonitorService.instance.isWifiOnNotifier.value = true;
    await tester.pumpWidget(const OneShareApp());
    await tester.pump(const Duration(milliseconds: 100));

    // Verify Online state
    expect(find.text('Online'), findsOneWidget);
    expect(find.text('Scanning for nearby devices'), findsOneWidget);

    // Simulate Wi-Fi toggling OFF
    NetworkMonitorService.instance.isWifiOnNotifier.value = false;
    await tester.pump(const Duration(milliseconds: 100));

    // Verify Offline state
    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('Turn on Wi-Fi to start scanning'), findsWidgets);

    // Simulate Wi-Fi toggling back ON
    NetworkMonitorService.instance.isWifiOnNotifier.value = true;
    await tester.pump(const Duration(milliseconds: 100));

    // Verify Online state restored
    expect(find.text('Online'), findsOneWidget);
    expect(find.text('Scanning for nearby devices'), findsOneWidget);
  });
}
