import 'package:flutter/material.dart';
import 'package:n_ui/n_ui.dart';

import '../platform/bridge.dart';

/// Shows the interactive Device Permissions & GPS Setup modal.
Future<void> showPermissionsSetupDialog(
  BuildContext context, {
  VoidCallback? onPermissionsChanged,
}) async {
  final isMobile = MediaQuery.sizeOf(context).width < 600;

  if (isMobile) {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _PermissionsDialogContent(
        isModal: true,
        onPermissionsChanged: onPermissionsChanged,
      ),
    );
  } else {
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: _PermissionsDialogContent(
            isModal: false,
            onPermissionsChanged: onPermissionsChanged,
          ),
        ),
      ),
    );
  }
}

class _PermissionsDialogContent extends StatefulWidget {
  const _PermissionsDialogContent({
    required this.isModal,
    this.onPermissionsChanged,
  });

  final bool isModal;
  final VoidCallback? onPermissionsChanged;

  @override
  State<_PermissionsDialogContent> createState() => _PermissionsDialogContentState();
}

class _PermissionsDialogContentState extends State<_PermissionsDialogContent> {
  bool _loading = true;
  PermissionStatusReport? _report;
  GeoReading? _latestFix;
  String? _statusMessage;
  bool _isRequestingLoc = false;
  bool _isRequestingNotif = false;
  bool _isTestingCam = false;
  bool _showTroubleshootLoc = false;
  bool _showTroubleshootNotif = false;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    setState(() => _loading = true);
    try {
      final rep = await bridge.checkPermissions();
      // If location is already granted or can be read, attempt a test reading
      if (rep.location == AppPermissionState.granted) {
        try {
          _latestFix = await bridge.currentPosition(timeout: const Duration(seconds: 4));
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          _report = rep;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _requestLocation() async {
    setState(() {
      _isRequestingLoc = true;
      _statusMessage = null;
    });

    try {
      final res = await bridge.requestLocationPermission();
      if (res['ok'] == true) {
        final lat = (res['lat'] as num?)?.toDouble() ?? 0.0;
        final lng = (res['lng'] as num?)?.toDouble() ?? 0.0;
        final acc = (res['accuracy'] as num?)?.toDouble() ?? 0.0;
        _latestFix = GeoReading(latitude: lat, longitude: lng, accuracyMeters: acc);
        if (mounted) {
          NToast.of(context).show('✓ GPS location access granted successfully!');
        }
      } else {
        if (mounted) {
          setState(() {
            _showTroubleshootLoc = true;
            _statusMessage = 'Location access was not granted. Follow the instructions below to enable it in your browser.';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _showTroubleshootLoc = true;
          _statusMessage = 'Could not access location: $e';
        });
      }
    } finally {
      await _checkPermissions();
      if (mounted) {
        setState(() => _isRequestingLoc = false);
        widget.onPermissionsChanged?.call();
      }
    }
  }

  Future<void> _requestNotifications() async {
    setState(() => _isRequestingNotif = true);
    try {
      final status = await bridge.requestNotificationPermission();
      if (status == 'granted') {
        if (mounted) {
          NToast.of(context).show('✓ Push notifications enabled!');
        }
      } else if (status == 'denied') {
        if (mounted) {
          setState(() => _showTroubleshootNotif = true);
        }
      }
    } catch (_) {
    } finally {
      await _checkPermissions();
      if (mounted) {
        setState(() => _isRequestingNotif = false);
        widget.onPermissionsChanged?.call();
      }
    }
  }

  Future<void> _testCamera() async {
    setState(() => _isTestingCam = true);
    try {
      final res = await bridge.requestCameraPermission();
      if (res['ok'] == true) {
        if (mounted) {
          NToast.of(context).show('✓ Front camera access is ready for selfie check-in!');
        }
      } else {
        if (mounted) {
          NToast.of(context).show('Camera permission was denied: ${res['message'] ?? 'Please allow camera access'}');
        }
      }
    } catch (_) {
    } finally {
      await _checkPermissions();
      if (mounted) {
        setState(() => _isTestingCam = false);
        widget.onPermissionsChanged?.call();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    final os = _report?.os ?? 'Device';
    final browser = _report?.browser ?? 'Browser';

    return Container(
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: widget.isModal ? const BorderRadius.vertical(top: Radius.circular(20)) : BorderRadius.circular(20),
        border: widget.isModal ? null : Border.all(color: t.cardBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 24,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: EdgeInsets.fromLTRB(18, 14, 18, 18 + bottomInset),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.90,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Modal drag handle
            if (widget.isModal)
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: t.divider,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

            // Header Row
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: t.accent.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.security_rounded, color: t.accent, size: 22),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Device & App Permissions',
                        style: t.text.title(size: 16).copyWith(fontWeight: FontWeight.w800),
                      ),
                      Text(
                        'Configure permissions required for GPS attendance, alerts & selfies',
                        style: t.text.caption(color: t.muted),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Detected Device Chip
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: t.isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(NTokens.radiusPill),
                border: Border.all(color: t.divider.withValues(alpha: 0.5)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _report?.isMobile == true ? Icons.smartphone_rounded : Icons.laptop_rounded,
                    size: 14,
                    color: t.accent,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Detected: $os · $browser ${_report?.isPwa == true ? "(Installed App)" : "(Web App)"}',
                    style: t.text.caption(weight: FontWeight.w700).copyWith(fontSize: 11, color: t.ink),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            if (_statusMessage != null) ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: t.amber.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: t.amber.withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline_rounded, size: 16, color: t.amber),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_statusMessage!, style: t.text.caption(color: t.amber)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],

            // 1. GPS / Location Permission Card
            _PermissionItemCard(
              icon: Icons.location_on_rounded,
              title: 'GPS & Geofence Location',
              subtitle: 'Required to verify you are within the workplace perimeter during attendance check-in.',
              state: _report?.location ?? AppPermissionState.prompt,
              details: _latestFix != null
                  ? 'Active GPS fix: ±${_latestFix!.accuracyMeters.round()}m accuracy (${_latestFix!.latitude.toStringAsFixed(4)}, ${_latestFix!.longitude.toStringAsFixed(4)})'
                  : null,
              actionLabel: _isRequestingLoc ? 'Prompting...' : 'Allow GPS Location',
              isLoading: _isRequestingLoc,
              onRequest: _requestLocation,
              onToggleTroubleshoot: () => setState(() => _showTroubleshootLoc = !_showTroubleshootLoc),
              showTroubleshoot: _showTroubleshootLoc,
              troubleshootGuide: _buildLocationGuide(os, browser),
              t: t,
            ),
            const SizedBox(height: 10),

            // 2. Push Notifications Card
            _PermissionItemCard(
              icon: Icons.notifications_active_rounded,
              title: 'Push & System Notifications',
              subtitle: 'Shift start/end reminders, check-out alerts at 6 PM, and urgent manager approvals.',
              state: _report?.notifications ?? AppPermissionState.prompt,
              details: _report?.notifications == AppPermissionState.granted ? 'Push notifications active on this browser.' : null,
              actionLabel: _isRequestingNotif ? 'Requesting...' : 'Enable Notifications',
              isLoading: _isRequestingNotif,
              onRequest: _requestNotifications,
              onToggleTroubleshoot: () => setState(() => _showTroubleshootNotif = !_showTroubleshootNotif),
              showTroubleshoot: _showTroubleshootNotif,
              troubleshootGuide: _buildNotificationGuide(os, browser),
              t: t,
            ),
            const SizedBox(height: 10),

            // 3. Camera / Face Verification Card
            _PermissionItemCard(
              icon: Icons.camera_front_rounded,
              title: 'Camera & Face Selfie Access',
              subtitle: 'Used for verified photo proof during attendance check-in and check-out.',
              state: _report?.camera ?? AppPermissionState.prompt,
              details: _report?.camera == AppPermissionState.granted ? 'Camera access is granted and verified.' : 'Will prompt automatically when snapping attendance selfie.',
              actionLabel: _isTestingCam ? 'Testing...' : 'Test Camera Access',
              isLoading: _isTestingCam,
              onRequest: _testCamera,
              onToggleTroubleshoot: null,
              showTroubleshoot: false,
              troubleshootGuide: null,
              t: t,
            ),
            const SizedBox(height: 16),

            // Footer actions: Refresh & Done
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: _loading
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('Recheck All'),
                    onPressed: _loading ? null : _checkPermissions,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: NButton(
                    label: 'Done',
                    icon: Icons.check_rounded,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLocationGuide(String os, String browser) {
    if (os == 'iOS') {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('How to enable Location in iOS Safari:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
          SizedBox(height: 4),
          Text('1. Tap the "aA" or Page Settings icon on the left side of the Safari address bar.'),
          Text('2. Tap "Website Settings".'),
          Text('3. Under "Location", choose "Allow".'),
          Text('4. Tap "Done", return here and tap "Recheck All" below!'),
          SizedBox(height: 4),
          Text('💡 Tip: In iPhone Settings > Privacy & Security > Location Services, ensure Safari Websites is set to "While Using the App".', style: TextStyle(fontStyle: FontStyle.italic, fontSize: 10)),
        ],
      );
    } else if (os == 'Android') {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('How to enable Location in Android Chrome:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
          SizedBox(height: 4),
          Text('1. Tap the Lock icon 🔒 or Tune icon on the left of the address bar.'),
          Text('2. Tap "Permissions" > "Location".'),
          Text('3. Toggle Location to "Allow".'),
          Text('4. Return here and tap "Recheck All" below!'),
        ],
      );
    } else {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('How to enable Location on Desktop PC / Laptop:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
          SizedBox(height: 4),
          Text('1. Click the Lock/Tune icon 🔒 on the left side of your browser URL bar.'),
          Text('2. Set "Location" to "Allow" or toggle it to ON.'),
          Text('3. Return here and tap "Recheck All" below!'),
        ],
      );
    }
  }

  Widget _buildNotificationGuide(String os, String browser) {
    if (os == 'iOS') {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('How to enable Notifications in iOS:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
          SizedBox(height: 4),
          Text('1. For iOS Web Push, tap the Share icon 📤 in Safari and select "Add to Home Screen".'),
          Text('2. Open Signal HRM from your Home Screen to receive instant push alerts!'),
        ],
      );
    } else {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('How to enable Notifications in your browser:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
          SizedBox(height: 4),
          Text('1. Click the Lock/Tune icon 🔒 next to the web address.'),
          Text('2. Set "Notifications" to "Allow".'),
          Text('3. Tap "Recheck All" below!'),
        ],
      );
    }
  }
}

class _PermissionItemCard extends StatelessWidget {
  const _PermissionItemCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.state,
    this.details,
    required this.actionLabel,
    required this.isLoading,
    required this.onRequest,
    this.onToggleTroubleshoot,
    required this.showTroubleshoot,
    this.troubleshootGuide,
    required this.t,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final AppPermissionState state;
  final String? details;
  final String actionLabel;
  final bool isLoading;
  final VoidCallback onRequest;
  final VoidCallback? onToggleTroubleshoot;
  final bool showTroubleshoot;
  final Widget? troubleshootGuide;
  final NTokens t;

  @override
  Widget build(BuildContext context) {
    final isGranted = state == AppPermissionState.granted;
    final isDenied = state == AppPermissionState.denied;

    final badgeColor = isGranted ? t.green : (isDenied ? t.amber : t.accent);
    final badgeText = isGranted
        ? '✓ Granted'
        : (isDenied ? '⚠️ Action Required' : 'Not Enabled');

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(t.radiusCard),
        border: Border.all(
          color: (isGranted ? t.green : (isDenied ? t.amber : t.cardBorder)).withValues(alpha: 0.5),
          width: 1.2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 18, color: badgeColor),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: t.text.body(weight: FontWeight.w700).copyWith(fontSize: 13),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: t.isDark ? 0.25 : 0.12),
                  borderRadius: BorderRadius.circular(NTokens.radiusPill),
                  border: Border.all(color: badgeColor.withValues(alpha: 0.5)),
                ),
                child: Text(
                  badgeText,
                  style: TextStyle(
                    color: badgeColor,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(subtitle, style: t.text.caption(color: t.muted)),
          if (details != null) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: t.green.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                details!,
                style: t.text.caption(color: t.green).copyWith(fontSize: 10.5, fontWeight: FontWeight.w600),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              if (!isGranted)
                FilledButton.tonalIcon(
                  icon: isLoading
                      ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.touch_app_rounded, size: 14),
                  label: Text(actionLabel, style: const TextStyle(fontSize: 11)),
                  onPressed: isLoading ? null : onRequest,
                )
              else
                OutlinedButton.icon(
                  icon: const Icon(Icons.check_circle_rounded, size: 14, color: Colors.green),
                  label: const Text('Configured', style: TextStyle(fontSize: 11)),
                  onPressed: onRequest,
                ),
              if (onToggleTroubleshoot != null) ...[
                const SizedBox(width: 8),
                TextButton.icon(
                  icon: Icon(
                    showTroubleshoot ? Icons.expand_less_rounded : Icons.help_outline_rounded,
                    size: 14,
                  ),
                  label: Text(
                    showTroubleshoot ? 'Hide help' : 'How to unblock',
                    style: const TextStyle(fontSize: 10.5),
                  ),
                  onPressed: onToggleTroubleshoot,
                ),
              ],
            ],
          ),
          if (showTroubleshoot && troubleshootGuide != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: t.isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: t.divider),
              ),
              child: DefaultTextStyle(
                style: t.text.caption().copyWith(fontSize: 10.5, height: 1.4),
                child: troubleshootGuide!,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
