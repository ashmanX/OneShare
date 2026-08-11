import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:droplan/config/droplan_config.dart';
import 'package:droplan/models/transfer_models.dart';
import 'package:droplan/services/device_identity_service.dart';
import 'package:droplan/services/droplan_discovery_service.dart';
import 'package:droplan/services/droplan_http_server.dart';
import 'package:droplan/services/transfer_service.dart';
import 'package:droplan/widgets/incoming_transfer_dialog.dart';

void main() {
  runApp(const DropLanApp());
}

class SelectedFile {
  const SelectedFile({
    required this.name,
    required this.size,
    required this.path,
  });

  final String name;
  final int size;
  final String path;
}

/// Three clear application states.
enum AppScreen { home, sc2, sc3 }

// BUG-11 FIX: Track which direction the active SC3 transfer is going so we
// can read the correct progress notifier (send vs receive).
enum TransferDirection { sending, receiving }

// ============================================================
// App root — theme only, no business logic
// ============================================================
class DropLanApp extends StatelessWidget {
  const DropLanApp({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = GoogleFonts.plusJakartaSansTextTheme(
      ThemeData.dark().textTheme,
    );

    const darkColorScheme = ColorScheme(
      brightness: Brightness.dark,
      primary: Color(0xFF3B82F6),
      onPrimary: Color(0xFFFFFFFF),
      primaryContainer: Color(0xFF1E40AF),
      onPrimaryContainer: Color(0xFFDBEAFE),
      secondary: Color(0xFF38BDF8),
      onSecondary: Color(0xFFFFFFFF),
      secondaryContainer: Color(0xFF075985),
      onSecondaryContainer: Color(0xFFE0F2FE),
      surface: Color(0xFF000000),
      onSurface: Color(0xFFFFFFFF),
      surfaceContainerLowest: Color(0xFF05060A),
      surfaceContainerHigh: Color(0xFF12141D),
      onSurfaceVariant: Color(0xFF8E95A5),
      outline: Color(0xFF1F2232),
      outlineVariant: Color(0xFF171A27),
      error: Color(0xFFEF4444),
      onError: Color(0xFFFFFFFF),
    );

    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Color(0xFF000000),
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );

    final sharedDialogTheme = DialogThemeData(
      backgroundColor: const Color(0xFF12141D),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: Color(0xFF1F2232), width: 1),
      ),
      titleTextStyle: GoogleFonts.plusJakartaSans(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: Colors.white,
      ),
      contentTextStyle: GoogleFonts.plusJakartaSans(
        fontSize: 14,
        color: const Color(0xFFCBD5E1),
      ),
    );

    return MaterialApp(
      title: 'AirShare',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: darkColorScheme,
        scaffoldBackgroundColor: const Color(0xFF000000),
        textTheme: textTheme,
        useMaterial3: true,
        dialogTheme: sharedDialogTheme,
      ),
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: darkColorScheme,
        scaffoldBackgroundColor: const Color(0xFF000000),
        textTheme: textTheme,
        useMaterial3: true,
        dialogTheme: sharedDialogTheme,
      ),
      home: const DropLanHomeScreen(),
    );
  }
}

// ============================================================
// Root widget
// ============================================================
class DropLanHomeScreen extends StatefulWidget {
  const DropLanHomeScreen({super.key});

  @override
  State<DropLanHomeScreen> createState() => _DropLanHomeScreenState();
}

// ============================================================
// State — all app logic lives here
// ============================================================
class _DropLanHomeScreenState extends State<DropLanHomeScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  // ── Services ─────────────────────────────────────────────
  late final String _deviceName;
  late final DropLanHttpServer _httpServer;
  late final DropLanDiscoveryService _discoveryService;

  // ── Animation ────────────────────────────────────────────
  late final AnimationController _radarAnimationController;

  // ── File selection ────────────────────────────────────────
  final List<SelectedFile> _selectedFiles = [];

  // ── App screen state ──────────────────────────────────────
  AppScreen _currentScreen = AppScreen.home;

  // ── Network / WiFi status state ─────────────────────────
  bool _isWifiOn = true;
  Timer? _wifiCheckTimer;

  // ── Transfer request state ────────────────────────────────
  bool _isSendingRequest = false;
  String? _waitingForDeviceName;
  bool _isIncomingDialogOpen = false;

  // BUG-16 FIX: Guard against launching multiple file pickers simultaneously
  // (e.g. rapid double-tap on macOS).
  bool _isPickingFiles = false;

  // BUG-11 FIX: Track which direction the active SC3 transfer is in and
  // which transfer session is current, to prevent stale progress updates
  // from switching the screen back to SC3 after the user taps Done.
  TransferDirection _transferDirection = TransferDirection.sending;
  String? _activeTransferSessionId;

  // ──────────────────────────────────────────────────────────
  // Lifecycle
  // ──────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();

    _deviceName = DeviceIdentityService.identity.deviceName;
    _httpServer = DropLanHttpServer();
    _discoveryService = DropLanDiscoveryService();

    _radarAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();

    WidgetsBinding.instance.addObserver(this);

    TransferService.instance.incomingRequestNotifier
        .addListener(_onIncomingTransferRequest);

    // BUG-11 FIX: Listen to the two separate progress notifiers.
    TransferService.instance.sendProgressNotifier
        .addListener(_onSendProgressChanged);
    TransferService.instance.receiveProgressNotifier
        .addListener(_onReceiveProgressChanged);

    _checkWifiStatus();
    _wifiCheckTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _checkWifiStatus();
    });

    _startServicesIfForeground();
  }

  @override
  void dispose() {
    _wifiCheckTimer?.cancel();
    _radarAnimationController.dispose();
    TransferService.instance.incomingRequestNotifier
        .removeListener(_onIncomingTransferRequest);
    // BUG-11 FIX: Remove listeners for both split notifiers.
    TransferService.instance.sendProgressNotifier
        .removeListener(_onSendProgressChanged);
    TransferService.instance.receiveProgressNotifier
        .removeListener(_onReceiveProgressChanged);
    WidgetsBinding.instance.removeObserver(this);
    _stopServices();
    super.dispose();
  }

  Future<void> _checkWifiStatus() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      bool activeNetworkFound = false;
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLoopback) {
            activeNetworkFound = true;
            break;
          }
        }
        if (activeNetworkFound) break;
      }

      if (!mounted) return;

      if (activeNetworkFound != _isWifiOn) {
        setState(() {
          _isWifiOn = activeNetworkFound;
          if (_isWifiOn) {
            if (!_radarAnimationController.isAnimating) {
              _radarAnimationController.repeat();
            }
          } else {
            if (_radarAnimationController.isAnimating) {
              _radarAnimationController.stop();
            }
          }
        });
        // BUG-17 FIX: When Wi-Fi reconnects (transition false→true), restart
        // NSD advertising and discovery so nearby devices become visible
        // again without requiring an app restart.
        if (activeNetworkFound) {
          _startServicesIfForeground(isResume: true);
        }
      }
    } catch (_) {}
  }

  // ──────────────────────────────────────────────────────────
  // Incoming transfer (receiver side) — unchanged
  // ──────────────────────────────────────────────────────────

  void _onIncomingTransferRequest() {
    final request = TransferService.instance.incomingRequestNotifier.value;
    if (request == null || !mounted) return;

    if (kDebugMode) {
      debugPrint(
          '[AirShare] INCOMING transferId=${request.transferId} time=${DateTime.now().toIso8601String()}');
    }

    if (_isIncomingDialogOpen) return;
    _isIncomingDialogOpen = true;

    if (Platform.isMacOS) {
      const MethodChannel('com.example.droplan/nsd_control')
          .invokeMethod('activateApp')
          .catchError((_) {});
    }

    showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => IncomingTransferDialog(request: request),
    ).then((result) {
      _isIncomingDialogOpen = false;
      if (TransferService.instance.incomingRequestNotifier.value?.transferId ==
          request.transferId) {
        TransferService.instance.incomingRequestNotifier.value = null;
      }
      if (result == 'cancelled_by_sender' && mounted) {
        _showModernToast(
          title: 'Request Cancelled',
          message: '${request.senderDeviceName} cancelled the transfer request.',
          icon: Icons.cancel_outlined,
          accentColor: const Color(0xFFF59E0B),
        );
      }
    });
  }

  // ──────────────────────────────────────────────────────────
  // Transfer progress → drives SC3
  // BUG-11 FIX: Two separate listeners for sender vs receiver progress.
  // BUG-15/03 FIX: Guard against stale progress updates overriding Home
  // after the user taps Done (by checking _activeTransferSessionId).
  // ──────────────────────────────────────────────────────────

  void _onSendProgressChanged() {
    if (!mounted) return;
    final p = TransferService.instance.sendProgressNotifier.value;
    if (p == null) return;
    // BUG-15 FIX: Only navigate to SC3 if this update belongs to the current
    // active session. After _onDone() clears _activeTransferSessionId, late
    // updates are ignored.
    if (_activeTransferSessionId != null &&
        p.transferId != _activeTransferSessionId) {
      return;
    }
    setState(() {
      _transferDirection = TransferDirection.sending;
      _currentScreen = AppScreen.sc3;
      _waitingForDeviceName = null;
      _isSendingRequest = false;
    });
  }

  void _onReceiveProgressChanged() {
    if (!mounted) return;
    final p = TransferService.instance.receiveProgressNotifier.value;
    if (p == null) return;
    setState(() {
      _transferDirection = TransferDirection.receiving;
      _currentScreen = AppScreen.sc3;
    });
  }

  // ──────────────────────────────────────────────────────────
  // App lifecycle
  // ──────────────────────────────────────────────────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (kDebugMode) {
      debugPrint('[AirShare] lifecycle: ${state.name}');
    }
    if (state == AppLifecycleState.resumed) {
      _startServicesIfForeground(isResume: true);
      return;
    }
    if (state == AppLifecycleState.detached) {
      _stopServices();
    }
  }

  Future<void> _startServicesIfForeground({bool isResume = false}) async {
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    if (lifecycleState != null &&
        lifecycleState != AppLifecycleState.resumed &&
        lifecycleState != AppLifecycleState.inactive) {
      return;
    }
    await _httpServer.start();
    if (_httpServer.isRunning) {
      await _discoveryService.startAdvertising(
        _deviceName,
        DropLanConfig.port,
        isResume: isResume,
      );
      await _discoveryService.startDiscovery();
    }
  }

  Future<void> _stopServices() async {
    await _discoveryService.stopDiscovery();
    await _discoveryService.stopAdvertising();
    _discoveryService.clearDiscoveredDevices();
    await _httpServer.stop();
  }

  // ──────────────────────────────────────────────────────────
  // Helpers
  // ──────────────────────────────────────────────────────────

  static String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static IconData _getDeviceIcon(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('mac') || lower.contains('imac') || lower.contains('macbook')) {
      return Icons.desktop_mac_rounded;
    } else if (lower.contains('windows') || lower.contains('pc') || lower.contains('desktop')) {
      return Icons.computer_rounded;
    } else if (lower.contains('laptop') || lower.contains('notebook') || lower.contains('book')) {
      return Icons.laptop_rounded;
    } else if (lower.contains('pad') || lower.contains('tablet')) {
      return Icons.tablet_rounded;
    } else if (lower.contains('android') || lower.contains('phone') ||
        lower.contains('mobile') || lower.contains('pixel') ||
        lower.contains('galaxy') || lower.contains('iphone')) {
      return Icons.smartphone_rounded;
    }
    return Icons.devices_rounded;
  }

  static IconData _getFileIcon(String fileName) {
    final ext = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : '';
    if (['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'bmp'].contains(ext)) {
      return Icons.image_rounded;
    } else if (['mp4', 'mkv', 'mov', 'avi', 'webm'].contains(ext)) {
      return Icons.movie_rounded;
    } else if (['mp3', 'wav', 'aac', 'flac', 'm4a'].contains(ext)) {
      return Icons.audiotrack_rounded;
    } else if (['pdf'].contains(ext)) {
      return Icons.picture_as_pdf_rounded;
    } else if (['zip', 'tar', 'gz', '7z', 'rar'].contains(ext)) {
      return Icons.folder_zip_rounded;
    } else if (['txt', 'md', 'json', 'dart', 'js', 'html', 'css'].contains(ext)) {
      return Icons.description_rounded;
    }
    return Icons.insert_drive_file_rounded;
  }

  static Color _getFileColor(String fileName) {
    final ext = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : '';
    if (['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg'].contains(ext)) {
      return const Color(0xFF38BDF8);
    } else if (['mp4', 'mkv', 'mov', 'avi'].contains(ext)) {
      return const Color(0xFFA855F7);
    } else if (['mp3', 'wav', 'aac'].contains(ext)) {
      return const Color(0xFFF59E0B);
    } else if (['pdf'].contains(ext)) {
      return const Color(0xFFEF4444);
    } else if (['zip', 'tar', 'gz'].contains(ext)) {
      return const Color(0xFF10B981);
    }
    return const Color(0xFF6366F1);
  }

  // ──────────────────────────────────────────────────────────
  // Toast
  // ──────────────────────────────────────────────────────────

  void _showModernToast({
    required String message,
    required IconData icon,
    required Color accentColor,
    String? title,
    Duration duration = const Duration(seconds: 3),
  }) {
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: duration,
        elevation: 0,
        backgroundColor: Colors.transparent,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        padding: EdgeInsets.zero,
        content: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF0B1220).withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: accentColor.withValues(alpha: 0.4),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: accentColor, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title != null) ...[
                      Text(
                        title,
                        style: GoogleFonts.plusJakartaSans(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                    ],
                    Text(
                      message,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: title != null
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  }

  // ──────────────────────────────────────────────────────────
  // File picker — transition to SC2 after selection
  // ──────────────────────────────────────────────────────────

  Future<void> _pickFiles() async {
    // BUG-16 FIX: Prevent opening multiple pickers on rapid double-tap.
    if (_isPickingFiles) return;
    _isPickingFiles = true;
    try {
      final newFiles = <SelectedFile>[];

      if (Platform.isAndroid) {
        const channel = MethodChannel('com.example.droplan/instant_picker');
        final List<dynamic>? res =
            await channel.invokeListMethod<dynamic>('pickFiles');

        if (res == null || res.isEmpty) return;

        for (final item in res) {
          if (item is Map) {
            final name = item['name'] as String? ?? 'file';
            final size = (item['size'] as num?)?.toInt() ?? 0;
            final path = item['path'] as String? ?? '';
            if (path.isNotEmpty) {
              newFiles.add(SelectedFile(name: name, size: size, path: path));
            }
          }
        }
      } else {
        // macOS & Desktop: Use file_selector openFiles() which directly calls native NSOpenPanel
        // returning XFile paths instantly without bookmark resolving, metadata pre-fetching, or temp file caching.
        const typeGroup = file_selector.XTypeGroup(label: 'any');
        final files = await file_selector.openFiles(
          acceptedTypeGroups: const [typeGroup],
        );

        if (files.isEmpty) return;

        for (final file in files) {
          final length = await file.length();
          newFiles.add(
            SelectedFile(name: file.name, size: length, path: file.path),
          );
        }
      }

      if (!mounted || newFiles.isEmpty) return;

      setState(() {
        for (final file in newFiles) {
          final isDuplicate = _selectedFiles.any(
            (existing) =>
                existing.name == file.name &&
                existing.size == file.size &&
                existing.path == file.path,
          );
          if (!isDuplicate) _selectedFiles.add(file);
        }
        // Transition to SC2 whenever files are selected
        if (_selectedFiles.isNotEmpty) {
          _currentScreen = AppScreen.sc2;
        }
      });
    } catch (error) {
      if (kDebugMode) {
        debugPrint('AirShare: file picker error: $error');
      }
    } finally {
      // BUG-16 FIX: Always release the guard.
      _isPickingFiles = false;
    }
  }

  // ──────────────────────────────────────────────────────────
  // File removal — return home if last file removed
  // ──────────────────────────────────────────────────────────

  void _removeFile(int index) {
    setState(() {
      _selectedFiles.removeAt(index);
      if (_selectedFiles.isEmpty) _currentScreen = AppScreen.home;
    });
  }

  // ──────────────────────────────────────────────────────────
  // Send transfer to device
  // ──────────────────────────────────────────────────────────

  Future<void> _sendTransferToDevice(DiscoveredDevice device) async {
    if (_selectedFiles.isEmpty || _isSendingRequest) return;

    setState(() {
      _isSendingRequest = true;
      _waitingForDeviceName = device.deviceName;
    });

    final filePayloads = _selectedFiles.map((f) {
      return {'name': f.name, 'size': f.size};
    }).toList();

    final outcome = await TransferService.instance.sendTransferRequest(
      targetHost: device.host,
      targetPort: device.port,
      selectedFileDetails: filePayloads,
      senderPort: _httpServer.port,
    );

    if (!mounted) return;

    setState(() {
      _isSendingRequest = false;
      _waitingForDeviceName = null;
    });

    switch (outcome.status) {
      case TransferResultStatus.accepted:
        if (outcome.transferId != null &&
            outcome.transferToken != null &&
            outcome.fileItems != null &&
            outcome.fileItems!.length == _selectedFiles.length) {
          final filesToSend = <FileToSend>[];
          for (int i = 0; i < outcome.fileItems!.length; i++) {
            filesToSend.add(
              FileToSend(
                fileItem: outcome.fileItems![i],
                localPath: _selectedFiles[i].path,
              ),
            );
          }
          // BUG-15/03 FIX: Record the session ID so stale progress updates
          // from a previous transfer cannot flip the screen back to SC3.
          if (mounted) {
            setState(() {
              _activeTransferSessionId = outcome.transferId;
            });
          }
          // SC3 transition driven by _onSendProgressChanged
          TransferService.instance.sendTransferFiles(
            targetHost: device.host,
            targetPort: device.port,
            transferId: outcome.transferId!,
            transferToken: outcome.transferToken!,
            filesToSend: filesToSend,
          );
        }
        break;

      case TransferResultStatus.rejected:
        // Stay on SC2 so the user can pick a different device
        _showModernToast(
          title: 'Request Declined',
          message: '${device.deviceName} declined the transfer request.',
          icon: Icons.cancel_rounded,
          accentColor: const Color(0xFFEF4444),
        );
        break;

      case TransferResultStatus.expired:
        _showModernToast(
          title: 'Request Timed Out',
          message: '${device.deviceName} did not respond in time.',
          icon: Icons.timer_off_rounded,
          accentColor: const Color(0xFFF59E0B),
        );
        break;

      case TransferResultStatus.failed:
        _showModernToast(
          title: 'Transfer Failed',
          message: outcome.message ?? 'Failed to connect to ${device.deviceName}.',
          icon: Icons.error_outline_rounded,
          accentColor: const Color(0xFFEF4444),
        );
        break;
    }
  }

  // ──────────────────────────────────────────────────────────
  // Cancel Request — cancels an outgoing request that is waiting for accept
  // BUG-01 FIX
  // ──────────────────────────────────────────────────────────

  void _cancelOutgoingRequest() {
    // BUG-01 FIX: Cancel the pending transfer request immediately without
    // waiting for the 35-second timeout to expire.
    TransferService.instance.cancelOutgoingRequest(
      // We don't have a local handle to the transferId here; cancelOutgoingRequest
      // works via the internal cancel completer and clears any pending outgoing
      // request, so passing an empty string is a valid sentinel.
      '',
    );
    if (!mounted) return;
    setState(() {
      _isSendingRequest = false;
      _waitingForDeviceName = null;
    });
  }

  // ──────────────────────────────────────────────────────────
  // Cancel confirmation dialog
  // ──────────────────────────────────────────────────────────

  Future<void> _confirmAndCancelTransfer() async {
    final shouldCancel = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Color(0xFF19233A), width: 1),
        ),
        backgroundColor: const Color(0xFF0B1220),
        title: Text(
          'Cancel transfer?',
          style: GoogleFonts.plusJakartaSans(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        content: Text(
          'The current transfer will be stopped.',
          style: GoogleFonts.plusJakartaSans(
            fontSize: 14,
            color: const Color(0xFFCBD5E1),
          ),
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(false),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              foregroundColor: const Color(0xFFCBD5E1),
              side: const BorderSide(color: Color(0xFF263044)),
            ),
            child: const Text('Keep transferring'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              backgroundColor: const Color(0xFFEF4444),
              foregroundColor: Colors.white,
            ),
            child: const Text('Cancel transfer'),
          ),
        ],
      ),
    );

    if (shouldCancel == true && mounted) {
      // BUG-11 FIX: Retrieve active transferId from the correct notifier
      // depending on which direction the active transfer is running.
      final activeTransferId = _transferDirection == TransferDirection.sending
          ? TransferService.instance.sendProgressNotifier.value?.transferId
          : TransferService.instance.receiveProgressNotifier.value?.transferId;

      if (activeTransferId != null) {
        await TransferService.instance.cancelTransfer(activeTransferId);
      } else {
        // BUG-11 FIX: Clear both notifiers to avoid stale state.
        TransferService.instance.sendProgressNotifier.value = null;
        TransferService.instance.receiveProgressNotifier.value = null;
      }

      if (!mounted) return;

      setState(() {
        _selectedFiles.clear();
        _isSendingRequest = false;
        _activeTransferSessionId = null;
        _currentScreen = AppScreen.home;
      });
    }
  }

  // ──────────────────────────────────────────────────────────
  // Done — clear transfer state, return home
  // ──────────────────────────────────────────────────────────

  void _onDone() {
    // BUG-11 FIX: Clear both split progress notifiers.
    // BUG-15/03 FIX: Clear _activeTransferSessionId first so the listener
    // will ignore any in-flight late progress updates that arrive after Done.
    setState(() {
      _activeTransferSessionId = null;
    });
    TransferService.instance.sendProgressNotifier.value = null;
    TransferService.instance.receiveProgressNotifier.value = null;
    setState(() {
      _selectedFiles.clear();
      _isSendingRequest = false;
      _currentScreen = AppScreen.home;
    });
  }

  // ──────────────────────────────────────────────────────────
  // BUILD — routes on AppScreen
  // ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Read from direction-appropriate notifier, with fallback to whichever state is active
    final sendState = TransferService.instance.sendProgressNotifier.value;
    final receiveState = TransferService.instance.receiveProgressNotifier.value;
    final progressState = _transferDirection == TransferDirection.sending
        ? (sendState ?? receiveState)
        : (receiveState ?? sendState);

    // Black Screen Prevention Guard: If screen is SC3 but no progress exists, reset to Home.
    if (_currentScreen == AppScreen.sc3 && progressState == null) {
      _currentScreen = AppScreen.home;
    }

    // BUG-02 FIX: Wrap root with PopScope so the Android Back gesture on SC2
    // returns to Home (or cancels the pending request) instead of exiting.
    return PopScope(
      canPop: _currentScreen == AppScreen.home,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_currentScreen == AppScreen.sc2) {
          if (_isSendingRequest) {
            _cancelOutgoingRequest();
          } else {
            setState(() {
              _selectedFiles.clear();
              _currentScreen = AppScreen.home;
            });
          }
        }
        // SC3 does not allow back navigation — the user must tap Cancel/Done.
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
        },
        child: Scaffold(
          backgroundColor: theme.colorScheme.surface,
          body: SafeArea(
            child: switch (_currentScreen) {
              AppScreen.home => _buildHomeScreen(context),
              AppScreen.sc2 => _buildSC2Screen(context),
              AppScreen.sc3 => _buildSC3Screen(context, progressState),
            },
          ),
        ),
      ),
    );
  }

  // ──────────────────────────────────────────────────────────
  // SHARED HEADER — identical on HOME / SC2 / SC3
  // ──────────────────────────────────────────────────────────

  Widget _buildSharedHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AirShare',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Share files wirelessly with nearby devices.',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF94A3B8),
                    height: 1.25,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: const Color(0xFF131722),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF1E2333), width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: _isWifiOn
                            ? const Color(0xFF10B981)
                            : const Color(0xFF94A3B8),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _isWifiOn ? 'Online' : 'Offline',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: _isWifiOn
                            ? const Color(0xFF10B981)
                            : const Color(0xFF94A3B8),
                      ),
                      textAlign: TextAlign.right,
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 115),
                  child: Text(
                    _deviceName,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────
  // HOME SCREEN
  // S1: header  S2: radar  S3: nearby devices  S4: select files
  // ──────────────────────────────────────────────────────────

  Widget _buildHomeScreen(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSharedHeader(context),
        const SizedBox(height: 16),
        Expanded(
          flex: 5,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _buildRadarCard(context),
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          flex: 4,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: ValueListenableBuilder<List<DiscoveredDevice>>(
              valueListenable: _discoveryService.discoveredDevicesNotifier,
              builder: (context, devices, _) {
                final sorted = List<DiscoveredDevice>.from(devices)
                  ..sort((a, b) => a.deviceId.compareTo(b.deviceId));
                return _buildDiscoveredDevicesList(
                  context: context,
                  devices: sorted,
                  heading: 'Nearby Devices',
                  showArrow: false,
                  onDeviceTap: (_) {
                    _showModernToast(
                      title: 'Select Files First',
                      message:
                          'Tap "Select Files to Send" to choose what to share.',
                      icon: Icons.upload_file_rounded,
                      accentColor: const Color(0xFF6366F1),
                    );
                  },
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 60,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _buildPrimaryFileActionButton(context),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  // ──────────────────────────────────────────────────────────
  // SC2: SELECTED FILES / SELECT DEVICE
  // S1: header  S2: file list  S3: device list  S4: breathing room
  // ──────────────────────────────────────────────────────────

  Widget _buildSC2Screen(BuildContext context) {
    final totalSelectedSize =
        _selectedFiles.fold<int>(0, (s, f) => s + f.size);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // BUG-02 FIX: Shared header with a Back button in SC2 so the user can
        // return to Home without deleting all selected files manually.
        _buildSC2Header(context),
        const SizedBox(height: 14),
        // S2 — selected files (flex 5)
        Expanded(
          flex: 5,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: _buildSC2SelectedFilesPanel(context, totalSelectedSize),
          ),
        ),
        const SizedBox(height: 12),
        // S3 — select device (flex 4)
        Expanded(
          flex: 4,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: _isSendingRequest
                ? _buildSC2WaitingPanel(context)
                : ValueListenableBuilder<List<DiscoveredDevice>>(
                    valueListenable:
                        _discoveryService.discoveredDevicesNotifier,
                    builder: (context, devices, _) {
                      final sorted = List<DiscoveredDevice>.from(devices)
                        ..sort((a, b) => a.deviceId.compareTo(b.deviceId));
                      return _buildDiscoveredDevicesList(
                        context: context,
                        devices: sorted,
                        heading: 'Select device',
                        showArrow: true,
                        onDeviceTap: _sendTransferToDevice,
                      );
                    },
                  ),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  // BUG-02 FIX: Custom header for SC2 that includes a visible Back button so
  // users can return to Home without relying on the system Back gesture.
  Widget _buildSC2Header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 20, 0),
      child: Row(
        children: [
          // Back button
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
            color: const Color(0xFF94A3B8),
            tooltip: 'Back',
            onPressed: _isSendingRequest
                ? null // disabled while waiting — use Cancel Request instead
                : () {
                    setState(() {
                      _selectedFiles.clear();
                      _currentScreen = AppScreen.home;
                    });
                  },
          ),
          Expanded(child: _buildSharedHeader(context)),
        ],
      ),
    );
  }

  Widget _buildSC2SelectedFilesPanel(BuildContext context, int totalSize) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, right: 4, bottom: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Text(
                    'Selected Files',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A233D),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${_selectedFiles.length} · ${_formatFileSize(totalSize)}',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF38BDF8),
                      ),
                    ),
                  ),
                ],
              ),
              InkWell(
                onTap: _pickFiles,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Row(
                    children: [
                      const Icon(Icons.add_rounded,
                          size: 16, color: Color(0xFF38BDF8)),
                      const SizedBox(width: 4),
                      Text(
                        'Add files',
                        style: GoogleFonts.plusJakartaSans(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: const Color(0xFF38BDF8),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF12141D),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF1F2232), width: 1),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: _selectedFiles.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, color: Color(0xFF1F2232)),
                itemBuilder: (context, index) => _buildSC2FileRow(
                  context,
                  _selectedFiles[index],
                  index,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSC2FileRow(
    BuildContext context,
    SelectedFile file,
    int index,
  ) {
    final fileColor = _getFileColor(file.name);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: fileColor.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(_getFileIcon(file.name), color: fileColor, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.name,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Text(
                  _formatFileSize(file.size),
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF8E95A5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: () => _removeFile(index),
            child: Container(
              width: 32,
              height: 32,
              decoration: const BoxDecoration(
                color: Color(0xFF1C2030),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.close_rounded,
                size: 16,
                color: Color(0xFF8E95A5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSC2WaitingPanel(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            'Select device',
            style: GoogleFonts.plusJakartaSans(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF12141D),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF1F2232), width: 1),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(Color(0xFF38BDF8)),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Sending request to ${_waitingForDeviceName ?? 'device'}…',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Waiting for them to accept.',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 12,
                      color: const Color(0xFF8E95A5),
                    ),
                    textAlign: TextAlign.center,
                  ),
                  // BUG-01 FIX: Cancel Request button so the user is not stuck
                  // waiting up to 35 seconds for the receiver to respond.
                  const SizedBox(height: 20),
                  OutlinedButton.icon(
                    onPressed: _cancelOutgoingRequest,
                    icon: const Icon(Icons.cancel_outlined, size: 16),
                    label: Text(
                      'Cancel Request',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFEF4444),
                      side: const BorderSide(
                          color: Color(0xFFEF4444), width: 1),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 10),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ──────────────────────────────────────────────────────────
  // SC3: TRANSFER IN PROGRESS / COMPLETION
  // S1: header  S2: transfer info + file list  S3: Cancel / Done
  // ──────────────────────────────────────────────────────────

  Widget _buildSC3Screen(
      BuildContext context, TransferProgressState? progressState) {
    if (progressState == null) {
      return _buildHomeScreen(context);
    }

    final isTransferring =
        progressState.status == TransferProgressStatus.transferring;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSharedHeader(context),
        const SizedBox(height: 14),
        Expanded(
          flex: 7,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: _buildSC3TransferContent(context, progressState),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 56,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: isTransferring
                ? _buildCancelTransferButton(context)
                : _buildDoneButton(context, progressState),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _buildSC3TransferContent(
      BuildContext context, TransferProgressState state) {
    final theme = Theme.of(context);
    final isCompleted = state.status == TransferProgressStatus.completed;
    final isFailed = state.status == TransferProgressStatus.failed;
    final isCancelled = state.status == TransferProgressStatus.cancelled;

    final Color accentColor;
    final String titleText;

    if (isCompleted) {
      titleText = 'Transfer Complete';
      accentColor = const Color(0xFF10B981);
    } else if (isFailed) {
      titleText = 'Transfer Failed';
      accentColor = const Color(0xFFEF4444);
    } else if (isCancelled) {
      titleText = 'Transfer Cancelled';
      accentColor = const Color(0xFFF59E0B);
    } else {
      titleText = 'Transferring Files';
      accentColor = theme.colorScheme.primary;
    }

    final completedCount = state.files
        .where((f) => f.status == FileTransferStatus.completed)
        .length;
    final fileCountText = isCompleted
        ? '$completedCount of ${state.totalFiles} files'
        : '${state.currentFileIndex} of ${state.totalFiles} files';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              titleText,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                letterSpacing: -0.3,
              ),
            ),
            Text(
              '${(state.overallProgress * 100).toStringAsFixed(0)}%',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 30,
                fontWeight: FontWeight.w800,
                color: accentColor,
                letterSpacing: -0.5,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: state.overallProgress,
            minHeight: 6,
            backgroundColor: const Color(0xFF0B1220),
            valueColor: AlwaysStoppedAnimation<Color>(accentColor),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${_formatFileSize(state.overallBytesTransferred)} / ${_formatFileSize(state.overallTotalBytes)}',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: const Color(0xFFCBD5E1),
              ),
            ),
            Text(
              fileCountText,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF64748B),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          'FILES',
          style: GoogleFonts.plusJakartaSans(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: const Color(0xFF64748B),
            letterSpacing: 1.0,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: state.files.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (context, index) => _buildSC3FileRow(
              context,
              state.files[index],
              accentColor,
              state.status,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSC3FileRow(
    BuildContext context,
    PerFileTransferState f,
    Color transferAccent,
    TransferProgressStatus overallStatus,
  ) {
    final isDone = f.status == FileTransferStatus.completed;
    final isOverallCancelled =
        overallStatus == TransferProgressStatus.cancelled;
    final isOverallFailed = overallStatus == TransferProgressStatus.failed;

    final isActive = !isOverallCancelled &&
        !isOverallFailed &&
        f.status == FileTransferStatus.transferring;
    final isFailed = f.status == FileTransferStatus.failed ||
        (!isDone && isOverallFailed && !isOverallCancelled);
    final isCancelled = f.status == FileTransferStatus.cancelled ||
        (!isDone && isOverallCancelled);

    final Color statusColor;
    final IconData statusIcon;
    final String statusLabel;

    if (isDone) {
      statusColor = const Color(0xFF10B981);
      statusIcon = Icons.check_circle_rounded;
      statusLabel = 'Complete';
    } else if (isCancelled) {
      statusColor = const Color(0xFFF59E0B);
      statusIcon = Icons.cancel_outlined;
      statusLabel = 'Cancelled';
    } else if (isFailed) {
      statusColor = const Color(0xFFEF4444);
      statusIcon = Icons.error_outline_rounded;
      statusLabel = 'Failed';
    } else if (isActive) {
      statusColor = transferAccent;
      statusIcon = Icons.sync_rounded;
      statusLabel = '${(f.progress * 100).toStringAsFixed(0)}%';
    } else {
      statusColor = const Color(0xFF64748B);
      statusIcon = Icons.insert_drive_file_outlined;
      statusLabel = 'Waiting';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isActive ? const Color(0xFF0F1A2E) : const Color(0xFF080E1C),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive
              ? transferAccent.withValues(alpha: 0.35)
              : const Color(0xFF19233A),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(statusIcon, color: statusColor, size: 16),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  f.fileName,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 13,
                    fontWeight: isActive ? FontWeight.bold : FontWeight.w600,
                    color: isActive ? Colors.white : const Color(0xFFCBD5E1),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  isDone
                      ? _formatFileSize(f.fileSize)
                      : isActive
                          ? '${_formatFileSize(f.bytesTransferred)} / ${_formatFileSize(f.fileSize)}'
                          : _formatFileSize(f.fileSize),
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 11,
                    color: const Color(0xFF64748B),
                  ),
                ),
                if (isActive) ...[
                  const SizedBox(height: 5),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: f.progress,
                      minHeight: 3,
                      backgroundColor: const Color(0xFF040711),
                      valueColor:
                          AlwaysStoppedAnimation<Color>(transferAccent),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            statusLabel,
            style: GoogleFonts.plusJakartaSans(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: statusColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCancelTransferButton(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _confirmAndCancelTransfer,
        icon: const Icon(Icons.cancel_outlined, size: 18),
        label: const Text('Cancel Transfer'),
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFFEF4444),
          side: const BorderSide(color: Color(0xFFEF4444), width: 1),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
      ),
    );
  }

  Widget _buildDoneButton(BuildContext context, TransferProgressState state) {
    final isCompleted = state.status == TransferProgressStatus.completed;
    final shadowColor = isCompleted
        ? const Color(0xFF10B981)
        : const Color(0xFF6366F1);

    return SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: isCompleted
                ? [const Color(0xFF10B981), const Color(0xFF059669)]
                : [const Color(0xFF6366F1), const Color(0xFF4F46E5)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: shadowColor.withValues(alpha: 0.30),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ElevatedButton.icon(
          onPressed: _onDone,
          icon: const Icon(Icons.check_rounded, size: 20),
          label: const Text('Done'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            textStyle: GoogleFonts.plusJakartaSans(
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

  // ──────────────────────────────────────────────────────────
  // SHARED: RADAR CARD (S2 on HOME)
  // ──────────────────────────────────────────────────────────

  Widget _buildRadarCard(BuildContext context) {
    const accentColor = Color(0xFF3B82F6);

    return Container(
      height: double.infinity,
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF12141D),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0xFF1F2232), width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Stack(
          alignment: Alignment.center,
          fit: StackFit.expand,
          children: [
            ValueListenableBuilder<List<DiscoveredDevice>>(
              valueListenable: _discoveryService.discoveredDevicesNotifier,
              builder: (context, devices, _) {
                return AnimatedBuilder(
                  animation: _radarAnimationController,
                  builder: (context, _) {
                    return CustomPaint(
                      painter: RadarBackgroundPainter(
                        animationValue: _radarAnimationController.value,
                        accentColor: accentColor,
                        devices: devices,
                        isWifiOn: _isWifiOn,
                      ),
                    );
                  },
                );
              },
            ),
            Center(
              child: Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: const Color(0xFF161E33),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: accentColor.withValues(alpha: 0.6),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: accentColor.withValues(alpha: 0.30),
                      blurRadius: 16,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.wifi_tethering_rounded,
                  size: 26,
                  color: Color(0xFF38BDF8),
                ),
              ),
            ),
            Positioned(
              left: 20,
              right: 20,
              bottom: 20,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _isWifiOn
                        ? 'Scanning for devices...'
                        : 'Turn on WiFi to start scanning.',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Make sure AirShare is open on nearby devices.',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: const Color(0xFF8E95A5),
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ──────────────────────────────────────────────────────────
  // SHARED: DISCOVERED DEVICES LIST (HOME + SC2)
  // ──────────────────────────────────────────────────────────

  Widget _buildDiscoveredDevicesList({
    required BuildContext context,
    required List<DiscoveredDevice> devices,
    required String heading,
    required void Function(DiscoveredDevice) onDeviceTap,
    bool showArrow = true,
  }) {
    const int maxVisible = 3;
    final realCount = devices.length;
    final skeletonCount = math.max(0, maxVisible - realCount);
    final totalSlots = realCount + skeletonCount;
    final scrollable = realCount > maxVisible;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Row(
            children: [
              Text(
                heading,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A233D),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$realCount',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF38BDF8),
                  ),
                ),
              ),
              if (_isWifiOn) ...[
                const SizedBox(width: 8),
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(Color(0xFF38BDF8)),
                  ),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF12141D),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF1F2232), width: 1),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: ListView.separated(
                physics: scrollable
                    ? const AlwaysScrollableScrollPhysics()
                    : const NeverScrollableScrollPhysics(),
                itemCount: totalSlots,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, color: Color(0xFF1F2232)),
                itemBuilder: (context, index) {
                  if (index < realCount) {
                    return _buildDeviceItem(
                      context,
                      devices[index],
                      index,
                      totalSlots,
                      onDeviceTap,
                      showArrow: showArrow,
                    );
                  }
                  return const ShimmerDeviceTile();
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDeviceItem(
    BuildContext context,
    DiscoveredDevice device,
    int index,
    int totalItems,
    void Function(DiscoveredDevice) onTap, {
    bool showArrow = true,
  }) {
    final iconData = _getDeviceIcon(device.deviceName);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _isSendingRequest ? null : () => onTap(device),
        borderRadius: index == 0 && totalItems == 1
            ? BorderRadius.circular(20)
            : index == 0
                ? const BorderRadius.vertical(top: Radius.circular(20))
                : index == totalItems - 1
                    ? const BorderRadius.vertical(bottom: Radius.circular(20))
                    : BorderRadius.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFF1A233D),
                  borderRadius: BorderRadius.circular(12),
                ),
                child:
                    Icon(iconData, size: 20, color: const Color(0xFF38BDF8)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.deviceName,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(
                            color: Color(0xFF10B981),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Nearby · Ready to receive',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: const Color(0xFF8E95A5),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (showArrow)
                Container(
                  width: 32,
                  height: 32,
                  decoration: const BoxDecoration(
                    color: Color(0xFF1C2030),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: Color(0xFF8E95A5),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ──────────────────────────────────────────────────────────
  // SHARED: PRIMARY FILE ACTION BUTTON (HOME S4)
  // ──────────────────────────────────────────────────────────

  Widget _buildPrimaryFileActionButton(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: const LinearGradient(
            colors: [Color(0xFF2563EB), Color(0xFF3B82F6)],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF2563EB).withValues(alpha: 0.35),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ElevatedButton(
          onPressed: _pickFiles,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 20),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.upload_rounded, size: 24, color: Colors.white),
              const SizedBox(width: 12),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Select Files to Send',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    'or drop files here',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                      color: const Color(0xFFDBEAFE),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// CONCENTRIC SUBTLE RADAR PAINTER
// ============================================================
class RadarBackgroundPainter extends CustomPainter {
  RadarBackgroundPainter({
    required this.animationValue,
    required this.accentColor,
    required this.devices,
    this.isWifiOn = true,
  });

  final double animationValue;
  final Color accentColor;
  final List<DiscoveredDevice> devices;
  final bool isWifiOn;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.shortestSide * 0.42;

    final ringPaint = Paint()
      ..color = const Color(0xFF232A44)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    final crosshairPaint = Paint()
      ..color = const Color(0xFF1A2035)
      ..strokeWidth = 1.0;

    for (int i = 1; i <= 4; i++) {
      canvas.drawCircle(center, (maxRadius / 4) * i, ringPaint);
    }

    canvas.drawLine(
      Offset(center.dx - maxRadius, center.dy),
      Offset(center.dx + maxRadius, center.dy),
      crosshairPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - maxRadius),
      Offset(center.dx, center.dy + maxRadius),
      crosshairPaint,
    );

    if (isWifiOn) {
      final pulseProgress = animationValue % 1.0;
      final pulseRadius = maxRadius * pulseProgress;
      final pulseOpacity = (1.0 - pulseProgress).clamp(0.0, 1.0) * 0.15;

      canvas.drawCircle(
        center,
        pulseRadius,
        Paint()
          ..color = accentColor.withValues(alpha: pulseOpacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );

      final sweepAngle = math.pi / 3;
      final startAngle = animationValue * 2 * math.pi;

      final sweepPaint = Paint()
        ..shader = SweepGradient(
          center: Alignment.center,
          startAngle: 0.0,
          endAngle: sweepAngle,
          colors: [
            accentColor.withValues(alpha: 0.0),
            accentColor.withValues(alpha: 0.28),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: maxRadius));

      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(startAngle);
      canvas.drawArc(
        Rect.fromCircle(center: Offset.zero, radius: maxRadius),
        0,
        sweepAngle,
        true,
        sweepPaint,
      );
      canvas.restore();
    }

    // Paint illuminated glowing dots for discovered devices
    for (int i = 0; i < devices.length; i++) {
      final device = devices[i];
      final hash = device.deviceId.hashCode.abs();

      final angle = ((hash % 360) * math.pi / 180.0) + (i * 1.2);
      final radiusStep = 0.35 + ((hash % 50) / 100.0);
      final r = maxRadius * radiusStep;

      final dotOffset = Offset(
        center.dx + r * math.cos(angle),
        center.dy + r * math.sin(angle),
      );

      // Outer glow aura
      final auraPaint = Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFF60A5FA).withValues(alpha: 0.85),
            const Color(0xFF2563EB).withValues(alpha: 0.4),
            const Color(0xFF2563EB).withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.45, 1.0],
        ).createShader(Rect.fromCircle(center: dotOffset, radius: 14));

      canvas.drawCircle(dotOffset, 14, auraPaint);

      // Bright inner core dot
      final corePaint = Paint()
        ..color = const Color(0xFFFFFFFF)
        ..style = PaintingStyle.fill;

      canvas.drawCircle(dotOffset, 3.5, corePaint);
    }
  }

  @override
  bool shouldRepaint(covariant RadarBackgroundPainter oldDelegate) {
    return oldDelegate.animationValue != animationValue ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.devices != devices ||
        oldDelegate.isWifiOn != isWifiOn;
  }
}

// ============================================================
// SHIMMER / WAVE EFFECT PLACEHOLDER
// ============================================================
class ShimmerDeviceTile extends StatefulWidget {
  const ShimmerDeviceTile({super.key});

  @override
  State<ShimmerDeviceTile> createState() => _ShimmerDeviceTileState();
}

class _ShimmerDeviceTileState extends State<ShimmerDeviceTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(
            children: [
              _buildShimmerBox(width: 44, height: 44, borderRadius: 12),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildShimmerBox(width: 130, height: 14, borderRadius: 4),
                    const SizedBox(height: 6),
                    _buildShimmerBox(width: 90, height: 11, borderRadius: 4),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _buildShimmerBox(width: 32, height: 32, borderRadius: 16),
            ],
          ),
        );
      },
    );
  }

  Widget _buildShimmerBox({
    required double width,
    required double height,
    required double borderRadius,
  }) {
    final shimmerPosition = _controller.value;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        gradient: LinearGradient(
          begin: Alignment(-1.5 + (shimmerPosition * 3.5), 0),
          end: Alignment(-0.3 + (shimmerPosition * 3.5), 0),
          colors: const [
            Color(0xFF151826),
            Color(0xFF20263B),
            Color(0xFF151826),
          ],
          stops: const [0.0, 0.5, 1.0],
        ),
      ),
    );
  }
}
