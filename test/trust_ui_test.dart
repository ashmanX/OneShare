import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oneshare/models/e2ee_models.dart';
import 'package:oneshare/services/crypto/crypto_key_storage.dart';
import 'package:oneshare/services/crypto/trust_store.dart';
import 'package:oneshare/services/device_identity_service.dart';
import 'package:oneshare/services/transfer_service.dart';
import 'package:oneshare/widgets/identity_mismatch_dialog.dart';
import 'package:oneshare/widgets/sas_verification_dialog.dart';
import 'package:oneshare/widgets/trust_indicator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TrustIndicator Widget Tests', () {
    testWidgets('Renders Untrusted badge correctly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TrustIndicator(trustLevel: TrustLevel.untrusted),
          ),
        ),
      );

      expect(find.text('Encrypted · Untrusted'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
    });

    testWidgets('Renders Unverified Seen badge correctly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TrustIndicator(trustLevel: TrustLevel.unverifiedSeen),
          ),
        ),
      );

      expect(find.text('Encrypted · Previously Seen (Unverified)'), findsOneWidget);
      expect(find.byIcon(Icons.lock_clock_rounded), findsOneWidget);
    });

    testWidgets('Renders Manually Verified badge correctly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TrustIndicator(trustLevel: TrustLevel.manuallyVerified),
          ),
        ),
      );

      expect(find.text('Verified · Trusted'), findsOneWidget);
      expect(find.byIcon(Icons.verified_user_rounded), findsOneWidget);
    });

    testWidgets('Compact mode renders abbreviated labels', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                TrustIndicator(trustLevel: TrustLevel.untrusted, compact: true),
                TrustIndicator(trustLevel: TrustLevel.unverifiedSeen, compact: true),
                TrustIndicator(trustLevel: TrustLevel.manuallyVerified, compact: true),
              ],
            ),
          ),
        ),
      );

      expect(find.text('Untrusted'), findsOneWidget);
      expect(find.text('Seen (Unverified)'), findsOneWidget);
      expect(find.text('Verified'), findsOneWidget);
    });
  });

  group('SasVerificationDialog Widget Tests', () {
    const testTransferId = 'test-transfer-sas-ui-001';
    final dummyPubBytes = Uint8List.fromList(List.generate(32, (i) => i));
    const dummyFingerprint = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

    setUp(() async {
      DeviceIdentityService.resetForTesting();
      await DeviceIdentityService.initialize(storage: InMemoryKeyStorage());
      TransferService.instance.trustStore = TrustStore(storage: InMemoryKeyStorage());
    });

    testWidgets('Displays formatted 6-digit SAS and formatted fingerprint', (tester) async {
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SasVerificationDialog(
              transferId: testTransferId,
              peerDeviceName: 'Pixel 8',
              peerDeviceId: 'dev-123',
              sasCode: '042816',
              peerFingerprint: dummyFingerprint,
              peerIdentityPublicKeyBytes: dummyPubBytes,
              initialTrustLevel: TrustLevel.untrusted,
            ),
          ),
        ),
      );

      // Verify formatted SAS "042 816" is displayed
      expect(find.text('042 816'), findsOneWidget);
      expect(find.textContaining('Pixel 8'), findsOneWidget);

      // Verify formatted fingerprint is displayed
      final formattedFp = DeviceIdentityService.formatFingerprint(dummyFingerprint);
      expect(find.text(formattedFp), findsOneWidget);
    });

    testWidgets('Out-of-band confirmation checkbox is required to enable Mark as Verified button', (tester) async {
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SasVerificationDialog(
              transferId: testTransferId,
              peerDeviceName: 'Pixel 8',
              peerDeviceId: 'dev-123',
              sasCode: '042816',
              peerFingerprint: dummyFingerprint,
              peerIdentityPublicKeyBytes: dummyPubBytes,
              initialTrustLevel: TrustLevel.untrusted,
            ),
          ),
        ),
      );

      final verifyBtnFinder = find.widgetWithText(ElevatedButton, 'Mark as Verified');
      expect(verifyBtnFinder, findsOneWidget);

      // Initially disabled
      final ElevatedButton initialBtn = tester.widget(verifyBtnFinder);
      expect(initialBtn.onPressed, isNull);

      // Tap checkbox
      final checkboxFinder = find.byType(Checkbox);
      expect(checkboxFinder, findsOneWidget);
      await tester.tap(checkboxFinder);
      await tester.pumpAndSettle();

      // Now button is enabled
      final ElevatedButton enabledBtn = tester.widget(verifyBtnFinder);
      expect(enabledBtn.onPressed, isNotNull);

      // Tap button and verify trust store promotion
      await tester.tap(verifyBtnFinder);
      await tester.pumpAndSettle();

      final record = await TransferService.instance.trustStore.getPeer(dummyFingerprint);
      expect(record, isNotNull);
      expect(record!.trustLevel, TrustLevel.manuallyVerified);
    });
  });

  group('IdentityMismatchDialog Widget Tests', () {
    testWidgets('Renders red alert banner, warning description, and fingerprints', (tester) async {
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      bool rejected = false;
      bool proceedUntrusted = false;

      final previousRecord = PeerRecord(
        fingerprint: '1111222233334444555566667777888899990000aaaabbbbccccddddeeeeffff',
        identityPublicKeyBytes: Uint8List(32),
        deviceName: 'Alice Phone',
        deviceId: 'alice-id',
        trustLevel: TrustLevel.manuallyVerified,
        firstSeen: DateTime.now(),
        lastSeen: DateTime.now(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IdentityMismatchDialog(
              deviceName: 'Alice Phone',
              deviceId: 'alice-id',
              newFingerprint: 'aaaabbbbccccddddeeeeffff1111222233334444555566667777888899990000',
              previousRecord: previousRecord,
              onReject: () => rejected = true,
              onProceedUntrusted: () => proceedUntrusted = true,
            ),
          ),
        ),
      );

      expect(find.text('Security Alert'), findsOneWidget);
      expect(find.text('Peer Identity Key Mismatch'), findsOneWidget);
      expect(find.text('Reject Connection (Recommended)'), findsOneWidget);
      expect(find.text('Proceed as Untrusted'), findsOneWidget);

      await tester.tap(find.text('Reject Connection (Recommended)'));
      expect(rejected, isTrue);

      await tester.tap(find.text('Proceed as Untrusted'));
      expect(proceedUntrusted, isTrue);
    });
  });
}
