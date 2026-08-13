import 'package:flutter_test/flutter_test.dart';

import 'package:oneshare/main.dart';

void main() {
  testWidgets('OneShare UI renders correctly', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const OneShareApp());

    // Verify that OneShare branding, subtitle, radar text, and main action render.
    expect(find.text('OneShare'), findsOneWidget);
    expect(find.text('Share files wirelessly with nearby devices.'), findsOneWidget);
    expect(find.text('Select Files to Send'), findsOneWidget);
    expect(find.text('Scanning for devices...'), findsOneWidget);
  });
}
