import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:oneshare/models/e2ee_models.dart';
import 'package:oneshare/services/crypto/sas_verification.dart';
import 'package:oneshare/services/device_identity_service.dart';
import 'package:oneshare/services/transfer_service.dart';
import 'package:oneshare/widgets/trust_indicator.dart';

/// Modal dialog for performing out-of-band Short Authentication String (SAS) code
/// and cryptographic identity fingerprint comparison.
///
/// Strictly enforces the security requirements of §2.8.2:
/// - Explicit out-of-band instructions ("Compare via phone call, in person, or secure third-party channel").
/// - Checkbox: "I have confirmed out-of-band that both codes match."
/// - "Mark as Verified" button is disabled until the checkbox is checked.
/// - Only upon explicit confirmation does it update the TrustStore to [TrustLevel.manuallyVerified].
class SasVerificationDialog extends StatefulWidget {
  const SasVerificationDialog({
    super.key,
    required this.transferId,
    required this.peerDeviceName,
    required this.peerDeviceId,
    required this.sasCode,
    required this.peerFingerprint,
    required this.peerIdentityPublicKeyBytes,
    required this.initialTrustLevel,
    this.onTrustLevelChanged,
  });

  final String transferId;
  final String peerDeviceName;
  final String peerDeviceId;
  final String sasCode;
  final String peerFingerprint;
  final List<int> peerIdentityPublicKeyBytes;
  final TrustLevel initialTrustLevel;
  final ValueChanged<TrustLevel>? onTrustLevelChanged;

  static Future<void> show(
    BuildContext context, {
    required String transferId,
    required String peerDeviceName,
    required String peerDeviceId,
    required String sasCode,
    required String peerFingerprint,
    required List<int> peerIdentityPublicKeyBytes,
    required TrustLevel initialTrustLevel,
    ValueChanged<TrustLevel>? onTrustLevelChanged,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => SasVerificationDialog(
        transferId: transferId,
        peerDeviceName: peerDeviceName,
        peerDeviceId: peerDeviceId,
        sasCode: sasCode,
        peerFingerprint: peerFingerprint,
        peerIdentityPublicKeyBytes: peerIdentityPublicKeyBytes,
        initialTrustLevel: initialTrustLevel,
        onTrustLevelChanged: onTrustLevelChanged,
      ),
    );
  }

  @override
  State<SasVerificationDialog> createState() => _SasVerificationDialogState();
}

class _SasVerificationDialogState extends State<SasVerificationDialog> {
  bool _hasConfirmedOutOfBand = false;
  bool _isSaving = false;
  late TrustLevel _currentTrustLevel;

  @override
  void initState() {
    super.initState();
    _currentTrustLevel = widget.initialTrustLevel;
  }

  Future<void> _handleConfirmVerification() async {
    if (!_hasConfirmedOutOfBand || _isSaving) return;

    setState(() {
      _isSaving = true;
    });

    try {
      final trustStore = TransferService.instance.trustStore;
      await trustStore.markManuallyVerified(
        fingerprint: widget.peerFingerprint,
        identityPublicKeyBytes: Uint8List.fromList(widget.peerIdentityPublicKeyBytes),
        deviceName: widget.peerDeviceName,
        deviceId: widget.peerDeviceId,
      );

      // Update active session trust level
      final session = TransferService.instance.getSession(widget.transferId);
      if (session != null) {
        session.trustLevel = TrustLevel.manuallyVerified;
      }

      if (mounted) {
        setState(() {
          _currentTrustLevel = TrustLevel.manuallyVerified;
          _isSaving = false;
        });
        widget.onTrustLevelChanged?.call(TrustLevel.manuallyVerified);
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save verification: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final formattedSas = SasVerification.formatSasCode(widget.sasCode);
    final formattedFp = DeviceIdentityService.formatFingerprint(widget.peerFingerprint);
    final isAlreadyVerified = _currentTrustLevel == TrustLevel.manuallyVerified;

    return Dialog(
      backgroundColor: const Color(0xFF10131E),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: Color(0xFF1E2436), width: 1),
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
              // Header
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A233D),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.shield_outlined,
                      color: Color(0xFF38BDF8),
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Verify Security Code',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'End-to-End Encryption Verification',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 12,
                            color: const Color(0xFF94A3B8),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Color(0xFF64748B), size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),

              const SizedBox(height: 18),

              // Current Trust Status Badge
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Peer Status:',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF94A3B8),
                    ),
                  ),
                  Flexible(
                    child: TrustIndicator(trustLevel: _currentTrustLevel, compact: true),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // 6-digit SAS Code Card
              Container(
                padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
                decoration: BoxDecoration(
                  color: const Color(0xFF161B2B),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF283454), width: 1.5),
                ),
                child: Column(
                  children: [
                    Text(
                      'SHORT AUTHENTICATION STRING (SAS)',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                        color: const Color(0xFF38BDF8),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SelectableText(
                      formattedSas,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.spaceMono(
                        fontSize: 34,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 6,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Compare this 6-digit code with ${widget.peerDeviceName}. Both devices must display the exact same code.',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 11,
                        color: const Color(0xFFA0ABBA),
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 14),

              // Peer Identity Fingerprint Card
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F131D),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF1E2436), width: 1),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'IDENTITY FINGERPRINT',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.0,
                            color: const Color(0xFF64748B),
                          ),
                        ),
                        InkWell(
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: widget.peerFingerprint));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Fingerprint copied to clipboard'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          },
                          child: Row(
                            children: [
                              const Icon(Icons.copy_rounded, size: 12, color: Color(0xFF38BDF8)),
                              const SizedBox(width: 4),
                              Text(
                                'Copy',
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: const Color(0xFF38BDF8),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      formattedFp,
                      style: GoogleFonts.spaceMono(
                        fontSize: 11,
                        color: const Color(0xFFCBD5E1),
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 18),

              // Verification Instructions
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A10),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF854D0E).withValues(alpha: 0.5), width: 1),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: Color(0xFFEAB308), size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Compare this code via phone call, in person, or a secure third-party channel. Do NOT proceed if the codes do not match.',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 11,
                          color: const Color(0xFFFEF08A),
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              if (isAlreadyVerified) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF062816),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF22C55E).withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle_rounded, color: Color(0xFF22C55E), size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'This peer identity is already verified and cryptographically trusted.',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF4ADE80),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    backgroundColor: const Color(0xFF1E2436),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(
                    'Close',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
              ] else ...[
                // Explicit Out-of-Band Confirmation Checkbox
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Checkbox(
                      value: _hasConfirmedOutOfBand,
                      onChanged: (val) {
                        setState(() {
                          _hasConfirmedOutOfBand = val ?? false;
                        });
                      },
                      activeColor: const Color(0xFF22C55E),
                      checkColor: Colors.black,
                      side: const BorderSide(color: Color(0xFF475569), width: 1.5),
                    ),
                    Expanded(
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            _hasConfirmedOutOfBand = !_hasConfirmedOutOfBand;
                          });
                        },
                        child: Text(
                          'I have confirmed out-of-band that both codes match.',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: _hasConfirmedOutOfBand ? Colors.white : const Color(0xFF94A3B8),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                // Mark as Verified Action Button
                ElevatedButton.icon(
                  onPressed: _hasConfirmedOutOfBand && !_isSaving ? _handleConfirmVerification : null,
                  icon: _isSaving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                        )
                      : const Icon(Icons.verified_user_rounded, size: 18),
                  label: Text(
                    _isSaving ? 'Verifying...' : 'Mark as Verified',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    backgroundColor: const Color(0xFF22C55E),
                    foregroundColor: Colors.black,
                    disabledBackgroundColor: const Color(0xFF1E293B),
                    disabledForegroundColor: const Color(0xFF64748B),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
