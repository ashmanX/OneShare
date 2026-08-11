import 'package:flutter_test/flutter_test.dart';

import 'package:droplan/main.dart';

void main() {
  testWidgets('AirShare UI renders correctly', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const DropLanApp());

    // Verify that AirShare branding, Nearby Devices subtitle, and main action render.
    expect(find.text('AirShare'), findsOneWidget);
    expect(find.text('Nearby Devices'), findsOneWidget);
    expect(find.text('Select Files to send'), findsOneWidget);
    expect(find.text('Scanning for nearby devices...'), findsOneWidget);
  });
}
