import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
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
    if (!mounted) return null;
    final picked = await showNSheet<PickedFile?>(
      context,
      title: stepTitle ?? (checkIn ? 'Check-in photo' : 'Check-out photo'),
      subtitle: 'Capture attendance photo to verify your punch.',
      builder: (ctx) => _SelfieSheet(isCheckIn: checkIn, locationName: locationName, stepTitle: stepTitle),
    );

    if (picked == null || !mounted) return null;
    setState(() => _phase = _Phase.sending);
    final rec = await api.upload(picked, purpose: 'selfie');
    return rec['id'] as String?;
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

      final successMsg = isCheckIn
          ? 'Check-in recorded at $punchTime.'
          : 'Check-out recorded at $punchTime.';

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

  Widget _buildShiftSchedule(NTokens t, String state, Map<String, dynamic> rec, double dayCount, bool isMobile) {
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
              spacing: 16,
              runSpacing: 10,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 80),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('First Check In', style: t.text.caption(weight: FontWeight.w500).copyWith(color: t.muted)),
                      const SizedBox(height: 2),
                      Text(
                        hasCheckedIn ? Fmt.time(inTime) : '—',
                        style: t.text.caption(weight: FontWeight.w700).copyWith(color: hasCheckedIn ? t.ink : t.muted),
                      ),
                      if (inLat != null && inLng != null) ...[
                        const SizedBox(height: 2),
                        InkWell(
                          onTap: () => bridge.openUrl('https://www.google.com/maps?q=$inLat,$inLng'),
                          child: Text(
                            'View GPS',
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
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 80),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Latest Check Out', style: t.text.caption(weight: FontWeight.w500).copyWith(color: t.muted)),
                      const SizedBox(height: 2),
                      Text(
                        hasCheckedOut ? Fmt.time(outTime) : (hasCheckedIn ? 'In Progress' : '—'),
                        style: t.text.caption(weight: FontWeight.w700).copyWith(color: hasCheckedOut ? t.ink : t.muted),
                      ),
                      if (outLat != null && outLng != null) ...[
                        const SizedBox(height: 2),
                        InkWell(
                          onTap: () => bridge.openUrl('https://www.google.com/maps?q=$outLat,$outLng'),
                          child: Text(
                            'View GPS',
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
                if (workedMins > 0)
                  ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 80),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Worked', style: t.text.caption(weight: FontWeight.w500).copyWith(color: t.muted)),
                        const SizedBox(height: 2),
                        Text(
                          Fmt.minutes(workedMins),
                          style: t.text.caption(weight: FontWeight.w700).copyWith(color: t.accent),
                        ),
                        Text(breakMins > 0 ? '${Fmt.minutes(breakMins)} break' : 'net work', style: t.text.caption().copyWith(fontSize: 9, color: t.muted)),
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
              _buildShiftSchedule(t, state, rec, dayCount, isMobile),

              // Work location row
              if (!widget.compact)
                NInfoRow(
                  label: 'Work location',
                  value: loc.isEmpty ? 'Main Office' : '${loc['name']} (within ${loc['radiusMeters'] ?? 100} m)',
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
              if (!isCheckedOut)
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
                          isMobile ? '✓ Confirm' : '✓ Confirm & Continue',
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
