import 'package:flutter_test/flutter_test.dart';

import 'package:droplan/main.dart';

void main() {
  testWidgets('DropLAN UI renders correctly', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const DropLanApp());

    // Verify that DropLAN header and main sections render.
    expect(find.text('DropLAN'), findsWidgets);
    expect(find.text('This device'), findsOneWidget);
    expect(find.text('Send files'), findsOneWidget);
  });
}
