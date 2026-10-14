import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:n_ui/n_ui.dart';

import '../../app/config.dart';
import '../../app/services.dart';
import '../../data/api.dart';
import '../../platform/bridge.dart';
import '../../widgets/async_view.dart';
import '../../widgets/format.dart';
import '../../widgets/status.dart';

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

  Future<String?> _takeSelfie(bool checkIn, String? locationName, {String? stepTitle}) async {
    final api = context.api;
    // Directly open device camera without showing intermediate review sheet
    PickedFile? picked;
    try {
      picked = await bridge.pickFile(accept: 'image/*', capture: 'user');
    } catch (_) {
      picked = null;
    }

    // Fallback: If camera was cancelled or native picker was blocked, show sheet to retry
    if (picked == null) {
      if (!mounted) return null;
      final retry = await showNSheet<PickedFile?>(
        context,
        title: stepTitle ?? (checkIn ? 'Check-in photo' : 'Check-out photo'),
        subtitle: 'Camera was closed. Tap below to capture your attendance photo.',
        builder: (ctx) => _SelfieSheet(isCheckIn: checkIn, locationName: locationName, stepTitle: stepTitle),
      );
      if (retry == null || !mounted) return null;
      picked = retry;
    }

    if (!mounted) return null;
    setState(() => _phase = _Phase.sending);
    final rec = await api.upload(picked, purpose: 'selfie');
    return rec['id'] as String?;
  }

  Future<void> _punch(Json today, {String? exceptionReason, bool remote = false}) async {
    final state = '${today['state']}';
    final isCheckIn = state == 'not_checked_in' || state == 'on_break';
    final action = isCheckIn ? 'check-in' : 'check-out';
    final req = jsonMap(jsonMap(today['requirements'])[isCheckIn ? 'checkIn' : 'checkOut']);
    final needLocation = req['requireLocation'] != false;
    // Always enable selfie photo verification for attendance punches
    final needSelfie = req['requireSelfie'] != false;

    final stepTitle = switch (state) {
      'not_checked_in' => 'Step 1: Check In',
      'checked_in' => 'Step 2: Break In',
      'on_break' => 'Step 3: Break Out',
      'session_2_active' => 'Step 4: Check Out',
      _ => isCheckIn ? 'Check in' : 'Check out',
    };

    _attemptKey ??= newIdempotencyKey();
    setState(() => _problem = null);
    final body = <String, dynamic>{};
    try {
      // 1. Geolocation verification first so we know if user is inside or outside company area
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
      // When outside company area, selfie is skipped per company policy
      if (needSelfie && !isOutsideCompany) {
        setState(() => _phase = _Phase.selfie);
        final locName = loc['name'] as String?;
        final id = await _takeSelfie(isCheckIn, locName, stepTitle: stepTitle);
        if (id == null) {
          setState(() => _phase = _Phase.idle);
          return;
        }
        body['selfieFileId'] = id;
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

      final successMsg = switch (state) {
        'not_checked_in' => 'Check in recorded at $punchTime.',
        'checked_in' => 'Break in recorded at $punchTime. (0.5 day counted)',
        'on_break' => 'Break out recorded at $punchTime. Welcome back!',
        'session_2_active' => 'Check out recorded at $punchTime. 1.0 Full Attendance Day completed!',
        _ => '${isCheckIn ? 'Checked in' : 'Checked out'} at $punchTime.',
      };

      NToast.of(context).show(r['exception'] == true
          ? 'Recorded at $punchTime. Your exception was sent for approval.'
          : successMsg);
      setState(() => _phase = _Phase.idle);
      _view.currentState?.reload();
      widget.onChanged?.call();
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

  Future<void> _resetDemo() async {
    try {
      await context.api.post('/attendance/reset-demo');
      if (!mounted) return;
      NToast.of(context).show('Attendance demo reset. You can test from Step 1 again.');
      _view.currentState?.reload();
      widget.onChanged?.call();
    } catch (e) {
      if (mounted) showError(context, e);
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
          if (e.code != 'NO_EMPLOYEE' && e.code != 'EMPLOYEE_INACTIVE') NButton(label: 'Try again', compact: true, variant: NButtonVariant.secondary, onPressed: () => _punch(today)),
          if (allowRemote) NButton(label: 'Record as remote', compact: true, variant: NButtonVariant.secondary, onPressed: () => _punch(today, remote: true)),
          if (exceptionAvailable) NButton(label: 'Request exception', compact: true, onPressed: () => _requestException(today)),
        ]),
      ),
    );
  }

  Widget _buildPunchStepper(NTokens t, int currentStep, Map<String, dynamic> rec, bool isMobile) {
    final session1 = jsonMap(rec['session1']);
    final session2 = jsonMap(rec['session2']);
    final s1CheckIn = jsonMap(session1['checkIn']);
    final s1CheckOut = jsonMap(session1['checkOut']);
    final s2CheckIn = jsonMap(session2['checkIn']);
    final s2CheckOut = jsonMap(session2['checkOut']);
    final recCheckIn = jsonMap(rec['checkIn']);
    final recCheckOut = jsonMap(rec['checkOut']);

    final s1In = s1CheckIn['at'] as String? ?? recCheckIn['at'] as String?;
    final s1Out = s1CheckOut['at'] as String?;
    final s2In = s2CheckIn['at'] as String?;
    final s2Out = s2CheckOut['at'] as String? ?? (currentStep == 4 ? recCheckOut['at'] as String? : null);

    final steps = [
      (title: '1. Check In', time: s1In != null ? Fmt.time(s1In) : null, icon: Icons.login_rounded),
      (title: '2. Break In', time: s1Out != null ? Fmt.time(s1Out) : null, icon: Icons.coffee_rounded),
      (title: '3. Break Out', time: s2In != null ? Fmt.time(s2In) : null, icon: Icons.play_circle_outline_rounded),
      (title: '4. Check Out', time: s2Out != null ? Fmt.time(s2Out) : null, icon: Icons.logout_rounded),
    ];

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.pillTrack,
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
              Text(
                'Punches (2 In + 2 Out = 1 Day)',
                style: t.text.caption(weight: FontWeight.w600).copyWith(color: t.ink),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: currentStep == 4
                      ? t.green.withValues(alpha: t.isDark ? 0.22 : 0.16)
                      : (currentStep >= 2
                          ? t.amber.withValues(alpha: t.isDark ? 0.22 : 0.16)
                          : t.accent.withValues(alpha: t.isDark ? 0.22 : 0.16)),
                  borderRadius: BorderRadius.circular(NTokens.radiusPill),
                ),
                child: Text(
                  currentStep == 4
                      ? '1.0 Full Day'
                      : (currentStep >= 2 ? '0.5 Half Day' : '0.0 Day'),
                  style: t.text.caption(weight: FontWeight.w700).copyWith(
                        color: currentStep == 4
                            ? t.green
                            : (currentStep >= 2 ? t.amber : t.accent),
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              for (var i = 0; i < steps.length; i++) ...[
                Expanded(
                  child: Column(
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i < currentStep
                              ? t.green
                              : (i == currentStep ? t.accent : t.card),
                          border: Border.all(
                            color: i == currentStep ? t.focusRing : t.cardBorder,
                            width: i == currentStep ? 2 : 1,
                          ),
                        ),
                        child: Center(
                          child: Icon(
                            i < currentStep
                                ? Icons.check_rounded
                                : steps[i].icon,
                            size: 14,
                            color: i < currentStep
                                ? Colors.white
                                : (i == currentStep ? t.onAccent : t.muted),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          isMobile ? steps[i].title.replaceFirst(RegExp(r'^\d+\.\s*'), '') : steps[i].title,
                          textAlign: TextAlign.center,
                          style: t.text.caption(
                            weight: i == currentStep ? FontWeight.w700 : (i < currentStep ? FontWeight.w600 : FontWeight.w400),
                          ).copyWith(
                            fontSize: isMobile ? 10 : 11,
                            color: i == currentStep ? t.accent : (i < currentStep ? t.ink : t.muted),
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          steps[i].time ?? (i == currentStep ? 'Next' : '—'),
                          textAlign: TextAlign.center,
                          style: t.text.caption(
                            weight: steps[i].time != null ? FontWeight.w600 : FontWeight.w400,
                          ).copyWith(
                            fontSize: isMobile ? 9 : 10,
                            color: steps[i].time != null
                                ? t.green
                                : (i == currentStep ? t.accent : t.muted),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (i < steps.length - 1)
                  Container(
                    width: 6,
                    height: 2,
                    margin: const EdgeInsets.only(bottom: 24),
                    color: i < currentStep ? t.green : t.divider,
                  ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSessionsBreakdown(NTokens t, Map<String, dynamic> rec, int step, double dayCount) {
    final session1 = jsonMap(rec['session1']);
    final session2 = jsonMap(rec['session2']);
    final s1CheckIn = jsonMap(session1['checkIn']);
    final s1CheckOut = jsonMap(session1['checkOut']);
    final s2CheckIn = jsonMap(session2['checkIn']);
    final s2CheckOut = jsonMap(session2['checkOut']);
    final recCheckIn = jsonMap(rec['checkIn']);
    final recCheckOut = jsonMap(rec['checkOut']);

    final s1In = s1CheckIn['at'] as String? ?? recCheckIn['at'] as String?;
    final s1Out = s1CheckOut['at'] as String?;
    final s2In = s2CheckIn['at'] as String?;
    final s2Out = s2CheckOut['at'] as String? ?? (step == 4 ? recCheckOut['at'] as String? : null);

    final s1InLat = s1CheckIn['latitude'] ?? recCheckIn['latitude'];
    final s1InLng = s1CheckIn['longitude'] ?? recCheckIn['longitude'];
    final s2InLat = s2CheckIn['latitude'];
    final s2InLng = s2CheckIn['longitude'];
    final s2OutLat = s2CheckOut['latitude'] ?? recCheckOut['latitude'];
    final s2OutLng = s2CheckOut['longitude'] ?? recCheckOut['longitude'];
    final s2Lat = s2OutLat ?? s2InLat;
    final s2Lng = s2OutLng ?? s2InLng;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
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
            runSpacing: 4,
            children: [
              Text('Sessions & Work Duration', style: t.text.caption(weight: FontWeight.w700).copyWith(color: t.ink)),
              if ((rec['workedMinutes'] as num? ?? 0) > 0)
                Text(
                  'Total: ${Fmt.minutes(rec['workedMinutes'])}',
                  style: t.text.caption(weight: FontWeight.w700).copyWith(color: t.accent),
                ),
            ],
          ),
          const SizedBox(height: 8),
          // Session 1
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: t.pillTrack,
              borderRadius: BorderRadius.circular(t.radiusTile),
              border: Border.all(color: t.divider),
            ),
            child: Row(
              children: [
                Icon(Icons.wb_sunny_outlined, size: 16, color: t.amber),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Session 1 (Morning)', style: t.text.caption(weight: FontWeight.w600).copyWith(color: t.ink)),
                      Text(
                        s1In != null
                            ? 'Check In: ${Fmt.time(s1In)} ${s1Out != null ? '· Break In: ${Fmt.time(s1Out)}' : '· (Active)'}'
                            : 'Not started',
                        style: t.text.caption().copyWith(color: t.muted),
                      ),
                      if (s1InLat != null && s1InLng != null) ...[
                        const SizedBox(height: 3),
                        InkWell(
                          onTap: () => bridge.openUrl('https://www.google.com/maps?q=$s1InLat,$s1InLng'),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.location_on_rounded, size: 12, color: t.accent),
                              const SizedBox(width: 2),
                              Text(
                                'View on Google Maps',
                                style: t.text.caption(weight: FontWeight.w600).copyWith(
                                      color: t.accent,
                                      fontSize: 10,
                                      decoration: TextDecoration.underline,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: step >= 2
                        ? t.green.withValues(alpha: t.isDark ? 0.22 : 0.16)
                        : (step >= 1 ? t.accent.withValues(alpha: t.isDark ? 0.22 : 0.16) : t.card),
                    borderRadius: BorderRadius.circular(NTokens.radiusPill),
                  ),
                  child: Text(
                    step >= 2 ? '0.5 Day Done' : (step >= 1 ? 'In Progress' : 'Pending'),
                    style: t.text.caption(weight: FontWeight.w600).copyWith(
                          fontSize: 10,
                          color: step >= 2 ? t.green : (step >= 1 ? t.accent : t.muted),
                        ),
                  ),
                ),
              ],
            ),
          ),
          if (step >= 2) ...[
            const SizedBox(height: 6),
            // Lunch break
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: t.pillTrack,
                borderRadius: BorderRadius.circular(t.radiusTile),
                border: Border.all(color: t.divider),
              ),
              child: Row(
                children: [
                  Icon(Icons.coffee_rounded, size: 14, color: step == 2 ? t.amber : t.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      step == 2
                          ? 'Currently on Break (Break In recorded)'
                          : (step > 2 ? 'Break completed (Break Out recorded)' : 'Break (Pending)'),
                      style: t.text.caption(weight: FontWeight.w500).copyWith(color: step == 2 ? t.ink : t.muted),
                    ),
                  ),
                  if (step == 2)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: t.amber.withValues(alpha: t.isDark ? 0.22 : 0.16),
                        borderRadius: BorderRadius.circular(NTokens.radiusPill),
                      ),
                      child: Text(
                        'On Break',
                        style: t.text.caption(weight: FontWeight.w600).copyWith(
                              fontSize: 10,
                              color: t.amber,
                            ),
                      ),
                    )
                  else if (step > 2)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: t.green.withValues(alpha: t.isDark ? 0.22 : 0.16),
                        borderRadius: BorderRadius.circular(NTokens.radiusPill),
                      ),
                      child: Text(
                        'Break Out Done',
                        style: t.text.caption(weight: FontWeight.w600).copyWith(
                              fontSize: 10,
                              color: t.green,
                            ),
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (step >= 2) ...[
            const SizedBox(height: 6),
            // Session 2
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: t.pillTrack,
                borderRadius: BorderRadius.circular(t.radiusTile),
                border: Border.all(color: t.divider),
              ),
              child: Row(
                children: [
                  Icon(Icons.nights_stay_outlined, size: 16, color: t.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Session 2 (Afternoon)', style: t.text.caption(weight: FontWeight.w600).copyWith(color: t.ink)),
                        Text(
                          s2In != null
                              ? 'Break Out: ${Fmt.time(s2In)} ${s2Out != null ? '· Check Out: ${Fmt.time(s2Out)}' : '· (Active)'}'
                              : 'Pending break return',
                          style: t.text.caption().copyWith(color: t.muted),
                        ),
                        if (s2Lat != null && s2Lng != null) ...[
                          const SizedBox(height: 3),
                          InkWell(
                            onTap: () => bridge.openUrl('https://www.google.com/maps?q=$s2Lat,$s2Lng'),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.location_on_rounded, size: 12, color: t.accent),
                                const SizedBox(width: 2),
                                Text(
                                  'View on Google Maps',
                                  style: t.text.caption(weight: FontWeight.w600).copyWith(
                                        color: t.accent,
                                        fontSize: 10,
                                        decoration: TextDecoration.underline,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: step == 4
                          ? t.green.withValues(alpha: t.isDark ? 0.22 : 0.16)
                          : (step == 3 ? t.accent.withValues(alpha: t.isDark ? 0.22 : 0.16) : t.card),
                      borderRadius: BorderRadius.circular(NTokens.radiusPill),
                    ),
                    child: Text(
                      step == 4 ? '1.0 Full Day Done' : (step == 3 ? 'In Progress' : 'Pending'),
                      style: t.text.caption(weight: FontWeight.w600).copyWith(
                            fontSize: 10,
                            color: step == 4 ? t.green : (step == 3 ? t.accent : t.muted),
                          ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final isMobile = NBreakpoint.of(context).isMobile;

    return NGlassCard(
      blur: false,
      child: AsyncView<Json>(
        key: _view,
        load: () async => jsonMap(await context.api.get('/attendance/today')),
        compact: true,
        builder: (context, today, reload) {
          final state = '${today['state']}';
          final rec = jsonMap(today['record']);
          final shift = jsonMap(today['shift']);
          final loc = jsonMap(today['location']);
          final busy = _phase != _Phase.idle;

          final step = (today['step'] as num?)?.toInt() ??
              (state == 'not_checked_in'
                  ? 0
                  : (state == 'checked_in'
                      ? 1
                      : (state == 'on_break'
                          ? 2
                          : (state == 'session_2_active' ? 3 : 4))));

          final dayCount = (today['attendanceDayCount'] as num?)?.toDouble() ??
              (rec['dayCount'] as num?)?.toDouble() ??
              (step == 4 ? 1.0 : (step >= 2 ? 0.5 : 0.0));

          final label = switch (_phase) {
            _Phase.locating => 'Getting your location…',
            _Phase.selfie => 'Waiting for photo…',
            _Phase.sending => 'Recording punch…',
            _Phase.idle => switch (state) {
                'not_checked_in' => 'Check in',
                'checked_in' => 'Break in',
                'on_break' => 'Break out',
                'session_2_active' => 'Check out',
                _ => 'Attendance Complete',
              },
          };

          final buttonIcon = switch (state) {
            'not_checked_in' => Icons.login_rounded,
            'checked_in' => Icons.coffee_rounded,
            'on_break' => Icons.play_circle_outline_rounded,
            'session_2_active' => Icons.logout_rounded,
            _ => Icons.task_alt_rounded,
          };

          final isCheckInAction = state == 'not_checked_in' || state == 'on_break';

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              NCardTitle(
                'Today\'s Attendance',
                subtitle: '${Fmt.date(today['workDate'])}${shift.isNotEmpty ? ' · ${shift['name']} ${shift['startTime']}–${shift['endTime']}' : ' · General Shift'}',
                trailing: StatusChip(
                  step == 4
                      ? 'present'
                      : (step >= 2 ? 'half_day' : (state == 'not_checked_in' ? 'pending' : 'present')),
                  label: switch (state) {
                    'not_checked_in' => 'Not checked in',
                    'checked_in' => 'Session 1 Active',
                    'on_break' => 'On Break',
                    'session_2_active' => 'Session 2 Active',
                    'checked_out' => '1.0 Day Complete',
                    _ => Fmt.label(state),
                  },
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

              // Visual Stepper for the 4 punches (2 in, 2 out)
              _buildPunchStepper(t, step, rec, isMobile),

              // Detailed Session Cards if started
              if (step >= 1) _buildSessionsBreakdown(t, rec, step, dayCount),

              // Work location row
              if (!widget.compact)
                NInfoRow(
                  label: 'Work location',
                  value: loc.isEmpty ? 'Main Office' : '${loc['name']} (within ${loc['radiusMeters'] ?? 100} m)',
                ),

              if (_problem != null) _problemPanel(t, today),
              const SizedBox(height: 12),

              // Primary Punch Action Button
              if (step < 4)
                NButton(
                  label: label,
                  icon: buttonIcon,
                  variant: NButtonVariant.accent,
                  busy: busy,
                  onPressed: () => _punch(today),
                ),

              // Day Complete Banner & Reset Button
              if (step == 4) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: t.green.withValues(alpha: t.isDark ? 0.20 : 0.12),
                    borderRadius: BorderRadius.circular(t.radiusCard),
                    border: Border.all(color: t.green),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.verified_rounded, color: t.green, size: 24),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '1.0 Full Attendance Day Counted',
                              style: t.text.body(weight: FontWeight.w700).copyWith(color: t.green),
                            ),
                            Text(
                              '2 Check-ins and 2 Check-outs completed successfully.',
                              style: t.text.caption().copyWith(color: t.muted),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                NButton(
                  label: 'Reset demo punches (Start from Step 1)',
                  icon: Icons.refresh_rounded,
                  variant: NButtonVariant.secondary,
                  onPressed: _resetDemo,
                ),
              ],

              // Footer helper details
              if (step < 4)
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
                      if (step > 0 && AppConfig.demo)
                        InkWell(
                          onTap: _resetDemo,
                          child: Text(
                            'Reset demo',
                            style: t.text.caption(weight: FontWeight.w600).copyWith(color: t.accent),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _SelfieSheet extends StatefulWidget {
  const _SelfieSheet({required this.isCheckIn, this.locationName, this.stepTitle});
  final bool isCheckIn;
  final String? locationName;
  final String? stepTitle;

  @override
  State<_SelfieSheet> createState() => _SelfieSheetState();
}

class _SelfieSheetState extends State<_SelfieSheet> {
  PickedFile? _picked;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Directly open the camera on launch
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _picked == null) {
        _takePhoto();
      }
    });
  }

  Future<void> _takePhoto() async {
    setState(() => _busy = true);
    try {
      final f = await bridge.pickFile(accept: 'image/*', capture: 'user');
      if (f != null && mounted) {
        Navigator.of(context).pop(f);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _useDemoPhoto() async {
    setState(() => _busy = true);
    try {
      final data = await rootBundle.load('assets/demo/selfie.jpg');
      final bytes = data.buffer.asUint8List();
      if (mounted) {
        Navigator.of(context).pop(PickedFile(name: 'selfie.jpg', bytes: bytes, mimeType: 'image/jpeg'));
      }
    } catch (_) {
      if (mounted) {
        Navigator.of(context).pop(
          PickedFile(
            name: 'selfie.png',
            bytes: Uint8List.fromList([
              0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
              0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
              0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
              0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x60, 0x60, 0x60, 0x60,
              0x00, 0x00, 0x00, 0x05, 0x00, 0x01, 0xA7, 0x34, 0x5B, 0x80, 0x00, 0x00,
              0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
            ]),
            mimeType: 'image/png',
          ),
        );
      }
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
              if (widget.locationName != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '📍 ${widget.locationName}',
                    style: t.text.caption().copyWith(color: t.muted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
            const SizedBox(height: 8),
            NButton(
              label: 'Use demo selfie photo',
              icon: Icons.auto_awesome_rounded,
              variant: NButtonVariant.secondary,
              onPressed: _useDemoPhoto,
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
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(NTokens.radiusPill),
                        ),
                      ),
                      icon: const Icon(Icons.check_circle_rounded, size: 20, color: Colors.white),
                      label: Text(
                        '✓ Confirm & Continue',
                        style: t.text.body(weight: FontWeight.w700, color: Colors.white),
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
