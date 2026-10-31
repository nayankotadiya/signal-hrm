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

const _weekdays = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

/// Shift schedule grid, change/swap requests and (for managers of shifts) shift setup.
class ShiftsTab extends StatefulWidget {
  const ShiftsTab({super.key});

  @override
  State<ShiftsTab> createState() => _ShiftsTabState();
}

class _ShiftsTabState extends State<ShiftsTab> {
  DateTime _from = DateTime.now();
  int _rev = 0;

  Future<void> _request() async {
    final r = await showFormSheet<Json>(
      context,
      title: 'Request a shift change',
      subtitle: 'Rules are checked before your manager sees it.',
      fields: [
        const FieldSpec('kind', 'Type', kind: FieldKind.select, required: true, options: [NOption('change', 'Change my shift'), NOption('swap', 'Swap with a colleague')]),
        const FieldSpec('date', 'From', kind: FieldKind.date, required: true),
        const FieldSpec('toDate', 'To (optional)', kind: FieldKind.date),
        FieldSpec('requestedShiftId', 'Requested shift', kind: FieldKind.asyncSelect, loadOptions: Lookups.shifts, visibleWhen: (v) => v['kind'] == 'change'),
        FieldSpec('swapWithEmployeeId', 'Swap with', kind: FieldKind.asyncSelect, loadOptions: Lookups.employees, visibleWhen: (v) => v['kind'] == 'swap'),
        const FieldSpec('reason', 'Reason', kind: FieldKind.multiline),
      ],
      submitLabel: 'Send request',
      successMessage: 'Shift request sent.',
      submit: (v, key) async => jsonMap(await context.api.post('/shifts/requests', body: v, idempotencyKey: key)),
    );
    if (r != null) setState(() => _rev++);
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final me = context.me;
    final from = DateTime(_from.year, _from.month, _from.day);
    final to = from.add(const Duration(days: 13));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InfoCard(
        title: 'Schedule',
        subtitle: '${Fmt.date(Fmt.day(from))} – ${Fmt.date(Fmt.day(to))}',
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(tooltip: 'Previous two weeks', icon: const Icon(Icons.chevron_left_rounded), onPressed: () => setState(() => _from = _from.subtract(const Duration(days: 14)))),
          IconButton(tooltip: 'Next two weeks', icon: const Icon(Icons.chevron_right_rounded), onPressed: () => setState(() => _from = _from.add(const Duration(days: 14)))),
          if (me.employeeId != null) NButton(label: 'Request change', compact: true, variant: NButtonVariant.secondary, onPressed: _request),
        ]),
        child: AsyncView<Json>(
          reloadKey: '${Fmt.day(from)}-$_rev',
          load: () async => jsonMap(await context.api.get('/shifts/calendar', query: {'from': Fmt.day(from), 'to': Fmt.day(to)})),
          builder: (context, cal, _) {
            final days = [for (final d in (cal['days'] as List? ?? const [])) '$d'];
            final rows = jsonList(cal['rows']);
            if (rows.isEmpty) return const NEmptyState(title: 'No schedule to show', compact: true, icon: Icons.view_timeline_rounded);
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const SizedBox(width: 160),
                  for (final d in days) SizedBox(width: 74, child: Text('${Fmt.weekday(d)}\n${Fmt.shortDate(d)}', textAlign: TextAlign.center, style: t.text.caption(weight: FontWeight.w500))),
                ]),
                const SizedBox(height: 6),
                for (final r in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(children: [
                      SizedBox(width: 160, child: Text('${r['name']}', overflow: TextOverflow.ellipsis, style: t.text.body())),
                      for (final cell in jsonList(r['days']))
                        Container(
                          width: 70,
                          height: 40,
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: cell['shiftId'] == null
                                ? (t.isDark ? const Color(0xFF1E2332) : const Color(0xFFF1F5F9))
                                : (cell['color'] != null ? _hex('${cell['color']}').withValues(alpha: 0.35) : t.accent.withValues(alpha: 0.18)),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: t.isDark ? const Color(0xFF2C3345) : t.divider),
                          ),
                          child: Semantics(
                            label: cell['shiftId'] == null ? 'Off' : '${cell['name']} ${cell['start']} to ${cell['end']}',
                            excludeSemantics: true,
                            child: Text(
                              cell['shiftId'] == null ? 'Off' : '${cell['start']}\n${cell['end']}${cell['overnight'] == true ? ' +1' : ''}',
                              textAlign: TextAlign.center,
                              style: t.text.caption(
                                color: cell['shiftId'] == null ? (t.isDark ? const Color(0xFF98A0B6) : t.muted) : t.ink,
                                size: 10,
                                weight: cell['shiftId'] == null ? FontWeight.w400 : FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                    ]),
                  ),
              ]),
            );
          },
        ),
      ),
      const SizedBox(height: 14),
      InfoCard(
        title: 'Change and swap requests',
        child: AsyncView<List<Json>>(
          reloadKey: _rev,
          load: () async => jsonList(await context.api.get('/shifts/requests')),
          builder: (context, items, _) => items.isEmpty
              ? const NEmptyState(title: 'No shift requests', compact: true, icon: Icons.swap_horiz_rounded)
              : NDataTable(
                  columns: const [NColumn('Person'), NColumn('Type'), NColumn('Dates'), NColumn('Checks', flex: 3, hideOnTablet: true), NColumn('Status')],
                  rows: [
                    for (final r in items)
                      [
                        Text('${r['employeeName'] ?? ''}'),
                        Text(Fmt.label(r['kind'])),
                        Text(r['toDate'] == null ? Fmt.date(r['date']) : '${Fmt.shortDate(r['date'])} – ${Fmt.date(r['toDate'])}'),
                        Text(jsonList(r['checks']).map((c) => '${c['ok'] == true ? '✓' : '✗'} ${c['message']}').join('\n'), style: t.text.caption()),
                        StatusChip('${r['status']}'),
                      ],
                  ],
                ),
        ),
      ),
      if (me.can('shifts', 'manage')) ...[const SizedBox(height: 14), _ShiftSetup(onChanged: () => setState(() => _rev++))],
    ]);
  }
}

Color _hex(String s) {
  final v = int.tryParse(s.replaceFirst('#', ''), radix: 16);
  return v == null ? const Color(0xFF8E8E96) : Color(0xFF000000 | v);
}

List<FieldSpec> shiftFields() => const [
      FieldSpec('name', 'Name', required: true),
      FieldSpec('startTime', 'Start', kind: FieldKind.time, required: true, hint: '09:30'),
      FieldSpec('endTime', 'End', kind: FieldKind.time, required: true, hint: '18:30', helper: 'An end before the start means the shift runs past midnight.'),
      FieldSpec('breakMinutes', 'Break (minutes)', kind: FieldKind.number, min: 0, max: 240),
      FieldSpec('graceMinutes', 'Grace before late (minutes)', kind: FieldKind.number, min: 0, max: 120),
      FieldSpec('overtimeAfterMinutes', 'Overtime after (minutes worked, 0 = shift length)', kind: FieldKind.number, min: 0, max: 1440),
      FieldSpec('workingDaysText', 'Working days', hint: 'Mon,Tue,Wed,Thu,Fri,Sat', helper: 'Comma-separated: Sun, Mon, Tue, Wed, Thu, Fri, Sat'),
      FieldSpec('color', 'Colour', hint: '#6C5CE7'),
    ];

Json shiftBody(Json v) {
  final out = <String, dynamic>{...v}..remove('workingDaysText');
  final txt = v['workingDaysText'] as String?;
  if (txt != null) {
    int dayIndex(String p) {
      final k = p.trim().toLowerCase();
      if (k.length < 3) return -1;
      return _weekdays.indexWhere((w) => w.toLowerCase() == k.substring(0, 3));
    }

    out['workingDays'] = [
      for (final p in txt.split(','))
        if (dayIndex(p) >= 0) dayIndex(p),
    ];
  }
  for (final k in ['breakMinutes', 'graceMinutes', 'overtimeAfterMinutes']) {
    if (out[k] is num) out[k] = (out[k] as num).round();
  }
  return out;
}

class _ShiftSetup extends StatefulWidget {
  const _ShiftSetup({required this.onChanged});
  final VoidCallback onChanged;

  @override
  State<_ShiftSetup> createState() => _ShiftSetupState();
}

class _ShiftSetupState extends State<_ShiftSetup> {
  int _rev = 0;

  Future<void> _edit([Json? s]) async {
    final api = context.api;
    final initial = s == null
        ? <String, dynamic>{'breakMinutes': 60, 'graceMinutes': 10, 'overtimeAfterMinutes': 0, 'workingDaysText': 'Mon,Tue,Wed,Thu,Fri,Sat'}
        : {...s, 'workingDaysText': [for (final d in (s['workingDays'] as List? ?? const [])) _weekdays[(d as num).toInt()]].join(',')};
    final r = await showFormSheet<Json>(
      context,
      title: s == null ? 'New shift' : 'Edit ${s['name']}',
      initial: initial,
      fields: shiftFields(),
      successMessage: 'Shift saved.',
      submit: (v, key) async => jsonMap(s == null ? await api.post('/shifts', body: shiftBody(v), idempotencyKey: key) : await api.patch('/shifts/${s['id']}', body: shiftBody(v), idempotencyKey: key)),
    );
    if (r != null) {
      setState(() => _rev++);
      widget.onChanged();
    }
  }

  Future<void> _assign(Json s) async {
    final api = context.api;
    final r = await showFormSheet<Json>(
      context,
      title: 'Assign ${s['name']}',
      subtitle: 'Applies from the chosen date. Earlier days keep their shift.',
      fields: const [
        FieldSpec('employeeId', 'Employee', kind: FieldKind.asyncSelect, loadOptions: Lookups.employees, required: true),
        FieldSpec('from', 'From', kind: FieldKind.date, required: true),
        FieldSpec('to', 'Until (optional)', kind: FieldKind.date),
        FieldSpec('setDefault', 'Make it their default shift', kind: FieldKind.toggle),
      ],
      initial: const {'setDefault': true},
      successMessage: 'Shift assigned.',
      submit: (v, key) async => jsonMap(await api.post('/shifts/assign', idempotencyKey: key, body: {
        'shiftId': s['id'],
        'employeeIds': [v['employeeId']],
        'from': v['from'],
        if (v['to'] != null) 'to': v['to'],
        'setDefault': v['setDefault'] == true,
      })),
    );
    if (r != null) widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return InfoCard(
      title: 'Shift setup',
      trailing: NButton(label: 'New shift', icon: Icons.add_rounded, compact: true, onPressed: () => _edit()),
      child: AsyncView<List<Json>>(
        reloadKey: _rev,
        load: () async => jsonList(await context.api.get('/shifts')),
        builder: (context, items, reload) => items.isEmpty
            ? const NEmptyState(title: 'No shifts yet', message: 'Create the first shift, then assign people to it.', compact: true, icon: Icons.view_timeline_rounded)
            : Column(children: [
                for (final s in items.where((s) => s['status'] != 'archived'))
                  NListRow(
                    leading: Container(width: 12, height: 12, decoration: BoxDecoration(color: s['color'] == null ? t.accent : _hex('${s['color']}'), shape: BoxShape.circle)),
                    title: '${s['name']} · ${s['startTime']}–${s['endTime']}',
                    subtitle: '${[for (final d in (s['workingDays'] as List? ?? const [])) _weekdays[(d as num).toInt()]].join(', ')} · break ${s['breakMinutes']} min · grace ${s['graceMinutes']} min',
                    trailing: Wrap(spacing: 4, children: [
                      IconButton(tooltip: 'Assign people', icon: const Icon(Icons.person_add_alt_rounded, size: 18), onPressed: () => _assign(s)),
                      IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_rounded, size: 18), onPressed: () => _edit(s)),
                      IconButton(
                        tooltip: 'Archive',
                        icon: const Icon(Icons.archive_outlined, size: 18),
                        onPressed: () async {
                          final c = await showNConfirm(context, title: 'Archive ${s['name']}?', message: 'People on this shift keep it until reassigned; it can no longer be assigned.', confirmLabel: 'Archive', destructive: true);
                          if (!c.confirmed || !context.mounted) return;
                          try {
                            await context.api.delete('/shifts/${s['id']}');
                            reload();
                          } catch (e) {
                            if (context.mounted) showError(context, e);
                          }
                        },
                      ),
                    ]),
                  ),
              ]),
      ),
    );
  }
}
