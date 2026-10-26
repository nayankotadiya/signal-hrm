import 'package:flutter/material.dart';
import 'package:n_ui/n_ui.dart';

import '../../app/services.dart';
import '../../data/api.dart';
import '../../data/lookups.dart';
import '../../widgets/async_view.dart';
import '../../widgets/form_kit.dart';
import '../../widgets/format.dart';
import '../../widgets/section.dart';
import '../../widgets/status.dart';
import '../../platform/bridge.dart';
import '../../widgets/authed_image.dart';
import 'attendance_card.dart';
import 'leave_tab.dart';
import 'shifts_tab.dart';

class TimeSection extends StatelessWidget {
  const TimeSection({super.key, this.tab});
  final String? tab;

  @override
  Widget build(BuildContext context) {
    return SectionPage(
      basePath: '/time',
      tabId: tab,
      title: 'Time',
      boldWord: 'tracking',
      subtitle: 'Attendance, leave, shifts and the holiday calendar.',
      tabs: [
        SectionTab('attendance', 'Attendance', Icons.fingerprint_rounded, (_) => const AttendanceTab(), visible: (me) => me.feature('attendance') && me.can('attendance', 'view')),
        SectionTab('leave', 'Leave', Icons.beach_access_rounded, (_) => const LeaveTab(), visible: (me) => me.feature('leave') && me.can('leave', 'view')),
        SectionTab('team', 'Team today', Icons.groups_2_rounded, (_) => const TeamLiveTab(), visible: (me) => me.feature('attendance') && me.can('attendance', 'view', 'team')),
        SectionTab('review', 'Review', Icons.policy_rounded, (_) => const FlagsTab(), visible: (me) => me.feature('attendance') && me.can('attendance', 'approve', 'team')),
        SectionTab('shifts', 'Shifts', Icons.view_timeline_rounded, (_) => const ShiftsTab(), visible: (me) => me.feature('shifts') && me.can('shifts', 'view')),
        SectionTab('calendar', 'Holidays', Icons.event_rounded, (_) => const HolidaysTab(), visible: (me) => me.feature('holidays') && me.can('holidays', 'view')),
      ],
    );
  }
}

const correctionKinds = [
  NOption('missed_check_in', 'Missed check-in'),
  NOption('missed_check_out', 'Missed check-out'),
  NOption('wrong_time', 'Wrong time recorded'),
  NOption('gps_failure', 'Location could not be verified'),
  NOption('other', 'Other'),
];

/// Builds an ISO instant from a day + "HH:MM" in the browser's time zone.
String? _instant(String? day, String? hhmm) {
  if (day == null || hhmm == null || !RegExp(r'^\d{1,2}:\d{2}$').hasMatch(hhmm)) return null;
  final p = hhmm.split(':');
  final d = DateTime.parse('${day}T00:00:00');
  return DateTime(d.year, d.month, d.day, int.parse(p[0]), int.parse(p[1])).toUtc().toIso8601String();
}

Future<void> requestCorrection(BuildContext context, {String? day, VoidCallback? onDone}) async {
  final r = await showFormSheet<Json>(
    context,
    title: 'Request a correction',
    subtitle: 'Your manager approves it. The original record stays in the history.',
    initial: {if (day != null) 'workDate': day},
    fields: const [
      FieldSpec('workDate', 'Day', kind: FieldKind.date, required: true),
      FieldSpec('kind', 'What happened', kind: FieldKind.select, required: true, options: correctionKinds),
      FieldSpec('checkInTime', 'Correct check-in time', kind: FieldKind.time, helper: 'Leave empty if the check-in was right.'),
      FieldSpec('checkOutTime', 'Correct check-out time', kind: FieldKind.time),
      FieldSpec('reason', 'Reason', kind: FieldKind.multiline, required: true, maxLength: 500),
    ],
    submitLabel: 'Send for approval',
    successMessage: 'Correction sent for approval.',
    submit: (v, key) async {
      final day = v['workDate'] as String?;
      return jsonMap(await context.api.post('/attendance/corrections', idempotencyKey: key, body: {
        'workDate': day,
        'kind': v['kind'],
        'reason': v['reason'],
        if (_instant(day, v['checkInTime'] as String?) != null) 'requestedCheckIn': _instant(day, v['checkInTime'] as String?),
        if (_instant(day, v['checkOutTime'] as String?) != null) 'requestedCheckOut': _instant(day, v['checkOutTime'] as String?),
      }));
    },
  );
  if (r != null) onDone?.call();
}

class AttendanceTab extends StatefulWidget {
  const AttendanceTab({super.key});

  @override
  State<AttendanceTab> createState() => _AttendanceTabState();
}

class _AttendanceTabState extends State<AttendanceTab> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  int _rev = 0;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final me = context.me;
    final month = '${_month.year}-${_month.month.toString().padLeft(2, '0')}';
    Color colorFor(String s) => switch (s) {
          'present' => t.green,
          'late' || 'half_day' => t.amber,
          'absent' => t.red,
          'on_leave' => t.accent,
          'holiday' => t.teal,
          'incomplete' || 'pending_correction' => t.amber,
          _ => Colors.transparent,
        };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      CardGrid(minTileWidth: 380, children: [
        if (me.employeeId != null && me.can('attendance', 'create')) AttendanceTodayCard(onChanged: () => setState(() => _rev++)),
        if (me.employeeId != null)
          InfoCard(
            title: 'My month',
            trailing: TextButton(onPressed: () => requestCorrection(context, onDone: () => setState(() => _rev++)), child: Text('Request correction', style: t.text.caption(color: t.ink, weight: FontWeight.w600))),
            child: AsyncView<Json>(
              reloadKey: '$month-$_rev',
              load: () async => jsonMap(await context.api.get('/attendance/calendar', query: {'month': month})),
              builder: (context, cal, _) {
                final days = jsonList(cal['days']);
                final summary = jsonMap(cal['summary']);
                return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  NMonthCalendar(
                    month: _month,
                    weekStart: me.weekStart == 0 ? 7 : me.weekStart,
                    onMonthChanged: (m) => setState(() => _month = m),
                    marks: {
                      for (final d in days)
                        if (d['status'] != 'none' && d['status'] != 'weekly_off') '${d['day']}': [NCalendarMark(color: colorFor('${d['status']}'), label: Fmt.label(d['status']))],
                    },
                    onDayTap: (d) {
                      final key = Fmt.day(d);
                      final info = days.where((x) => x['day'] == key).toList();
                      if (info.isEmpty) return;
                      final i = info.first;
                      NToast.of(context).show('${Fmt.date(key)}: ${Fmt.label(i['status'])}${(i['workedMinutes'] as num? ?? 0) > 0 ? ' · ${Fmt.minutes(i['workedMinutes'])}' : ''}${i['holiday'] != null ? ' · ${i['holiday']}' : ''}');
                    },
                  ),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 6, children: [
                    for (final e in summary.entries)
                      if (e.key != 'none') StatusChip(e.key, label: '${Fmt.label(e.key)}: ${e.value}'),
                  ]),
                ]);
              },
            ),
          ),
      ]),
      const SizedBox(height: 14),
      InfoCard(
        title: 'Correction requests',
        child: AsyncView<List<Json>>(
          reloadKey: _rev,
          load: () async => jsonList(await context.api.get('/attendance/corrections')),
          builder: (context, items, _) => items.isEmpty
              ? const NEmptyState(title: 'No correction requests', compact: true, icon: Icons.edit_calendar_rounded)
              : NDataTable(
                  columns: const [NColumn('Day'), NColumn('Person', hideOnTablet: true), NColumn('Kind'), NColumn('Reason', flex: 3, hideOnTablet: true), NColumn('Status')],
                  rows: [
                    for (final c in items)
                      [
                        Text(Fmt.date(c['workDate'])),
                        Text('${c['employeeName'] ?? ''}'),
                        Text(Fmt.label(c['kind'])),
                        Text('${c['reason'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis),
                        StatusChip('${c['status']}'),
                      ],
                  ],
                ),
        ),
      ),
      if (me.can('attendance', 'view', 'team')) ...[const SizedBox(height: 14), const _AttendanceRecords()],
    ]);
  }
}

/// Scoped attendance register with filters (managers, HR).
class _AttendanceRecords extends StatefulWidget {
  const _AttendanceRecords();

  @override
  State<_AttendanceRecords> createState() => _AttendanceRecordsState();
}

class _AttendanceRecordsState extends State<_AttendanceRecords> {
  DateTime _from = DateTime.now().subtract(const Duration(days: 6));
  DateTime _to = DateTime.now();
  String _status = '';
  bool _flagged = false;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return InfoCard(
      title: 'Attendance register',
      subtitle: 'Distance, accuracy and verification are stored on every punch.',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Toolbar(children: [
          SizedBox(width: 170, child: NDateField(label: 'From', value: _from, required: true, onChanged: (d) => setState(() => _from = d ?? _from))),
          SizedBox(width: 170, child: NDateField(label: 'To', value: _to, required: true, onChanged: (d) => setState(() => _to = d ?? _to))),
          SizedBox(
            width: 180,
            child: NSelect<String>(
              label: 'Status',
              value: _status,
              options: const [NOption('', 'Any'), NOption('present', 'Present'), NOption('late', 'Late'), NOption('absent', 'Absent'), NOption('incomplete', 'Incomplete'), NOption('pending_correction', 'Pending correction')],
              onChanged: (v) => setState(() => _status = v ?? ''),
            ),
          ),
          SizedBox(width: 200, child: NCheckRow(label: 'Flagged only', value: _flagged, onChanged: (v) => setState(() => _flagged = v))),
        ]),
        PagedList(
          path: '/attendance',
          query: {'from': Fmt.day(_from), 'to': Fmt.day(_to), 'status': _status, if (_flagged) 'flagged': true},
          reloadKey: '${Fmt.day(_from)}${Fmt.day(_to)}$_status$_flagged',
          emptyTitle: 'No attendance records for these filters',
          itemBuilder: (_, __, ___) => const SizedBox.shrink(),
          wrap: (context, items, _) => NDataTable(
            columns: const [NColumn('Person', flex: 3), NColumn('Day'), NColumn('In'), NColumn('Out'), NColumn('Worked', numeric: true, hideOnTablet: true), NColumn('Check & Location', flex: 4, hideOnTablet: true), NColumn('Status')],
            rows: [
              for (final r in items) ...[
                () {
                  final cIn = jsonMap(r['checkIn']);
                  final cOut = jsonMap(r['checkOut']);
                  final inLat = cIn['latitude'];
                  final inLng = cIn['longitude'];
                  final outLat = cOut['latitude'];
                  final outLng = cOut['longitude'];
                  final inAddr = cIn['address'] as String?;
                  final outAddr = cOut['address'] as String?;
                  final displayAddr = inAddr ?? outAddr;
                  final inPhoto = cIn['selfieFileId'] as String?;
                  final outPhoto = cOut['selfieFileId'] as String?;
                  final hasLoc = (inLat != null && inLng != null) || (outLat != null && outLng != null);
                  return [
                    Text('${r['employeeName'] ?? ''}'),
                    Text(Fmt.shortDate(r['workDate'])),
                    Text(Fmt.time(cIn['at'])),
                    Text(Fmt.time(cOut['at'])),
                    Text(Fmt.minutes(r['workedMinutes'])),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          [
                            if (cIn['verification'] != null) Fmt.label(cIn['verification']),
                            if (cIn['distanceMeters'] != null) '${cIn['distanceMeters']} m',
                            if (cIn['accuracyMeters'] != null) '±${cIn['accuracyMeters']} m',
                            if ((r['flags'] as List? ?? const []).isNotEmpty) '⚑ flagged',
                          ].join(' · '),
                          style: t.text.caption(),
                        ),
                        if (displayAddr != null && displayAddr.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.location_on_rounded, size: 12, color: t.accent),
                              const SizedBox(width: 3),
                              Flexible(
                                child: Text(
                                  displayAddr,
                                  style: t.text.caption(weight: FontWeight.w600).copyWith(fontSize: 11, color: t.ink),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ],
                        if (hasLoc || inPhoto != null || outPhoto != null) ...[
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              if (inPhoto != null)
                                InkWell(
                                  onTap: () => _viewPhotoModal(context, inPhoto, 'Check-in Face Verification', cIn['at'], inAddr),
                                  borderRadius: BorderRadius.circular(4),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.face_rounded, size: 14, color: t.green),
                                        const SizedBox(width: 2),
                                        Text('In Photo', style: t.text.caption(weight: FontWeight.w600).copyWith(color: t.green, decoration: TextDecoration.underline)),
                                      ],
                                    ),
                                  ),
                                ),
                              if (outPhoto != null)
                                InkWell(
                                  onTap: () => _viewPhotoModal(context, outPhoto, 'Check-out Face Verification', cOut['at'], outAddr),
                                  borderRadius: BorderRadius.circular(4),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.face_rounded, size: 14, color: t.green),
                                        const SizedBox(width: 2),
                                        Text('Out Photo', style: t.text.caption(weight: FontWeight.w600).copyWith(color: t.green, decoration: TextDecoration.underline)),
                                      ],
                                    ),
                                  ),
                                ),
                              if (inLat != null && inLng != null)
                                InkWell(
                                  onTap: () => bridge.openUrl('https://www.google.com/maps?q=$inLat,$inLng'),
                                  borderRadius: BorderRadius.circular(4),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.location_on_rounded, size: 14, color: t.accent),
                                        const SizedBox(width: 2),
                                        Text('In Map', style: t.text.caption(weight: FontWeight.w600).copyWith(color: t.accent, decoration: TextDecoration.underline)),
                                      ],
                                    ),
                                  ),
                                ),
                              if (outLat != null && outLng != null)
                                InkWell(
                                  onTap: () => bridge.openUrl('https://www.google.com/maps?q=$outLat,$outLng'),
                                  borderRadius: BorderRadius.circular(4),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.location_on_outlined, size: 14, color: t.teal),
                                        const SizedBox(width: 2),
                                        Text('Out Map', style: t.text.caption(weight: FontWeight.w600).copyWith(color: t.teal, decoration: TextDecoration.underline)),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                    StatusChip('${r['status']}'),
                  ];
                }(),
              ],
            ],
          ),
        ),
      ]),
    );
  }

  void _viewPhotoModal(BuildContext context, String fileId, String title, dynamic punchTime, String? address) {
    final t = NTokens.of(context);
    showNSheet<void>(
      context,
      title: title,
      subtitle: punchTime != null ? 'Recorded at ${Fmt.time(punchTime)}' : null,
      builder: (ctx) => SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            AuthedImage(fileId: fileId, height: 320),
            if (address != null && address.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: t.card,
                  borderRadius: BorderRadius.circular(t.radiusCard),
                  border: Border.all(color: t.cardBorder),
                ),
                child: Row(
                  children: [
                    Icon(Icons.location_on_rounded, size: 16, color: t.accent),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        address,
                        style: t.text.caption(weight: FontWeight.w600).copyWith(color: t.ink),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Live board for managers: who is in, late, remote or on leave; coverage by location.
class TeamLiveTab extends StatelessWidget {
  const TeamLiveTab({super.key});

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return AsyncView<Json>(
      load: () async => jsonMap(await context.api.get('/attendance/live')),
      builder: (context, d, reload) {
        final people = jsonList(d['people']);
        final counts = jsonMap(d['counts']);
        final coverage = jsonList(d['coverage']);
        const order = ['in', 'late', 'remote', 'left', 'on_leave', 'not_in'];
        const labels = {'in': 'In', 'late': 'Late', 'remote': 'Remote', 'left': 'Left', 'on_leave': 'On leave', 'not_in': 'Not in yet'};
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Toolbar(children: [
            for (final k in order) StatusChip(k == 'in' ? 'present' : (k == 'not_in' ? 'pending' : (k == 'left' ? 'completed' : k)), label: '${labels[k]}: ${counts[k] ?? 0}'),
            NButton(label: 'Refresh', icon: Icons.refresh_rounded, compact: true, variant: NButtonVariant.secondary, onPressed: reload),
          ]),
          if (coverage.any((c) => c['warning'] == true))
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: NBanner(
                tone: NBannerTone.warning,
                title: 'Low coverage',
                message: coverage.where((c) => c['warning'] == true).map((c) => '${c['location']}: ${c['present']} of ${c['expected']} in').join('\n'),
              ),
            ),
          CardGrid(minTileWidth: 260, children: [
            for (final k in order)
              if (people.any((p) => p['state'] == k))
                InfoCard(
                  title: labels[k]!,
                  subtitle: '${people.where((p) => p['state'] == k).length} people',
                  child: Column(children: [
                    for (final p in people.where((p) => p['state'] == k))
                      NListRow(
                        dense: true,
                        leading: NAvatar(name: '${p['name']}', size: 30),
                        title: '${p['name']}',
                        subtitle: [if (p['since'] != null) 'since ${Fmt.time(p['since'])}', if (p['location'] != null) '${p['location']}', if ((p['flags'] as List? ?? const []).isNotEmpty) 'flagged for review'].join(' · '),
                        trailing: (p['flags'] as List? ?? const []).isNotEmpty ? Icon(Icons.flag_rounded, size: 16, color: t.amber, semanticLabel: 'Flagged') : null,
                      ),
                  ]),
                ),
          ]),
          if (people.isEmpty) const NEmptyState(title: 'No one in your scope', icon: Icons.groups_rounded),
        ]);
      },
    );
  }
}

/// Suspicious-pattern review. Flags never change pay or status by themselves.
class FlagsTab extends StatefulWidget {
  const FlagsTab({super.key});

  @override
  State<FlagsTab> createState() => _FlagsTabState();
}

class _FlagsTabState extends State<FlagsTab> {
  String _status = 'open';

  static const _flagText = {
    'shared_device': 'Same device used by several employees',
    'impossible_travel': 'Sudden jump to a far location',
    'repeated_gps_failure': 'Repeated GPS failures',
    'mock_location': 'Mock-location signal from the browser',
    'outside_geofence': 'Recorded outside the geofence',
  };

  Future<void> _review(Json f, String outcome) async {
    final r = await showNConfirm(
      context,
      title: outcome == 'reviewed_concern' ? 'Record a concern' : (outcome == 'dismissed' ? 'Dismiss flag' : 'Mark as fine'),
      message: 'This is a note on the record only. It does not change attendance, pay or status.',
      confirmLabel: 'Save',
      reasonLabel: 'Note',
      reasonRequired: outcome == 'reviewed_concern',
    );
    if (!r.confirmed || !mounted) return;
    try {
      await context.api.post('/attendance/flags/${f['id']}/review', body: {'outcome': outcome, if (r.reason != null) 'note': r.reason});
      if (mounted) {
        NToast.of(context).show('Review saved.');
        setState(() {});
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _evidence(Json f) async {
    final attendanceId = f['attendanceId'];
    if (attendanceId == null) return;
    await showNSheet<void>(
      context,
      title: 'Evidence',
      subtitle: 'Viewing evidence is recorded in the audit log.',
      builder: (ctx) => ApiScope(
        api: context.api,
        child: AsyncView<List<Json>>(
          load: () async => jsonList(await context.api.get('/attendance/$attendanceId/evidence')),
          builder: (ctx, items, _) => items.isEmpty
              ? const NEmptyState(title: 'No photo for this record', icon: Icons.no_photography_rounded)
              : ListView(padding: const EdgeInsets.all(20), children: [
                  for (final e in items) ...[
                    Text('${Fmt.label(e['kind'])} · ${Fmt.dateTime(e['capturedAt'])}', style: NTokens.of(ctx).text.caption()),
                    const SizedBox(height: 6),
                    AuthedImage(fileId: '${e['fileId']}'),
                    const SizedBox(height: 14),
                  ],
                ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final canEvidence = context.me.can('attendance_evidence', 'view', 'team');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const NBanner(message: 'Patterns are flagged for a person to review. Nobody is penalised automatically.', tone: NBannerTone.info),
      const SizedBox(height: 12),
      Toolbar(children: [
        NFilterChips<String>(
          value: _status,
          onChanged: (v) => setState(() => _status = v),
          options: const [NOption('open', 'Open'), NOption('reviewed_ok', 'Fine'), NOption('reviewed_concern', 'Concern'), NOption('dismissed', 'Dismissed')],
        ),
      ]),
      AsyncView<List<Json>>(
        reloadKey: _status,
        load: () async => jsonList(await context.api.get('/attendance/flags', query: {'status': _status})),
        builder: (context, items, reload) => items.isEmpty
            ? const NEmptyState(title: 'Nothing to review', icon: Icons.verified_user_rounded)
            : Column(children: [
                for (final f in items)
                  NGlassCard(
                    blur: false,
                    padding: const EdgeInsets.all(14),
                    child: () {
                      final det = jsonMap(f['details']);
                      final fLat = det['latitude'];
                      final fLng = det['longitude'];
                      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Row(children: [
                          Expanded(child: Text('${f['employeeName'] ?? 'Employee'} · ${_flagText[f['type']] ?? Fmt.label(f['type'])}', style: t.text.body(weight: FontWeight.w600))),
                          StatusChip('${f['severity']}'),
                        ]),
                        const SizedBox(height: 4),
                        Text('${Fmt.dateTime(f['createdAt'])}${det.isEmpty ? '' : ' · ${det.entries.map((e) => '${Fmt.label(e.key)}: ${e.value}').join(', ')}'}', style: t.text.caption()),
                        if (f['reviewNote'] != null) Text('Note: ${f['reviewNote']}', style: t.text.caption()),
                        const SizedBox(height: 10),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          if (_status == 'open') ...[
                            NButton(label: 'Fine', compact: true, variant: NButtonVariant.secondary, onPressed: () => _review(f, 'reviewed_ok')),
                            NButton(label: 'Concern', compact: true, variant: NButtonVariant.secondary, onPressed: () => _review(f, 'reviewed_concern')),
                            NButton(label: 'Dismiss', compact: true, variant: NButtonVariant.secondary, onPressed: () => _review(f, 'dismissed')),
                          ],
                          if (fLat != null && fLng != null)
                            NButton(
                              label: 'View on Map',
                              icon: Icons.map_rounded,
                              compact: true,
                              variant: NButtonVariant.secondary,
                              onPressed: () => bridge.openUrl('https://www.google.com/maps?q=$fLat,$fLng'),
                            ),
                          if (canEvidence && f['attendanceId'] != null)
                            NButton(label: 'View evidence', icon: Icons.photo_rounded, compact: true, variant: NButtonVariant.secondary, onPressed: () => _evidence(f)),
                        ]),
                      ]);
                    }(),
                  ),
              ].expand((w) => [w, const SizedBox(height: 10)]).toList()),
      ),
    ]);
  }
}

/// Holidays and HR events.
class HolidaysTab extends StatefulWidget {
  const HolidaysTab({super.key});

  @override
  State<HolidaysTab> createState() => _HolidaysTabState();
}

class _HolidaysTabState extends State<HolidaysTab> {
  int _year = DateTime.now().year;
  int _rev = 0;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final canManage = context.me.can('holidays', 'manage', 'organization');
    return CardGrid(minTileWidth: 380, children: [
      InfoCard(
        title: 'Holidays $_year',
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(tooltip: 'Previous year', icon: const Icon(Icons.chevron_left_rounded), onPressed: () => setState(() => _year--)),
          IconButton(tooltip: 'Next year', icon: const Icon(Icons.chevron_right_rounded), onPressed: () => setState(() => _year++)),
          if (canManage)
            NButton(
              label: 'Add',
              icon: Icons.add_rounded,
              compact: true,
              onPressed: () async {
                final r = await showFormSheet<Json>(
                  context,
                  title: 'Add holiday',
                  fields: const [
                    FieldSpec('date', 'Date', kind: FieldKind.date, required: true),
                    FieldSpec('name', 'Name', required: true),
                    FieldSpec('optional', 'Optional holiday', kind: FieldKind.toggle, description: "Employees choose whether to take it; it isn't skipped in leave counts."),
                  ],
                  submit: (v, key) async => jsonMap(await context.api.post('/holidays', body: {...v, 'optional': v['optional'] == true}, idempotencyKey: key)),
                  successMessage: 'Holiday added.',
                );
                if (r != null) setState(() => _rev++);
              },
            ),
        ]),
        child: AsyncView<List<Json>>(
          reloadKey: '$_year-$_rev',
          load: () async => jsonList(await context.api.get('/holidays', query: {'year': _year})),
          builder: (context, items, reload) => items.isEmpty
              ? const NEmptyState(title: 'No holidays added for this year', compact: true, icon: Icons.beach_access_rounded)
              : Column(children: [
                  for (final h in items)
                    NListRow(
                      dense: true,
                      leading: SizedBox(width: 44, child: Text(Fmt.shortDate(h['date']), style: t.text.caption(weight: FontWeight.w600))),
                      title: '${h['name']}',
                      subtitle: '${Fmt.weekday(h['date'])}${h['optional'] == true ? ' · optional' : ''}${(h['locationIds'] as List? ?? const []).isNotEmpty ? ' · some locations' : ''}',
                      trailing: canManage
                          ? IconButton(
                              tooltip: 'Delete holiday',
                              icon: Icon(Icons.delete_outline_rounded, size: 18, color: t.muted),
                              onPressed: () async {
                                final c = await showNConfirm(context, title: 'Delete ${h['name']}?', message: 'Attendance and leave counts for that day will change.', confirmLabel: 'Delete', destructive: true);
                                if (!c.confirmed || !context.mounted) return;
                                try {
                                  await context.api.delete('/holidays/${h['id']}');
                                  reload();
                                } catch (e) {
                                  if (context.mounted) showError(context, e);
                                }
                              },
                            )
                          : null,
                    ),
                ]),
        ),
      ),
      InfoCard(
        title: 'Events',
        trailing: canManage
            ? NButton(
                label: 'Add',
                icon: Icons.add_rounded,
                compact: true,
                onPressed: () async {
                  final r = await showFormSheet<Json>(
                    context,
                    title: 'Add event',
                    fields: const [
                      FieldSpec('title', 'Title', required: true),
                      FieldSpec('date', 'Date', kind: FieldKind.date, required: true),
                      FieldSpec('time', 'Start time', kind: FieldKind.time, required: true),
                      FieldSpec('eventType', 'Type', kind: FieldKind.select, options: [NOption('company', 'Company'), NOption('training', 'Training'), NOption('celebration', 'Celebration'), NOption('deadline', 'Deadline'), NOption('other', 'Other')]),
                      FieldSpec('description', 'Description', kind: FieldKind.multiline),
                    ],
                    submit: (v, key) async => jsonMap(await context.api.post('/events', idempotencyKey: key, body: {
                      'title': v['title'],
                      'startAt': _instant(v['date'] as String?, v['time'] as String?),
                      'eventType': v['eventType'] ?? 'company',
                      if (v['description'] != null) 'description': v['description'],
                    })),
                    successMessage: 'Event added.',
                  );
                  if (r != null) setState(() => _rev++);
                },
              )
            : null,
        child: AsyncView<List<Json>>(
          reloadKey: _rev,
          load: () async => jsonList(await context.api.get('/events')),
          builder: (context, items, _) => items.isEmpty
              ? const NEmptyState(title: 'No upcoming events', compact: true, icon: Icons.event_rounded)
              : Column(children: [
                  for (final e in items) NListRow(dense: true, title: '${e['title']}', subtitle: '${Fmt.dateTime(e['startAt'])} · ${Fmt.label(e['eventType'])}', trailing: StatusChip('${e['status']}')),
                ]),
        ),
      ),
    ]);
  }
}

/// Re-exported for other sections (people picker in forms).
const employeeField = FieldSpec('employeeId', 'Employee', kind: FieldKind.asyncSelect, loadOptions: Lookups.employees, required: true);
