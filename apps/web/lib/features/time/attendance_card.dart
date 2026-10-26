import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:n_ui/n_ui.dart';

import '../../app/config.dart';
import '../../app/services.dart';
import '../../data/api.dart';
import '../../platform/bridge.dart';
import '../../platform/geocoding.dart';
import '../../widgets/async_view.dart';
import '../../widgets/authed_image.dart';
import '../../widgets/format.dart';
import '../../widgets/geofence_map.dart';
import '../../widgets/permissions_dialog.dart';
import '../../widgets/set_office_location_dialog.dart';
import '../../widgets/status.dart';

class _CapturedSelfie {
  const _CapturedSelfie({required this.fileId, required this.bytes});
  final String fileId;
  final Uint8List bytes;
}

/// Offline punches: kept in this browser until the network returns, then sent with their original
/// Idempotency-Key and `queuedOffline: true`. The server still stamps its own time; when the gap is
/// large it opens a correction request instead of trusting the device clock.
class PunchQueue {
  static const _key = 'shrm_punch_queue';

  static List<Json> read() {
    try {
      final raw = bridge.readLocal(_key);
      if (raw == null) return [];
      return [for (final e in jsonDecode(raw) as List) (e as Map).cast<String, dynamic>()];
    } catch (_) {
      return [];
    }
  }

  static void _write(List<Json> q) => bridge.writeLocal(_key, q.isEmpty ? null : jsonEncode(q));

  static void add(String action, String key, Json body) {
    final q = read()..removeWhere((e) => e['action'] == action);
    q.add({'action': action, 'key': key, 'body': {...body, 'queuedOffline': true, 'clientRecordedAt': DateTime.now().toUtc().toIso8601String()}});
    _write(q);
  }

  /// Sends queued punches in order. Returns how many were accepted.
  static Future<int> flush(ApiClient api) async {
    var sent = 0;
    for (final e in read()) {
      try {
        await api.post('/attendance/${e['action']}', body: e['body'], idempotencyKey: '${e['key']}');
        sent++;
        _write(read()..removeWhere((x) => x['key'] == e['key']));
      } on ApiException catch (err) {
        if (err.isNetwork) break; // still offline
        _write(read()..removeWhere((x) => x['key'] == e['key'])); // rejected: drop, the user sees today's state
      }
    }
    return sent;
  }
}

/// Today's attendance with multi-step break tracking and day count calculation:
/// 1. Check In (Session 1 Start)
/// 2. Break In (Lunch / Break Start) -> 0.5 Day Counted
/// 3. Break Out (Session 2 Start / Break Return)
/// 4. Check Out (Day Complete) -> 1.0 Full Day Counted (2 Check-ins + 2 Check-outs)
class AttendanceTodayCard extends StatefulWidget {
  const AttendanceTodayCard({super.key, this.compact = false, this.onChanged});
  final bool compact;
  final VoidCallback? onChanged;

  @override
  State<AttendanceTodayCard> createState() => _AttendanceTodayCardState();
}

enum _Phase { idle, locating, selfie, sending }

class _AttendanceTodayCardState extends State<AttendanceTodayCard> {
  final _view = GlobalKey<AsyncViewState<Json>>();
  _Phase _phase = _Phase.idle;
  String? _attemptKey;
  ApiException? _problem;
  GeoReading? _lastFix;
  String _lastStatus = 'not_requested';
  StreamSubscription<bool>? _online;
  int _queued = PunchQueue.read().length;

  Uint8List? _checkInPhotoBytes;
  Uint8List? _checkOutPhotoBytes;
  String? _checkInAddress;
  String? _checkOutAddress;
  final Map<String, String> _resolvedAddresses = {};

  bool _refreshingLocation = false;
  bool _showGeofenceMap = false;
  String? _liveAddress;
  double? _liveDistanceMeters;
  bool? _isInsideGeofence;
  String? _liveLocationError;

  @override
  void initState() {
    super.initState();
    _online = bridge.onlineChanges.listen((on) {
      if (on) _flush();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _flush());
  }

  @override
  void dispose() {
    _online?.cancel();
    super.dispose();
  }

  Future<void> _flush() async {
    if (PunchQueue.read().isEmpty || !mounted) return;
    final n = await PunchQueue.flush(context.api);
    if (!mounted) return;
    setState(() => _queued = PunchQueue.read().length);
    if (n > 0) {
      NToast.of(context).show('Offline punch synced.');
      _view.currentState?.reload();
      widget.onChanged?.call();
    }
  }

  Future<_CapturedSelfie?> _takeSelfie(
    bool checkIn,
    String? locationName, {
    String? locationAddress,
    String? stepTitle,
  }) async {
    final api = context.api;
    if (!mounted) return null;
    final picked = await showNSheet<PickedFile?>(
      context,
      title: stepTitle ?? (checkIn ? 'Check-in photo' : 'Check-out photo'),
      subtitle: 'Capture attendance photo to verify your punch.',
      builder: (ctx) => _SelfieSheet(
        isCheckIn: checkIn,
        locationName: locationName,
        locationAddress: locationAddress,
        stepTitle: stepTitle,
      ),
    );

    if (picked == null || !mounted) return null;
    setState(() => _phase = _Phase.sending);
    final rec = await api.upload(picked, purpose: 'selfie');
    final id = rec['id'] as String?;
    if (id == null) return null;
    return _CapturedSelfie(fileId: id, bytes: picked.bytes);
  }

  Future<void> _punch(Json today, {String? exceptionReason, bool remote = false}) async {
    final state = '${today['state']}';
    final isCheckIn = state != 'checked_in';
    final action = isCheckIn ? 'check-in' : 'check-out';
    final req = jsonMap(jsonMap(today['requirements'])[isCheckIn ? 'checkIn' : 'checkOut']);
    final needLocation = req['requireLocation'] != false;
    // Always enable selfie photo verification for attendance punches
    final needSelfie = req['requireSelfie'] != false;

    final stepTitle = isCheckIn ? 'Check-in photo' : 'Check-out photo';

    _attemptKey ??= newIdempotencyKey();
    setState(() => _problem = null);
    final body = <String, dynamic>{};
    try {
      // 1. Geolocation verification first so we know if user is inside or outside company area
      String? resolvedAddress;
      if (needLocation) {
        setState(() => _phase = _Phase.locating);
        try {
          final fix = await bridge.currentPosition();
          _lastFix = fix;
          _lastStatus = 'granted';
        } on GeoException catch (g) {
          _lastFix = null;
          _lastStatus = switch (g.failure) {
            GeoFailure.denied => 'denied',
            GeoFailure.timeout => 'timeout',
            _ => 'unavailable',
          };
        } catch (_) {
          _lastFix = null;
          _lastStatus = 'unavailable';
        }
        if (AppConfig.demo && _lastFix == null) {
          _lastFix = const GeoReading(latitude: 23.0225, longitude: 72.5714, accuracyMeters: 12);
          _lastStatus = 'granted';
        }
        body['locationStatus'] = _lastStatus;
        if (_lastFix != null) {
          body['latitude'] = _lastFix!.latitude;
          body['longitude'] = _lastFix!.longitude;
          body['accuracyMeters'] = _lastFix!.accuracyMeters;
          final loc = jsonMap(today['location']);
          resolvedAddress = await Geocoding.reverseGeocode(
            _lastFix!.latitude,
            _lastFix!.longitude,
            fallbackAddress: loc['address'] as String?,
            fallbackLocationName: loc['name'] as String?,
          );
          body['address'] = resolvedAddress;
        }
      }

      // Check if user is outside company area
      final loc = jsonMap(today['location']);
      bool isOutsideCompany = false;
      if (_lastFix != null && loc['latitude'] != null && loc['longitude'] != null) {
        final dist = _haversineMeters(
          _lastFix!.latitude,
          _lastFix!.longitude,
          (loc['latitude'] as num).toDouble(),
          (loc['longitude'] as num).toDouble(),
        );
        final radius = (loc['radiusMeters'] as num?)?.toDouble() ?? 100.0;
        isOutsideCompany = dist > radius;
      }

      // 2. Selfie verification: ONLY when inside company area!
      _CapturedSelfie? selfie;
      if (needSelfie && !isOutsideCompany) {
        setState(() => _phase = _Phase.selfie);
        final locName = loc['name'] as String?;
        selfie = await _takeSelfie(
          isCheckIn,
          locName,
          locationAddress: resolvedAddress ?? loc['address'] as String?,
          stepTitle: stepTitle,
        );
        if (selfie == null) {
          setState(() => _phase = _Phase.idle);
          return;
        }
        body['selfieFileId'] = selfie.fileId;
        if (isCheckIn) {
          _checkInPhotoBytes = selfie.bytes;
        } else {
          _checkOutPhotoBytes = selfie.bytes;
        }
      }

      if (exceptionReason != null) body['exceptionReason'] = exceptionReason;
      if (remote) body['remote'] = true;
      if (!mounted) return;
      setState(() => _phase = _Phase.sending);
      final r = jsonMap(await context.api.post('/attendance/$action', body: body, idempotencyKey: _attemptKey));
      _attemptKey = null;
      if (!mounted) return;
      final rec = jsonMap(r['record']);
      final punch = jsonMap(rec[isCheckIn ? 'checkIn' : 'checkOut']);
      final punchTime = punch['at'] != null ? Fmt.time(punch['at']) : 'now';
      final fileId = punch['selfieFileId'] as String? ?? selfie?.fileId;
      final finalAddress = punch['address'] as String? ?? resolvedAddress;
      if (finalAddress != null) {
        if (isCheckIn) {
          _checkInAddress = finalAddress;
        } else {
          _checkOutAddress = finalAddress;
        }
      }

      final successMsg = isCheckIn
          ? 'Check-in recorded at $punchTime.'
          : 'Check-out recorded at $punchTime.';

      NToast.of(context).show(r['exception'] == true
          ? 'Recorded at $punchTime. Your exception was sent for approval.'
          : successMsg);
      setState(() => _phase = _Phase.idle);
      _view.currentState?.reload();
      widget.onChanged?.call();

      await _showPunchSuccessModal(
        context,
        isCheckIn: isCheckIn,
        punchTime: punchTime,
        punch: punch,
        selfieBytes: selfie?.bytes,
        selfieFileId: fileId,
        address: finalAddress,
        shift: jsonMap(today['shift']),
        location: loc,
        isException: r['exception'] == true,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isNetwork && !bridge.online) {
        PunchQueue.add(action, _attemptKey!, body);
        _attemptKey = null;
        setState(() {
          _phase = _Phase.idle;
          _queued = PunchQueue.read().length;
        });
        NToast.of(context).show("You're offline. Your punch will sync when you reconnect.");
        return;
      }
      setState(() {
        _phase = _Phase.idle;
        _problem = e;
      });
      if (e.code == 'ALREADY_CHECKED_IN' || e.code == 'ALREADY_CHECKED_OUT') {
        _attemptKey = null;
        _view.currentState?.reload();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _phase = _Phase.idle);
      showError(context, e);
    }
  }

  double _haversineMeters(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * (math.pi / 180.0);
    final dLon = (lon2 - lon1) * (math.pi / 180.0);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * (math.pi / 180.0)) *
            math.cos(lat2 * (math.pi / 180.0)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  Future<void> _refreshCurrentLocation(Json today) async {
    if (_refreshingLocation) return;
    setState(() {
      _refreshingLocation = true;
      _liveLocationError = null;
    });

    try {
      GeoReading? fix;
      try {
        fix = await bridge.currentPosition();
      } on GeoException catch (g) {
        final msg = switch (g.failure) {
          GeoFailure.denied => 'Location access was denied. Please allow location permissions in your browser.',
          GeoFailure.timeout => 'Location request timed out. Please try again.',
          _ => 'GPS location is unavailable on this device.',
        };
        _liveLocationError = msg;
      } catch (e) {
        _liveLocationError = 'Could not get location: $e';
      }

      if (AppConfig.demo && fix == null) {
        fix = const GeoReading(latitude: 23.0225, longitude: 72.5714, accuracyMeters: 12);
      }

      if (fix != null) {
        _lastFix = fix;
        _lastStatus = 'granted';
        final loc = jsonMap(today['location']);
        double? dist;
        bool? inside;
        if (loc['latitude'] != null && loc['longitude'] != null) {
          dist = _haversineMeters(
            fix.latitude,
            fix.longitude,
            (loc['latitude'] as num).toDouble(),
            (loc['longitude'] as num).toDouble(),
          );
          final radius = (loc['radiusMeters'] as num?)?.toDouble() ?? 100.0;
          inside = dist <= radius;
        }

        final resolved = await Geocoding.reverseGeocode(
          fix.latitude,
          fix.longitude,
          fallbackAddress: loc['address'] as String?,
          fallbackLocationName: loc['name'] as String?,
        );

        if (!mounted) return;
        setState(() {
          _liveDistanceMeters = dist;
          _isInsideGeofence = inside;
          _liveAddress = resolved;
          _refreshingLocation = false;
        });

        final locName = loc['name'] as String? ?? 'Office';
        if (dist != null && inside != null) {
          if (inside) {
            NToast.of(context).show('Location refreshed: Inside $locName area (${dist.round()}m away)');
          } else {
            final radius = (loc['radiusMeters'] as num?)?.toDouble() ?? 100.0;
            NToast.of(context).show('Location refreshed: ${dist.round()}m from $locName (limit ${radius.round()}m)');
          }
        } else {
          NToast.of(context).show('Location refreshed: $resolved');
        }
      } else {
        if (!mounted) return;
        setState(() => _refreshingLocation = false);
        if (_liveLocationError != null) {
          NToast.of(context).show(_liveLocationError!);
        }
      }
    } catch (e) {
      if (!mounted) return;
      final msg = 'Failed to fetch location: $e';
      setState(() {
        _liveLocationError = msg;
        _refreshingLocation = false;
      });
      NToast.of(context).show(msg);
    }
  }

  Future<void> _openSetOfficeLocation(Json loc, Json today) async {
    final updated = await showSetOfficeLocationSheet(
      context,
      location: loc,
      onLocationUpdated: () {
        _view.currentState?.reload();
      },
    );
    if (updated != null && mounted) {
      _view.currentState?.reload();
      _refreshCurrentLocation(today);
    }
  }

  Future<void> _requestException(Json today) async {
    final r = await showNConfirm(
      context,
      title: 'Request an exception',
      message: "Your location couldn't be verified. Explain what happened; your manager reviews it. The time recorded is the server's time now.",
      confirmLabel: 'Send for approval',
      reasonLabel: 'What happened?',
    );
    if (!r.confirmed || r.reason == null || r.reason!.length < 5) return;
    await _punch(today, exceptionReason: r.reason);
  }

  Widget _problemPanel(NTokens t, Json today) {
    final e = _problem!;
    final m = e.meta;
    final details = <String>[
      if (m['accuracyMeters'] != null) 'Accuracy: ±${(m['accuracyMeters'] as num).round()} m (limit ${m['requiredAccuracy']} m)',
      if (m['distanceMeters'] != null) 'Distance: ${(m['distanceMeters'] as num).round()} m from ${m['locationName'] ?? 'your location'} (allowed ${m['radiusMeters']} m)',
      if (m['retriesLeft'] != null && (m['retriesLeft'] as num) > 0) '${m['retriesLeft']} more ${(m['retriesLeft'] as num) == 1 ? 'try' : 'tries'} before you can request an exception',
    ];
    final exceptionAvailable = m['exceptionAvailable'] == true;
    final allowRemote = jsonMap(today['requirements'])['allowRemote'] == true && e.code == 'OUTSIDE_GEOFENCE';
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: NBanner(
        tone: NBannerTone.warning,
        title: switch (e.code) {
          'GPS_ACCURACY_TOO_LOW' => 'Location not precise enough',
          'OUTSIDE_GEOFENCE' => 'Outside your work location',
          'LOCATION_REQUIRED' => 'Location needed',
          'SELFIE_REQUIRED' => 'Photo needed',
          _ => 'Not recorded',
        },
        message: [e.message, ...details].join('\n'),
        action: Wrap(direction: Axis.vertical, spacing: 6, children: [
          NButton(
            label: 'Refresh location',
            icon: Icons.my_location_rounded,
            compact: true,
            variant: NButtonVariant.secondary,
            busy: _refreshingLocation,
            onPressed: () => _refreshCurrentLocation(today),
          ),
          if (e.code != 'NO_EMPLOYEE' && e.code != 'EMPLOYEE_INACTIVE') NButton(label: 'Try again', compact: true, variant: NButtonVariant.secondary, onPressed: () => _punch(today)),
          if (allowRemote) NButton(label: 'Record as remote', compact: true, variant: NButtonVariant.secondary, onPressed: () => _punch(today, remote: true)),
          if (exceptionAvailable) NButton(label: 'Request exception', compact: true, onPressed: () => _requestException(today)),
        ]),
      ),
    );
  }

  String? _getOrResolveAddress(
    double? lat,
    double? lng,
    String? locName,
    String? locAddress,
    String? existingAddress,
  ) {
    if (existingAddress != null && existingAddress.isNotEmpty) return existingAddress;
    if (lat == null || lng == null) return locAddress ?? locName;
    final key = '${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';
    if (_resolvedAddresses.containsKey(key)) return _resolvedAddresses[key];

    // Background reverse geocode lookup
    Geocoding.reverseGeocode(
      lat,
      lng,
      fallbackAddress: locAddress,
      fallbackLocationName: locName,
    ).then((resolved) {
      if (mounted && resolved.isNotEmpty && _resolvedAddresses[key] != resolved) {
        setState(() {
          _resolvedAddresses[key] = resolved;
        });
      }
    });
    return locAddress ?? locName ?? '${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}';
  }

  void _openPhotoLightbox(
    BuildContext context, {
    required String title,
    required String? time,
    required String? address,
    required double? lat,
    required double? lng,
    Uint8List? photoBytes,
    String? fileId,
  }) {
    final t = NTokens.of(context);
    showNSheet<void>(
      context,
      title: title,
      subtitle: time != null ? 'Recorded at $time' : null,
      builder: (ctx) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              decoration: BoxDecoration(
                color: t.pillTrack,
                borderRadius: BorderRadius.circular(t.radiusPanel),
                border: Border.all(color: t.cardBorder),
              ),
              clipBehavior: Clip.antiAlias,
              child: photoBytes != null
                  ? Image.memory(photoBytes, height: 280, fit: BoxFit.cover)
                  : (fileId != null
                      ? AuthedImage(fileId: fileId, height: 280, fit: BoxFit.cover)
                      : Container(
                          height: 180,
                          color: t.pillTrack,
                          child: Center(
                            child: Icon(Icons.face_rounded, size: 60, color: t.muted),
                          ),
                        )),
            ),
            const SizedBox(height: 14),
            if (address != null && address.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: t.card,
                  borderRadius: BorderRadius.circular(t.radiusCard),
                  border: Border.all(color: t.cardBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.location_on_rounded, size: 16, color: t.accent),
                        const SizedBox(width: 6),
                        Text(
                          'Punch Location Address',
                          style: t.text.caption(weight: FontWeight.w700).copyWith(color: t.ink),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(address, style: t.text.body(weight: FontWeight.w600).copyWith(color: t.ink)),
                    if (lat != null && lng != null) ...[
                      const SizedBox(height: 8),
                      InkWell(
                        onTap: () => bridge.openUrl('https://www.google.com/maps?q=$lat,$lng'),
                        child: Text(
                          'Open in Google Maps (${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)})',
                          style: t.text.caption(weight: FontWeight.w600).copyWith(
                                color: t.accent,
                                decoration: TextDecoration.underline,
                              ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPunchDetailTile({
    required NTokens t,
    required String title,
    required String? time,
    required double? lat,
    required double? lng,
    required String? address,
    required Uint8List? photoBytes,
    required String? photoFileId,
    required bool isComplete,
    required bool isMobile,
  }) {
    final hasPhoto = photoBytes != null || photoFileId != null;

    return Container(
      constraints: BoxConstraints(minWidth: isMobile ? double.infinity : 210),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(t.radiusTile),
        border: Border.all(color: t.divider),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Face Attendance Photo Thumbnail (Clickable to enlarge)
          GestureDetector(
            onTap: hasPhoto
                ? () => _openPhotoLightbox(
                      context,
                      title: '$title Face Verification',
                      time: time,
                      address: address,
                      lat: lat,
                      lng: lng,
                      photoBytes: photoBytes,
                      fileId: photoFileId,
                    )
                : null,
            child: Stack(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: t.pillTrack,
                    borderRadius: BorderRadius.circular(t.radiusTile),
                    border: Border.all(
                      color: hasPhoto ? t.accent.withValues(alpha: 0.5) : t.divider,
                      width: 1.5,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: photoBytes != null
                      ? Image.memory(photoBytes, fit: BoxFit.cover)
                      : (photoFileId != null
                          ? AuthedImage(fileId: photoFileId, height: 52, width: 52, fit: BoxFit.cover)
                          : Center(
                              child: Icon(
                                isComplete ? Icons.face_rounded : Icons.camera_alt_outlined,
                                size: 22,
                                color: isComplete ? t.accent : t.muted,
                              ),
                            )),
                ),
                if (hasPhoto)
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: t.green,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                      child: const Icon(Icons.check, size: 8, color: Colors.white),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),

          // Time and Location Details
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: t.text.caption(weight: FontWeight.w500).copyWith(color: t.muted, fontSize: 11),
                ),
                const SizedBox(height: 1),
                Row(
                  children: [
                    Text(
                      time ?? '—',
                      style: t.text.caption(weight: FontWeight.w700).copyWith(
                            color: time != null ? t.ink : t.muted,
                            fontSize: 13,
                          ),
                    ),
                    if (hasPhoto) ...[
                      const SizedBox(width: 6),
                      InkWell(
                        onTap: () => _openPhotoLightbox(
                          context,
                          title: '$title Face Verification',
                          time: time,
                          address: address,
                          lat: lat,
                          lng: lng,
                          photoBytes: photoBytes,
                          fileId: photoFileId,
                        ),
                        child: Text(
                          'View Photo',
                          style: t.text.caption(weight: FontWeight.w600).copyWith(
                                color: t.accent,
                                fontSize: 10,
                                decoration: TextDecoration.underline,
                              ),
                        ),
                      ),
                    ],
                  ],
                ),
                if (address != null && address.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 1.5),
                        child: Icon(Icons.location_on_rounded, size: 12, color: t.accent),
                      ),
                      const SizedBox(width: 3),
                      Expanded(
                        child: Text(
                          address,
                          style: t.text.caption().copyWith(fontSize: 10, color: t.ink),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
                if (lat != null && lng != null) ...[
                  const SizedBox(height: 2),
                  InkWell(
                    onTap: () => bridge.openUrl('https://www.google.com/maps?q=$lat,$lng'),
                    child: Text(
                      'View on Map',
                      style: t.text.caption(weight: FontWeight.w600).copyWith(
                            color: t.accent,
                            fontSize: 10,
                            decoration: TextDecoration.underline,
                          ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showPunchSuccessModal(
    BuildContext context, {
    required bool isCheckIn,
    required String punchTime,
    required Map<String, dynamic> punch,
    required Uint8List? selfieBytes,
    required String? selfieFileId,
    required String? address,
    required Map<String, dynamic> shift,
    required Map<String, dynamic> location,
    required bool isException,
  }) async {
    final t = NTokens.of(context);
    final isMobile = NBreakpoint.of(context).isMobile;
    final lat = (punch['latitude'] as num?)?.toDouble() ?? _lastFix?.latitude;
    final lng = (punch['longitude'] as num?)?.toDouble() ?? _lastFix?.longitude;
    final accuracy = (punch['accuracyMeters'] as num?)?.round() ?? _lastFix?.accuracyMeters.round();
    final dist = (punch['distanceMeters'] as num?)?.round();
    final shiftName = shift['name'] as String? ?? 'Standard Shift';
    final shiftHours = shift['startTime'] != null && shift['endTime'] != null
        ? '${shift['startTime']} – ${shift['endTime']}'
        : '10:00 AM – 7:00 PM';

    await showNSheet<void>(
      context,
      title: isCheckIn ? 'Check-In Confirmed' : 'Check-Out Confirmed',
      subtitle: isException
          ? 'Recorded at $punchTime. Sent for exception approval.'
          : 'Successfully recorded at $punchTime',
      builder: (ctx) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Status Hero Banner
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: (isCheckIn ? t.accent : t.green).withValues(alpha: t.isDark ? 0.22 : 0.14),
                borderRadius: BorderRadius.circular(t.radiusCard),
                border: Border.all(
                  color: (isCheckIn ? t.accent : t.green).withValues(alpha: 0.4),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: isCheckIn ? t.accent : t.green,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.check_rounded, color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isCheckIn ? 'Checked In Successfully' : 'Checked Out Successfully',
                          style: t.text.title(size: 15).copyWith(
                                color: isCheckIn ? t.accent : t.green,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          'Recorded at $punchTime · Server clock verified',
                          style: t.text.caption(color: t.muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Captured Face Attendance Photo
            if (selfieBytes != null || selfieFileId != null) ...[
              Container(
                decoration: BoxDecoration(
                  color: t.pillTrack,
                  borderRadius: BorderRadius.circular(t.radiusPanel),
                  border: Border.all(color: t.cardBorder),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  alignment: Alignment.bottomCenter,
                  children: [
                    if (selfieBytes != null)
                      Image.memory(
                        selfieBytes,
                        height: isMobile ? 200 : 240,
                        width: double.infinity,
                        fit: BoxFit.cover,
                      )
                    else if (selfieFileId != null)
                      AuthedImage(
                        fileId: selfieFileId,
                        height: isMobile ? 200 : 240,
                        width: double.infinity,
                        fit: BoxFit.cover,
                      ),
                    Positioned(
                      top: 10,
                      left: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(NTokens.radiusPill),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.face_rounded, size: 14, color: Colors.white),
                            SizedBox(width: 5),
                            Text(
                              'Face Verified',
                              style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.8),
                              Colors.transparent,
                            ],
                          ),
                        ),
                        child: Text(
                          'Captured Attendance Photo · $punchTime',
                          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w500),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
            ],

            // Location & Address Card
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: t.card,
                borderRadius: BorderRadius.circular(t.radiusCard),
                border: Border.all(color: t.cardBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Icons.location_on_rounded, size: 18, color: t.accent),
                      const SizedBox(width: 6),
                      Text(
                        'Location & Address',
                        style: t.text.caption(weight: FontWeight.w700).copyWith(color: t.ink),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    address ?? (location['address'] as String?) ?? (location['name'] as String?) ?? 'Work Office Location',
                    style: t.text.body(weight: FontWeight.w600).copyWith(color: t.ink, height: 1.35),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (dist != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: t.pillTrack,
                            borderRadius: BorderRadius.circular(NTokens.radiusPill),
                          ),
                          child: Text(
                            dist == 0 ? 'Inside Office Area' : '$dist m from office',
                            style: t.text.caption(color: t.muted).copyWith(fontSize: 11),
                          ),
                        ),
                      if (accuracy != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: t.pillTrack,
                            borderRadius: BorderRadius.circular(NTokens.radiusPill),
                          ),
                          child: Text(
                            'Accuracy: ±$accuracy m',
                            style: t.text.caption(color: t.muted).copyWith(fontSize: 11),
                          ),
                        ),
                      if (lat != null && lng != null)
                        InkWell(
                          onTap: () => bridge.openUrl('https://www.google.com/maps?q=$lat,$lng'),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.map_rounded, size: 14, color: t.accent),
                                const SizedBox(width: 4),
                                Text(
                                  'Open in Google Maps',
                                  style: t.text.caption(weight: FontWeight.w700).copyWith(
                                        color: t.accent,
                                        fontSize: 11,
                                        decoration: TextDecoration.underline,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Shift Details Card
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: t.pillTrack.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(t.radiusCard),
              ),
              child: Row(
                children: [
                  Icon(Icons.schedule_rounded, size: 16, color: t.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$shiftName ($shiftHours)',
                      style: t.text.caption().copyWith(color: t.ink),
                    ),
                  ),
                  Text(
                    isCheckIn ? 'Active Session' : 'Shift Recorded',
                    style: t.text.caption(weight: FontWeight.w600).copyWith(
                          color: isCheckIn ? t.accent : t.green,
                        ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),

            // Close / Done button
            NButton(
              label: 'Done',
              icon: Icons.check_circle_outline_rounded,
              variant: NButtonVariant.accent,
              onPressed: () => Navigator.of(ctx).pop(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShiftSchedule(NTokens t, String state, Map<String, dynamic> rec, Json today, double dayCount, bool isMobile) {
    final checkIn = jsonMap(rec['checkIn']);
    final checkOut = jsonMap(rec['checkOut']);
    final inTime = checkIn['at'] as String?;
    final outTime = checkOut['at'] as String?;
    final inLat = checkIn['latitude'];
    final inLng = checkIn['longitude'];
    final outLat = checkOut['latitude'];
    final outLng = checkOut['longitude'];
    final workedMins = (rec['workedMinutes'] as num? ?? 0).toInt();
    final breakMins = (rec['breakMinutes'] as num? ?? 0).toInt();
    final sessionsList = (rec['sessions'] as List<dynamic>?)?.map((s) => jsonMap(s)).toList() ?? [];

    final loc = jsonMap(today['location']);
    final locName = loc['name'] as String?;
    final locAddress = loc['address'] as String?;

    final inAddress = _getOrResolveAddress(
      inLat != null ? (inLat as num).toDouble() : null,
      inLng != null ? (inLng as num).toDouble() : null,
      locName,
      locAddress,
      checkIn['address'] as String? ?? _checkInAddress,
    );

    final outAddress = _getOrResolveAddress(
      outLat != null ? (outLat as num).toDouble() : null,
      outLng != null ? (outLng as num).toDouble() : null,
      locName,
      locAddress,
      checkOut['address'] as String? ?? _checkOutAddress,
    );

    final inPhotoFileId = checkIn['selfieFileId'] as String?;
    final outPhotoFileId = checkOut['selfieFileId'] as String?;

    final hasCheckedIn = inTime != null;
    final hasCheckedOut = outTime != null;
    final isCheckedIn = state == 'checked_in';

    final badgeLabel = isCheckedIn
        ? 'Active Session'
        : (hasCheckedOut
            ? (dayCount >= 1.0 ? '1.0 Full Day' : (dayCount >= 0.5 ? '0.5 Half Day' : 'Paused / On Break'))
            : (hasCheckedIn ? 'Checked In' : 'Not Started'));
    final badgeColor = isCheckedIn
        ? t.accent
        : (hasCheckedOut
            ? (dayCount >= 1.0 ? t.green : t.amber)
            : t.muted);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(t.radiusCard),
        border: Border.all(color: t.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.schedule_rounded, size: 16, color: t.accent),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'Shift Schedule',
                      style: t.text.caption(weight: FontWeight.w700).copyWith(color: t.ink),
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: t.isDark ? 0.22 : 0.16),
                  borderRadius: BorderRadius.circular(NTokens.radiusPill),
                ),
                child: Text(
                  badgeLabel,
                  style: t.text.caption(weight: FontWeight.w700).copyWith(color: badgeColor),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Morning Shift: 10:00 AM - 1:00 PM
          _buildShiftTimelineItem(
            t: t,
            icon: Icons.wb_sunny_outlined,
            title: 'Morning Shift',
            timing: '10:00 AM – 1:00 PM',
            duration: '3 hrs',
            status: hasCheckedIn ? (hasCheckedOut ? 'Recorded' : 'Active') : 'Upcoming',
            color: t.amber,
            isCurrent: hasCheckedIn && !hasCheckedOut,
          ),
          const SizedBox(height: 6),

          // Lunch Break: 1:00 PM - 2:00 PM
          _buildShiftTimelineItem(
            t: t,
            icon: Icons.restaurant_rounded,
            title: 'Lunch Break',
            timing: '1:00 PM – 2:00 PM',
            duration: breakMins > 0 ? '${Fmt.minutes(breakMins)} taken' : '1 hr auto-break',
            status: breakMins > 0 ? '${Fmt.minutes(breakMins)} Break' : (hasCheckedOut ? 'Deducted' : '1 hr'),
            color: t.muted,
            isCurrent: false,
            isBreak: true,
          ),
          const SizedBox(height: 6),

          // Afternoon Shift: 2:00 PM - 7:00 PM
          _buildShiftTimelineItem(
            t: t,
            icon: Icons.wb_twilight_rounded,
            title: 'Afternoon Shift',
            timing: '2:00 PM – 7:00 PM',
            duration: '5 hrs',
            status: hasCheckedOut ? 'Recorded' : (hasCheckedIn ? 'In Progress' : 'Upcoming'),
            color: t.accent,
            isCurrent: hasCheckedIn && !hasCheckedOut,
          ),

          // Multiple Sessions breakdown if employee punched in/out multiple times
          if (sessionsList.length > 1) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: t.pillTrack,
                borderRadius: BorderRadius.circular(t.radiusTile),
                border: Border.all(color: t.divider),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Today\'s Sessions (${sessionsList.length})', style: t.text.caption(weight: FontWeight.w700).copyWith(color: t.ink)),
                      if (breakMins > 0)
                        Text('Break: ${Fmt.minutes(breakMins)}', style: t.text.caption(weight: FontWeight.w600).copyWith(color: t.amber)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  for (var i = 0; i < sessionsList.length; i++) ...[
                    Builder(builder: (context) {
                      final s = sessionsList[i];
                      final sIn = jsonMap(s['checkIn'])['at'] as String?;
                      final sOut = jsonMap(s['checkOut'])['at'] as String?;
                      final sDur = (s['durationMinutes'] as num? ?? 0).toInt();
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Session ${i + 1}: ${sIn != null ? Fmt.time(sIn) : "—"} – ${sOut != null ? Fmt.time(sOut) : "(Active)"}',
                              style: t.text.caption().copyWith(color: sOut == null ? t.accent : t.ink, fontSize: 11),
                            ),
                            Text(
                              sOut != null ? Fmt.minutes(sDur) : 'In Progress',
                              style: t.text.caption(weight: FontWeight.w600).copyWith(color: sOut == null ? t.accent : t.muted, fontSize: 11),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ],
              ),
            ),
          ],

          if (hasCheckedIn || hasCheckedOut) ...[
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              children: [
                _buildPunchDetailTile(
                  t: t,
                  title: 'First Check In',
                  time: hasCheckedIn ? Fmt.time(inTime) : null,
                  lat: inLat != null ? (inLat as num).toDouble() : null,
                  lng: inLng != null ? (inLng as num).toDouble() : null,
                  address: inAddress,
                  photoBytes: _checkInPhotoBytes,
                  photoFileId: inPhotoFileId,
                  isComplete: hasCheckedIn,
                  isMobile: isMobile,
                ),
                _buildPunchDetailTile(
                  t: t,
                  title: 'Latest Check Out',
                  time: hasCheckedOut ? Fmt.time(outTime) : (hasCheckedIn ? 'In Progress' : null),
                  lat: outLat != null ? (outLat as num).toDouble() : null,
                  lng: outLng != null ? (outLng as num).toDouble() : null,
                  address: outAddress,
                  photoBytes: _checkOutPhotoBytes,
                  photoFileId: outPhotoFileId,
                  isComplete: hasCheckedOut,
                  isMobile: isMobile,
                ),
                if (workedMins > 0)
                  Container(
                    constraints: BoxConstraints(minWidth: isMobile ? double.infinity : 130),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: t.card,
                      borderRadius: BorderRadius.circular(t.radiusTile),
                      border: Border.all(color: t.divider),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Total Worked', style: t.text.caption(weight: FontWeight.w500).copyWith(color: t.muted, fontSize: 11)),
                        const SizedBox(height: 2),
                        Text(
                          Fmt.minutes(workedMins),
                          style: t.text.caption(weight: FontWeight.w700).copyWith(color: t.accent, fontSize: 13),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          breakMins > 0 ? '${Fmt.minutes(breakMins)} break deducted' : 'Net productive time',
                          style: t.text.caption().copyWith(fontSize: 10, color: t.muted),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildShiftTimelineItem({
    required NTokens t,
    required IconData icon,
    required String title,
    required String timing,
    required String duration,
    required String status,
    required Color color,
    required bool isCurrent,
    bool isBreak = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: isBreak ? t.pillTrack.withValues(alpha: 0.6) : (isCurrent ? color.withValues(alpha: 0.08) : t.pillTrack),
        borderRadius: BorderRadius.circular(t.radiusTile),
        border: Border.all(
          color: isCurrent ? color.withValues(alpha: 0.5) : t.divider,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(title, style: t.text.caption(weight: FontWeight.w700).copyWith(color: t.ink)),
                    Text('($duration)', style: t.text.caption().copyWith(fontSize: 10, color: t.muted)),
                  ],
                ),
                const SizedBox(height: 1),
                Text(timing, style: t.text.caption().copyWith(fontSize: 11, color: t.muted)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: (status == 'Active' || status == 'In Progress' ? t.accent : (status == 'Done' || status == 'Completed' ? t.green : t.card))
                  .withValues(alpha: t.isDark ? 0.22 : 0.16),
              borderRadius: BorderRadius.circular(NTokens.radiusPill),
            ),
            child: Text(
              status,
              style: t.text.caption(weight: FontWeight.w600).copyWith(
                    fontSize: 10,
                    color: status == 'Active' || status == 'In Progress'
                        ? t.accent
                        : (status == 'Done' || status == 'Completed' ? t.green : t.muted),
                  ),
            ),
          ),
        ],
      ),
    );
  }

  static Json? _loadCached() {
    try {
      final raw = bridge.readLocal('shrm_attendance_today_cache');
      if (raw != null && raw.isNotEmpty) {
        return (jsonDecode(raw) as Map).cast<String, dynamic>();
      }
    } catch (_) {}
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final isMobile = NBreakpoint.of(context).isMobile;

    return NGlassCard(
      blur: false,
      child: AsyncView<Json>(
        key: _view,
        initialData: _loadCached(),
        load: () async {
          final res = jsonMap(await context.api.get('/attendance/today'));
          try {
            bridge.writeLocal('shrm_attendance_today_cache', jsonEncode(res));
          } catch (_) {}
          return res;
        },
        compact: true,
        builder: (context, today, reload) {
          final state = '${today['state']}';
          final rec = jsonMap(today['record']);
          final shift = jsonMap(today['shift']);
          final loc = jsonMap(today['location']);
          final busy = _phase != _Phase.idle;

          final isCheckedIn = state == 'checked_in';
          final isCheckedOut = state == 'checked_out';

          final dayCount = (today['attendanceDayCount'] as num?)?.toDouble() ??
              (rec['dayCount'] as num?)?.toDouble() ??
              (isCheckedOut ? (rec['status'] == 'half_day' ? 0.5 : 1.0) : (isCheckedIn ? 0.5 : 0.0));

          final hasStarted = rec['checkIn'] != null;

          final label = switch (_phase) {
            _Phase.locating => 'Getting your location…',
            _Phase.selfie => 'Waiting for photo…',
            _Phase.sending => 'Recording punch…',
            _Phase.idle => switch (state) {
                'not_checked_in' => 'Check in',
                'checked_in' => 'Check out',
                _ => 'Check in (Resume Work)',
              },
          };

          final buttonIcon = switch (state) {
            'not_checked_in' => Icons.login_rounded,
            'checked_in' => Icons.logout_rounded,
            _ => Icons.login_rounded,
          };

          final isCheckInAction = state != 'checked_in';

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              NCardTitle(
                'Today\'s Attendance',
                subtitle: '${Fmt.date(today['workDate'])}${shift.isNotEmpty ? ' · ${shift['name']} (${shift['startTime']}–${shift['endTime']})' : ' · Shift: 10:00 AM – 7:00 PM'}',
                trailing: StatusChip(
                  isCheckedOut
                      ? (dayCount >= 1.0 ? 'present' : (dayCount >= 0.5 ? 'half_day' : 'pending'))
                      : (isCheckedIn ? 'present' : 'pending'),
                  label: isCheckedIn
                      ? 'Checked In · Active'
                      : (hasStarted
                          ? (dayCount >= 1.0 ? '1.0 Full Day' : (dayCount >= 0.5 ? '0.5 Half Day' : 'Paused / On Break'))
                          : 'Not Checked In'),
                ),
              ),
              if (today['holiday'] != null)
                NBanner(message: 'Today is a holiday: ${jsonMap(today['holiday'])['name']}.', tone: NBannerTone.info),
              if (today['onLeave'] != null)
                const NBanner(message: 'You\'re on approved leave today.', tone: NBannerTone.info),
              if (_queued > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: NBanner(message: '$_queued punch waiting to sync from this device.', tone: NBannerTone.warning),
                ),

              // Shift Schedule & Punch Details
              _buildShiftSchedule(t, state, rec, today, dayCount, isMobile),

              // Work location & Real-time GPS verification panel with Refresh Location button
              if (!widget.compact) ...[
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: t.pillTrack.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(t.radiusCard),
                    border: Border.all(color: t.cardBorder),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.business_rounded, size: 16, color: t.accent),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  'Work Location',
                                  style: t.text.caption(weight: FontWeight.w700).copyWith(color: t.ink),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          Wrap(
                            spacing: 4,
                            runSpacing: 2,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              InkWell(
                                onTap: () => setState(() => _showGeofenceMap = !_showGeofenceMap),
                                borderRadius: BorderRadius.circular(NTokens.radiusPill),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(_showGeofenceMap ? Icons.map_rounded : Icons.radar_rounded, size: 14, color: t.accent),
                                      const SizedBox(width: 4),
                                      Text(
                                        _showGeofenceMap ? 'Hide Map' : 'View Map',
                                        style: t.text.caption(weight: FontWeight.w700).copyWith(
                                              color: t.accent,
                                              fontSize: 11,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              InkWell(
                                onTap: _refreshingLocation ? null : () => _refreshCurrentLocation(today),
                                borderRadius: BorderRadius.circular(NTokens.radiusPill),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (_refreshingLocation)
                                        SizedBox(
                                          width: 12,
                                          height: 12,
                                          child: CircularProgressIndicator(strokeWidth: 2, color: t.accent),
                                        )
                                      else
                                        Icon(Icons.refresh_rounded, size: 14, color: t.accent),
                                      const SizedBox(width: 4),
                                      Text(
                                        _refreshingLocation ? 'Refreshing...' : 'Refresh GPS',
                                        style: t.text.caption(weight: FontWeight.w700).copyWith(
                                              color: t.accent,
                                              fontSize: 11,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              InkWell(
                                onTap: () => _openSetOfficeLocation(loc, today),
                                borderRadius: BorderRadius.circular(NTokens.radiusPill),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.edit_location_alt_outlined, size: 14, color: t.accent),
                                      const SizedBox(width: 4),
                                      Text(
                                        'Set Office',
                                        style: t.text.caption(weight: FontWeight.w700).copyWith(
                                              color: t.accent,
                                              fontSize: 11,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              InkWell(
                                onTap: () => showPermissionsSetupDialog(
                                  context,
                                  onPermissionsChanged: () => _refreshCurrentLocation(today),
                                ),
                                borderRadius: BorderRadius.circular(NTokens.radiusPill),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.verified_user_outlined, size: 14, color: t.accent),
                                      const SizedBox(width: 4),
                                      Text(
                                        'Permissions',
                                        style: t.text.caption(weight: FontWeight.w700).copyWith(
                                              color: t.accent,
                                              fontSize: 11,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        loc.isEmpty
                            ? 'Main Office'
                            : (loc['address'] != null && (loc['address'] as String).isNotEmpty
                                ? '${loc['name']} · ${loc['address']} (allowed radius ${loc['radiusMeters'] ?? 100} m)'
                                : '${loc['name']} (allowed radius ${loc['radiusMeters'] ?? 100} m)'),
                        style: t.text.caption(color: t.muted),
                      ),
                      if (_lastFix != null || _liveAddress != null) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: (_isInsideGeofence == true ? t.green : t.amber).withValues(alpha: t.isDark ? 0.20 : 0.12),
                            borderRadius: BorderRadius.circular(t.radiusTile),
                            border: Border.all(
                              color: (_isInsideGeofence == true ? t.green : t.amber).withValues(alpha: 0.4),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    _isInsideGeofence == true ? Icons.check_circle_rounded : Icons.info_outline_rounded,
                                    size: 14,
                                    color: _isInsideGeofence == true ? t.green : t.amber,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      _isInsideGeofence == true
                                          ? 'Inside office area · ${_liveDistanceMeters?.round() ?? 0}m away'
                                          : (_liveDistanceMeters != null
                                              ? 'Outside office area · ${_liveDistanceMeters!.round()}m away (allowed ${loc['radiusMeters'] ?? 100}m)'
                                              : 'Current location detected'),
                                      style: t.text.caption(weight: FontWeight.w700).copyWith(
                                            color: _isInsideGeofence == true ? t.green : t.amber,
                                            fontSize: 11,
                                          ),
                                    ),
                                  ),
                                  if (_lastFix != null)
                                    Text(
                                      '±${_lastFix!.accuracyMeters.round()}m',
                                      style: t.text.caption(color: t.muted).copyWith(fontSize: 10),
                                    ),
                                ],
                              ),
                              if (_liveAddress != null && _liveAddress!.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Icon(Icons.place_outlined, size: 12, color: t.muted),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: Text(
                                        _liveAddress!,
                                        style: t.text.caption().copyWith(fontSize: 10, color: t.ink),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                              if (_lastFix != null) ...[
                                const SizedBox(height: 2),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: InkWell(
                                    onTap: () => bridge.openUrl('https://www.google.com/maps?q=${_lastFix!.latitude},${_lastFix!.longitude}'),
                                    child: Text(
                                      'View current GPS on Map',
                                      style: t.text.caption(weight: FontWeight.w600).copyWith(
                                            color: t.accent,
                                            fontSize: 10,
                                            decoration: TextDecoration.underline,
                                          ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ] else if (_liveLocationError != null) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: t.red.withValues(alpha: t.isDark ? 0.20 : 0.10),
                            borderRadius: BorderRadius.circular(t.radiusTile),
                            border: Border.all(color: t.red.withValues(alpha: 0.4)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.warning_amber_rounded, size: 14, color: t.red),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      _liveLocationError!,
                                      style: t.text.caption(color: t.red).copyWith(fontWeight: FontWeight.w600, fontSize: 10.5),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Align(
                                alignment: Alignment.centerRight,
                                child: InkWell(
                                  onTap: () => showPermissionsSetupDialog(
                                    context,
                                    onPermissionsChanged: () => _refreshCurrentLocation(today),
                                  ),
                                  borderRadius: BorderRadius.circular(NTokens.radiusPill),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: t.accent.withValues(alpha: 0.18),
                                      borderRadius: BorderRadius.circular(NTokens.radiusPill),
                                      border: Border.all(color: t.accent.withValues(alpha: 0.5)),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.security_rounded, size: 12, color: t.accent),
                                        const SizedBox(width: 4),
                                        Text(
                                          'Fix Permissions & GPS Setup',
                                          style: TextStyle(color: t.accent, fontWeight: FontWeight.w700, fontSize: 10),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (_showGeofenceMap) ...[
                        const SizedBox(height: 10),
                        GeofenceRadarMap(
                          officeLat: (loc['latitude'] as num?)?.toDouble() ?? 23.0225,
                          officeLng: (loc['longitude'] as num?)?.toDouble() ?? 72.5714,
                          officeRadiusMeters: (loc['radiusMeters'] as num?)?.toDouble() ?? 100.0,
                          officeName: loc['name'] as String? ?? 'Bulletproof Brands HQ',
                          officeAddress: loc['address'] as String?,
                          userLat: _lastFix?.latitude,
                          userLng: _lastFix?.longitude,
                          accuracyMeters: _lastFix?.accuracyMeters,
                          isInside: _isInsideGeofence,
                          isRefreshing: _refreshingLocation,
                          onRefresh: () => _refreshCurrentLocation(today),
                          onSetOfficeLocation: () => _openSetOfficeLocation(loc, today),
                          onOpenPermissions: () => showPermissionsSetupDialog(
                            context,
                            onPermissionsChanged: () => _refreshCurrentLocation(today),
                          ),
                          height: 230,
                        ),
                      ],
                    ],
                  ),
                ),
              ],

              // Evening Check-Out Reminder
              if (isCheckedIn && DateTime.now().hour >= 18)
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: t.amber.withValues(alpha: t.isDark ? 0.22 : 0.14),
                      borderRadius: BorderRadius.circular(t.radiusCard),
                      border: Border.all(color: t.amber.withValues(alpha: 0.5)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.alarm_on_rounded, size: 20, color: t.amber),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Shift End Reminder',
                                style: t.text.caption(weight: FontWeight.w700).copyWith(color: t.amber, fontSize: 11),
                              ),
                              Text(
                                'Standard shift ends at 7:00 PM. Don\'t forget to Check Out when you leave!',
                                style: t.text.caption().copyWith(fontSize: 10, color: t.ink),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              if (_problem != null) _problemPanel(t, today),
              const SizedBox(height: 12),

              // Primary Punch Action Button (Check In or Check Out)
              NButton(
                label: label,
                icon: buttonIcon,
                variant: isCheckedIn ? NButtonVariant.secondary : NButtonVariant.accent,
                busy: busy,
                onPressed: () => _punch(today),
              ),

              // Day Summary Banner when currently checked out
              if (isCheckedOut && hasStarted) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: (dayCount >= 1.0 ? t.green : t.amber).withValues(alpha: t.isDark ? 0.20 : 0.12),
                    borderRadius: BorderRadius.circular(t.radiusCard),
                    border: Border.all(color: dayCount >= 1.0 ? t.green : t.amber),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.verified_rounded, color: dayCount >= 1.0 ? t.green : t.amber, size: 24),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${dayCount >= 1.0 ? "1.0 Full Day" : (dayCount >= 0.5 ? "0.5 Half Day" : "In Progress")} (${Fmt.minutes(rec['workedMinutes'] ?? 0)} worked)',
                              style: t.text.body(weight: FontWeight.w700).copyWith(color: dayCount >= 1.0 ? t.green : t.amber),
                            ),
                            Text(
                              'Latest check-out at ${rec['checkOut']?['at'] != null ? Fmt.time(rec['checkOut']['at']) : '—'}.${(rec['breakMinutes'] as num? ?? 0) > 0 ? ' Break: ${Fmt.minutes(rec['breakMinutes'])}.' : ''} Tap "Check In (Resume Work)" whenever you return.',
                              style: t.text.caption().copyWith(color: t.muted),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // Footer helper details
              if (!isCheckedOut) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          [
                            if (jsonMap(jsonMap(today['requirements'])[isCheckInAction ? 'checkIn' : 'checkOut'])['requireLocation'] != false) 'GPS Geofenced',
                            if (jsonMap(jsonMap(today['requirements'])[isCheckInAction ? 'checkIn' : 'checkOut'])['requireSelfie'] == true) 'Selfie verified',
                            'Server clock',
                          ].join(' · '),
                          style: t.text.caption(),
                        ),
                      ),
                    ],
                  ),
                ),
                if (isMobile) const SizedBox(height: 14),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _SelfieSheet extends StatefulWidget {
  const _SelfieSheet({
    required this.isCheckIn,
    this.locationName,
    this.locationAddress,
    this.stepTitle,
  });
  final bool isCheckIn;
  final String? locationName;
  final String? locationAddress;
  final String? stepTitle;

  @override
  State<_SelfieSheet> createState() => _SelfieSheetState();
}

class _SelfieSheetState extends State<_SelfieSheet> {
  PickedFile? _picked;
  bool _busy = false;
  bool _refreshingLoc = false;
  late String? _displayLoc = widget.locationAddress ?? widget.locationName;

  @override
  void initState() {
    super.initState();
  }

  Future<void> _refreshLocation() async {
    if (_refreshingLoc) return;
    setState(() => _refreshingLoc = true);
    try {
      final fix = await bridge.currentPosition();
      final addr = await Geocoding.reverseGeocode(
        fix.latitude,
        fix.longitude,
        fallbackAddress: widget.locationAddress,
        fallbackLocationName: widget.locationName,
      );
      if (mounted) {
        setState(() {
          _displayLoc = addr;
          _refreshingLoc = false;
        });
        NToast.of(context).show('Location refreshed: $addr');
      }
    } catch (_) {
      if (mounted) setState(() => _refreshingLoc = false);
    }
  }

  Future<void> _takePhoto() async {
    setState(() => _busy = true);
    try {
      final f = await bridge.pickFile(accept: 'image/*', capture: 'user');
      if (f != null && mounted) {
        setState(() => _picked = f);
      }
    } catch (_) {
      // Ignored
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final actionName = widget.stepTitle ?? (widget.isCheckIn ? 'Check in' : 'Check out');
    final isMobile = NBreakpoint.of(context).isMobile;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Step Info Badge & Location
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: t.accent.withValues(alpha: t.isDark ? 0.22 : 0.16),
                  borderRadius: BorderRadius.circular(NTokens.radiusPill),
                  border: Border.all(color: t.accent.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.camera_alt_rounded, size: 14, color: t.accent),
                    const SizedBox(width: 6),
                    Text(
                      actionName,
                      style: t.text.caption(weight: FontWeight.w700).copyWith(color: t.accent),
                    ),
                  ],
                ),
              ),
              if (_displayLoc != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '📍 $_displayLoc',
                    style: t.text.caption().copyWith(color: t.muted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                InkWell(
                  onTap: _refreshingLoc ? null : _refreshLocation,
                  borderRadius: BorderRadius.circular(NTokens.radiusPill),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: _refreshingLoc
                        ? SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2, color: t.accent),
                          )
                        : Icon(Icons.refresh_rounded, size: 14, color: t.accent),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),

          // Camera Viewfinder & Photo Display
          Container(
            height: isMobile ? 220 : 270,
            decoration: BoxDecoration(
              color: t.pillTrack,
              borderRadius: BorderRadius.circular(t.radiusPanel),
              border: Border.all(
                color: _picked != null ? t.green : t.cardBorder,
                width: _picked != null ? 2.5 : 1,
              ),
              boxShadow: _picked != null
                  ? [
                      BoxShadow(
                        color: t.green.withValues(alpha: 0.2),
                        blurRadius: 16,
                        spreadRadius: 2,
                      ),
                    ]
                  : null,
            ),
            clipBehavior: Clip.antiAlias,
            child: _picked != null
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.memory(_picked!.bytes, fit: BoxFit.cover),
                      Positioned(
                        top: 12,
                        left: 12,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: t.green,
                            borderRadius: BorderRadius.circular(NTokens.radiusPill),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.25),
                                blurRadius: 6,
                              ),
                            ],
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.check_circle_rounded, size: 15, color: Colors.white),
                              SizedBox(width: 5),
                              Text(
                                'Photo Captured',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 74,
                        height: 74,
                        decoration: BoxDecoration(
                          color: t.accent.withValues(alpha: t.isDark ? 0.25 : 0.16),
                          shape: BoxShape.circle,
                          border: Border.all(color: t.accent.withValues(alpha: 0.4), width: 2),
                        ),
                        child: Center(
                          child: _busy
                              ? SizedBox(
                                  width: 32,
                                  height: 32,
                                  child: CircularProgressIndicator(strokeWidth: 2.5, color: t.accent),
                                )
                              : Icon(Icons.camera_alt_rounded, size: 36, color: t.accent),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _busy ? 'Opening camera…' : 'Capture Attendance Selfie',
                        style: t.text.title(size: 16),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Direct front camera photo verification',
                        style: t.text.caption(color: t.muted),
                      ),
                    ],
                  ),
          ),
          const SizedBox(height: 16),

          // Actions: Direct capture when empty, or Side-by-side Retake + TICK BUTTON when photo is clicked
          if (_picked == null) ...[
            NButton(
              label: 'Click / Open Camera',
              icon: Icons.camera_alt_rounded,
              variant: NButtonVariant.accent,
              busy: _busy,
              onPressed: _takePhoto,
            ),
          ] else ...[
            // Side-by-side action bar: Retake on the left, TICK BUTTON (✓ Confirm & Continue) on the right
            Row(
              children: [
                Expanded(
                  flex: 1,
                  child: NButton(
                    label: 'Retake',
                    icon: Icons.refresh_rounded,
                    variant: NButtonVariant.secondary,
                    onPressed: () {
                      setState(() => _picked = null);
                      _takePhoto();
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(NTokens.radiusPill),
                      boxShadow: [
                        BoxShadow(
                          color: t.green.withValues(alpha: 0.35),
                          blurRadius: 12,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: t.green,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: EdgeInsets.symmetric(horizontal: isMobile ? 10 : 16, vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(NTokens.radiusPill),
                        ),
                      ),
                      icon: const Icon(Icons.check_circle_rounded, size: 20, color: Colors.white),
                      label: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          isMobile ? 'Confirm' : 'Confirm & Continue',
                          style: t.text.body(weight: FontWeight.w700, color: Colors.white),
                        ),
                      ),
                      onPressed: () => Navigator.of(context).pop(_picked),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
