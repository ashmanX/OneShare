import 'dart:typed_data';

/// Utility to derive the 6-digit Short Authentication String (SAS)
/// code from HKDF-derived sasBytes.
class SasVerification {
  SasVerification._();

  /// Derives a 6-digit zero-padded numeric string from 4 bytes:
  /// `BigEndian_uint32(sasBytes[0..3]) mod 1000000`.
  static String deriveSasCode(List<int> sasBytes) {
    if (sasBytes.length < 4) {
      throw ArgumentError('sasBytes must be at least 4 bytes');
    }
    final byteData = ByteData.sublistView(Uint8List.fromList(sasBytes), 0, 4);
    final uint32Val = byteData.getUint32(0, Endian.big);
    final codeInt = uint32Val % 1000000;
    return codeInt.toString().padLeft(6, '0');
  }

  /// Formats the 6-digit code into a grouped format for UI display (e.g. "042 816").
  static String formatSasCode(String sasCode) {
    if (sasCode.length == 6) {
      return '${sasCode.substring(0, 3)} ${sasCode.substring(3, 6)}';
    }
    return sasCode;
  }
}
