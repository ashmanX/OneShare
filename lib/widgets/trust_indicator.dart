import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:oneshare/models/e2ee_models.dart';

/// Renders visual badge and label corresponding to the peer's cryptographic [TrustLevel].
///
/// Strictly distinguishes between:
/// - [TrustLevel.untrusted]: Grey lock ("Encrypted · Untrusted")
/// - [TrustLevel.unverifiedSeen]: Amber/Grey lock ("Encrypted · Previously Seen (Unverified)")
/// - [TrustLevel.manuallyVerified]: Green lock + checkmark ("Verified · Trusted")
class TrustIndicator extends StatelessWidget {
  const TrustIndicator({
    super.key,
    required this.trustLevel,
    this.compact = false,
    this.onTap,
  });

  final TrustLevel trustLevel;
  final bool compact;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Color badgeColor;
    final Color textColor;
    final Color bgColor;
    final IconData icon;
    final String label;

    switch (trustLevel) {
      case TrustLevel.manuallyVerified:
        badgeColor = const Color(0xFF22C55E); // Green
        textColor = const Color(0xFF4ADE80);
        bgColor = const Color(0xFF0E2E1E);
        icon = Icons.verified_user_rounded;
        label = compact ? 'Verified' : 'Verified · Trusted';
        break;

      case TrustLevel.unverifiedSeen:
        badgeColor = const Color(0xFFF59E0B); // Amber
        textColor = const Color(0xFFFBBF24);
        bgColor = const Color(0xFF2E2410);
        icon = Icons.lock_clock_rounded;
        label = compact ? 'Seen (Unverified)' : 'Encrypted · Previously Seen (Unverified)';
        break;

      case TrustLevel.untrusted:
        badgeColor = const Color(0xFF94A3B8); // Slate grey
        textColor = const Color(0xFFCBD5E1);
        bgColor = const Color(0xFF1E2430);
        icon = Icons.lock_outline_rounded;
        label = compact ? 'Untrusted' : 'Encrypted · Untrusted';
        break;
    }

    Widget content = Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 4 : 5,
      ),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(compact ? 8 : 10),
        border: Border.all(color: badgeColor.withValues(alpha: 0.35), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, size: compact ? 13 : 15, color: badgeColor),
          const SizedBox(width: 5),
          Text(
            label,
            style: GoogleFonts.plusJakartaSans(
              fontSize: compact ? 11 : 12,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, size: 14, color: textColor.withValues(alpha: 0.7)),
          ],
        ],
      ),
    );

    if (onTap != null) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(compact ? 8 : 10),
        child: content,
      );
    }

    return content;
  }
}
