import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
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
      primary: Color(0xFF6366F1),
      onPrimary: Color(0xFFFFFFFF),
      primaryContainer: Color(0xFF312E81),
      onPrimaryContainer: Color(0xFFE0E7FF),
      secondary: Color(0xFF38BDF8),
      onSecondary: Color(0xFFFFFFFF),
      secondaryContainer: Color(0xFF075985),
      onSecondaryContainer: Color(0xFFE0F2FE),
      surface: Color(0xFF040711),
      onSurface: Color(0xFFFFFFFF),
      surfaceContainerLowest: Color(0xFF070B14),
      surfaceContainerHigh: Color(0xFF0B1220),
      onSurfaceVariant: Color(0xFF94A3B8),
      outline: Color(0xFF263044),
      outlineVariant: Color(0xFF19233A),
      error: Color(0xFFEF4444),
      onError: Color(0xFFFFFFFF),
    );

    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Color(0xFF040711),
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );

    final sharedDialogTheme = DialogThemeData(
      backgroundColor: const Color(0xFF0B1220),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: Color(0xFF19233A), width: 1),
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
        scaffoldBackgroundColor: const Color(0xFF040711),
        textTheme: textTheme,
        useMaterial3: true,
        dialogTheme: sharedDialogTheme,
      ),
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: darkColorScheme,
        scaffoldBackgroundColor: const Color(0xFF040711),
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

  // ── Transfer request state ────────────────────────────────
  bool _isSendingRequest = false;
  String? _waitingForDeviceName;
  bool _isIncomingDialogOpen = false;

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

    TransferService.instance.progressNotifier
        .addListener(_onTransferProgressChanged);

    _startServicesIfForeground();
  }

  @override
  void dispose() {
    _radarAnimationController.dispose();
    TransferService.instance.incomingRequestNotifier
        .removeListener(_onIncomingTransferRequest);
    TransferService.instance.progressNotifier
        .removeListener(_onTransferProgressChanged);
    WidgetsBinding.instance.removeObserver(this);
    _stopServices();
    super.dispose();
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

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => IncomingTransferDialog(request: request),
    ).then((_) {
      _isIncomingDialogOpen = false;
      if (TransferService.instance.incomingRequestNotifier.value?.transferId ==
          request.transferId) {
        TransferService.instance.incomingRequestNotifier.value = null;
      }
    });
  }

  // ──────────────────────────────────────────────────────────
  // Transfer progress → drives SC3
  // ──────────────────────────────────────────────────────────

  void _onTransferProgressChanged() {
    if (!mounted) return;
    setState(() {
      final p = TransferService.instance.progressNotifier.value;
      if (p != null) {
        _currentScreen = AppScreen.sc3;
        _waitingForDeviceName = null;
        _isSendingRequest = false;
      }
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
        content: Container(
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
    );
  }

  // ──────────────────────────────────────────────────────────
  // File picker — transition to SC2 after selection
  // ──────────────────────────────────────────────────────────

  Future<void> _pickFiles() async {
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
        final result = await FilePicker.platform.pickFiles(
          allowMultiple: true,
          withData: false,
          withReadStream: false,
        );

        if (result == null || result.files.isEmpty) return;

        for (final file in result.files) {
          if (file.path == null) continue;
          newFiles.add(
            SelectedFile(name: file.name, size: file.size, path: file.path!),
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
          // SC3 transition driven by _onTransferProgressChanged
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
      final activeTransferId =
          TransferService.instance.progressNotifier.value?.transferId;

      if (activeTransferId != null) {
        await TransferService.instance.cancelTransfer(activeTransferId);
      } else {
        TransferService.instance.progressNotifier.value = null;
      }

      if (!mounted) return;

      setState(() {
        _selectedFiles.clear();
        _isSendingRequest = false;
        _currentScreen = AppScreen.home;
      });
    }
  }

  // ──────────────────────────────────────────────────────────
  // Done — clear transfer state, return home
  // ──────────────────────────────────────────────────────────

  void _onDone() {
    TransferService.instance.progressNotifier.value = null;
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
    final progressState = TransferService.instance.progressNotifier.value;

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        child: switch (_currentScreen) {
          AppScreen.home => _buildHomeScreen(context),
          AppScreen.sc2 => _buildSC2Screen(context),
          AppScreen.sc3 => _buildSC3Screen(context, progressState),
        },
      ),
    );
  }

  // ──────────────────────────────────────────────────────────
  // SHARED HEADER — identical on HOME / SC2 / SC3
  // ──────────────────────────────────────────────────────────

  Widget _buildSharedHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
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
                    fontSize: 26,
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
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: const Color(0xFF0B1220),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF19233A), width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Online',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF10B981),
                      ),
                      textAlign: TextAlign.right,
                    ),
                    const SizedBox(width: 5),
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: Color(0xFF10B981),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 120),
                  child: Text(
                    _deviceName,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 12,
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
        const SizedBox(height: 14),
        Expanded(
          flex: 5,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: _buildRadarCard(context),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          flex: 3,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: ValueListenableBuilder<List<DiscoveredDevice>>(
              valueListenable: _discoveryService.discoveredDevicesNotifier,
              builder: (context, devices, _) {
                final sorted = List<DiscoveredDevice>.from(devices)
                  ..sort((a, b) => a.deviceId.compareTo(b.deviceId));
                return _buildDiscoveredDevicesList(
                  context: context,
                  devices: sorted,
                  heading: 'Nearby Devices',
                  onDeviceTap: (_) {
                    _showModernToast(
                      title: 'Select Files First',
                      message: 'Tap "Select Files to Send" to choose what to share.',
                      icon: Icons.upload_file_rounded,
                      accentColor: const Color(0xFF6366F1),
                    );
                  },
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 56,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: _buildPrimaryFileActionButton(context),
          ),
        ),
        const SizedBox(height: 12),
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
        _buildSharedHeader(context),
        const SizedBox(height: 14),
        // S2 — selected files (flex 5)
        Expanded(
          flex: 5,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: _buildSC2SelectedFilesPanel(context, totalSelectedSize),
          ),
        ),
        const SizedBox(height: 10),
        // S3 — select device (flex 3)
        Expanded(
          flex: 3,
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
                        onDeviceTap: _sendTransferToDevice,
                      );
                    },
                  ),
          ),
        ),
        // S4 — 56px breathing room
        const SizedBox(height: 8),
        const SizedBox(height: 56),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _buildSC2SelectedFilesPanel(BuildContext context, int totalSize) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Text(
                  'Selected Files',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6366F1).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${_selectedFiles.length} · ${_formatFileSize(totalSize)}',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF818CF8),
                    ),
                  ),
                ),
              ],
            ),
            TextButton.icon(
              onPressed: _pickFiles,
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('Add files'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: const Color(0xFF818CF8),
                textStyle: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF0B1220),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF19233A), width: 1),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: _selectedFiles.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, color: Color(0xFF19233A)),
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: fileColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(_getFileIcon(file.name), color: fileColor, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.name,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  _formatFileSize(file.size),
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 11,
                    color: const Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => _removeFile(index),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: const Color(0xFF19233A),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.close_rounded,
                size: 15,
                color: Color(0xFF64748B),
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
        Text(
          'Select device',
          style: GoogleFonts.plusJakartaSans(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF0B1220),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF19233A), width: 1),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(Color(0xFF6366F1)),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Sending request to ${_waitingForDeviceName ?? 'device'}…',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Waiting for them to accept.',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 12,
                      color: const Color(0xFF64748B),
                    ),
                    textAlign: TextAlign.center,
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
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _currentScreen = AppScreen.home);
      });
      return const SizedBox.shrink();
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
            itemBuilder: (context, index) =>
                _buildSC3FileRow(context, state.files[index], accentColor),
          ),
        ),
      ],
    );
  }

  Widget _buildSC3FileRow(
    BuildContext context,
    PerFileTransferState f,
    Color transferAccent,
  ) {
    final isActive = f.status == FileTransferStatus.transferring;
    final isDone = f.status == FileTransferStatus.completed;
    final isFailed = f.status == FileTransferStatus.failed;
    final isCancelled = f.status == FileTransferStatus.cancelled;

    final Color statusColor;
    final IconData statusIcon;
    final String statusLabel;

    if (isDone) {
      statusColor = const Color(0xFF10B981);
      statusIcon = Icons.check_circle_rounded;
      statusLabel = 'Complete';
    } else if (isFailed) {
      statusColor = const Color(0xFFEF4444);
      statusIcon = Icons.error_outline_rounded;
      statusLabel = 'Failed';
    } else if (isCancelled) {
      statusColor = const Color(0xFFF59E0B);
      statusIcon = Icons.cancel_outlined;
      statusLabel = 'Cancelled';
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
    final accentColor = const Color(0xFF6366F1);

    return Container(
      height: double.infinity,
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF0B1220),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF19233A), width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          alignment: Alignment.center,
          fit: StackFit.expand,
          children: [
            AnimatedBuilder(
              animation: _radarAnimationController,
              builder: (context, _) {
                return CustomPaint(
                  painter: RadarBackgroundPainter(
                    animationValue: _radarAnimationController.value,
                    accentColor: accentColor,
                  ),
                );
              },
            ),
            Center(
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xFF0B1220),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: accentColor.withValues(alpha: 0.4),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: accentColor.withValues(alpha: 0.15),
                      blurRadius: 10,
                    ),
                  ],
                ),
                child: Icon(
                  Icons.wifi_tethering_rounded,
                  size: 24,
                  color: accentColor,
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Scanning for devices...',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Make sure AirShare is open on nearby devices.',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: const Color(0xFF64748B),
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
          padding: const EdgeInsets.only(left: 2, bottom: 8),
          child: Row(
            children: [
              Text(
                heading,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                decoration: BoxDecoration(
                  color: const Color(0xFF6366F1).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$realCount',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF818CF8),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(Color(0xFF818CF8)),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF0B1220),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF19233A), width: 1),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: ListView.separated(
                physics: scrollable
                    ? const AlwaysScrollableScrollPhysics()
                    : const NeverScrollableScrollPhysics(),
                itemCount: totalSlots,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, color: Color(0xFF19233A)),
                itemBuilder: (context, index) {
                  if (index < realCount) {
                    return _buildDeviceItem(
                      context,
                      devices[index],
                      index,
                      totalSlots,
                      onDeviceTap,
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
    void Function(DiscoveredDevice) onTap,
  ) {
    final iconData = _getDeviceIcon(device.deviceName);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _isSendingRequest ? null : () => onTap(device),
        borderRadius: index == 0 && totalItems == 1
            ? BorderRadius.circular(16)
            : index == 0
                ? const BorderRadius.vertical(top: Radius.circular(16))
                : index == totalItems - 1
                    ? const BorderRadius.vertical(bottom: Radius.circular(16))
                    : BorderRadius.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: const Color(0xFF6366F1).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child:
                    Icon(iconData, size: 18, color: const Color(0xFF818CF8)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.deviceName,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
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
                        const SizedBox(width: 5),
                        Text(
                          'Nearby · Ready to receive',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: const Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: Color(0xFF64748B),
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
          borderRadius: BorderRadius.circular(16),
          gradient: const LinearGradient(
            colors: [Color(0xFF6366F1), Color(0xFF4F46E5)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF6366F1).withValues(alpha: 0.35),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ElevatedButton.icon(
          onPressed: _pickFiles,
          icon: const Icon(Icons.upload_file_rounded, size: 21),
          label: const Text('Select Files to Send'),
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
              letterSpacing: 0.2,
            ),
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
  });

  final double animationValue;
  final Color accentColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.shortestSide * 0.42;

    final ringPaint = Paint()
      ..color = accentColor.withValues(alpha: 0.06)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    final crosshairPaint = Paint()
      ..color = accentColor.withValues(alpha: 0.04)
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

    final pulseProgress = animationValue % 1.0;
    final pulseRadius = maxRadius * pulseProgress;
    final pulseOpacity = (1.0 - pulseProgress).clamp(0.0, 1.0) * 0.12;

    canvas.drawCircle(
      center,
      pulseRadius,
      Paint()
        ..color = accentColor.withValues(alpha: pulseOpacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    final sweepAngle = math.pi / 4;
    final startAngle = animationValue * 2 * math.pi;

    final sweepPaint = Paint()
      ..shader = SweepGradient(
        center: Alignment.center,
        startAngle: 0.0,
        endAngle: sweepAngle,
        colors: [
          accentColor.withValues(alpha: 0.0),
          accentColor.withValues(alpha: 0.10),
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

  @override
  bool shouldRepaint(covariant RadarBackgroundPainter oldDelegate) {
    return oldDelegate.animationValue != animationValue ||
        oldDelegate.accentColor != accentColor;
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
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            children: [
              _buildShimmerBox(width: 32, height: 32, borderRadius: 10),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildShimmerBox(width: 130, height: 12, borderRadius: 4),
                    const SizedBox(height: 6),
                    _buildShimmerBox(width: 90, height: 10, borderRadius: 4),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _buildShimmerBox(width: 14, height: 14, borderRadius: 7),
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
            Color(0xFF1E293B),
            Color(0xFF263044),
            Color(0xFF1E293B),
          ],
          stops: const [0.0, 0.5, 1.0],
        ),
      ),
    );
  }
}
