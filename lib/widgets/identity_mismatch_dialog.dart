import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:oneshare/models/e2ee_models.dart';
import 'package:oneshare/services/device_identity_service.dart';

/// Red alert dialog shown when a peer device name or device ID connects with an
/// unexpected cryptographic fingerprint different from the one previously recorded in TrustStore.
class IdentityMismatchDialog extends StatelessWidget {
  const IdentityMismatchDialog({
    super.key,
    required this.deviceName,
    required this.deviceId,
    required this.newFingerprint,
    required this.previousRecord,
    required this.onReject,
    required this.onProceedUntrusted,
  });

  final String deviceName;
  final String deviceId;
  final String newFingerprint;
  final PeerRecord previousRecord;
  final VoidCallback onReject;
  final VoidCallback onProceedUntrusted;

  static Future<bool?> show(
    BuildContext context, {
    required String deviceName,
    required String deviceId,
    required String newFingerprint,
    required PeerRecord previousRecord,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => IdentityMismatchDialog(
        deviceName: deviceName,
        deviceId: deviceId,
        newFingerprint: newFingerprint,
        previousRecord: previousRecord,
        onReject: () => Navigator.of(ctx).pop(false),
        onProceedUntrusted: () => Navigator.of(ctx).pop(true),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final formattedNew = DeviceIdentityService.formatFingerprint(newFingerprint);
    final formattedPrev = DeviceIdentityService.formatFingerprint(previousRecord.fingerprint);

    return Dialog(
      backgroundColor: const Color(0xFF140D10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: Color(0xFFEF4444), width: 1.5),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFF3B1214),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.warning_rounded,
                      color: Color(0xFFEF4444),
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Security Alert',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFFEF4444),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'Peer Identity Key Mismatch',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 12,
                            color: const Color(0xFFFCA5A5),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                'The device "$deviceName" is presenting a DIFFERENT cryptographic identity key than previously recorded in your Trust Store.',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF221115),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF7F1D1D)),
                ),
                child: Text(
                  'This could mean the remote user reinstalled the application or reset their device keys. However, it can also indicate a Man-in-the-Middle (MITM) interception attempt on your local network.',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 11,
                    color: const Color(0xFFF87171),
                    height: 1.35,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'PREVIOUS FINGERPRINT:',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                  color: const Color(0xFF94A3B8),
                ),
              ),
              const SizedBox(height: 4),
              SelectableText(
                formattedPrev,
                style: GoogleFonts.spaceMono(
                  fontSize: 10,
                  color: const Color(0xFF94A3B8),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'NEW FINGERPRINT (CURRENT CONNECTION):',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                  color: const Color(0xFFEF4444),
                ),
              ),
              const SizedBox(height: 4),
              SelectableText(
                formattedNew,
                style: GoogleFonts.spaceMono(
                  fontSize: 10,
                  color: const Color(0xFFFCA5A5),
                ),
              ),
              const SizedBox(height: 22),
              ElevatedButton(
                onPressed: onReject,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFDC2626),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(
                  'Reject Connection (Recommended)',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: onProceedUntrusted,
                child: Text(
                  'Proceed as Untrusted',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF94A3B8),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
