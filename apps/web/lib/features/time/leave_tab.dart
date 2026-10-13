import 'package:flutter/material.dart';
import 'package:n_ui/n_ui.dart';

import '../../app/services.dart';
import '../../data/api.dart';
import '../../data/lookups.dart';
import '../../platform/bridge.dart';
import '../../widgets/async_view.dart';
import '../../widgets/format.dart';
import '../../widgets/section.dart';
import '../../widgets/status.dart';

/// Leave: balances, apply (with live preview of units and balance), my requests and the team calendar.
class LeaveTab extends StatefulWidget {
  const LeaveTab({super.key});

  @override
  State<LeaveTab> createState() => _LeaveTabState();
}

class _LeaveTabState extends State<LeaveTab> {
  int _rev = 0;
  String _status = '';

  Future<void> _apply() async {
    final r = await showNSheet<bool>(context, title: 'Apply for leave', builder: (ctx) => ApiScope(api: context.api, child: const _ApplySheet()));
    if (r == true && mounted) setState(() => _rev++);
  }

  Future<void> _cancel(Json r) async {
    final c = await showNConfirm(context, title: 'Cancel this request?', message: 'Pending days go back to your balance. Approved leave that already started cannot be cancelled here.', confirmLabel: 'Cancel request', destructive: true);
    if (!c.confirmed || !mounted) return;
    try {
      await context.api.post('/leave/requests/${r['id']}/cancel');
      if (mounted) {
        NToast.of(context).show('Request cancelled.');
        setState(() => _rev++);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final me = context.me;
    final team = me.can('leave', 'view', 'team');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (me.employeeId != null)
        InfoCard(
          title: 'My balances ${DateTime.now().year}',
          trailing: me.can('leave', 'create') ? NButton(label: 'Apply', icon: Icons.add_rounded, compact: true, variant: NButtonVariant.accent, onPressed: _apply) : null,
          child: AsyncView<List<Json>>(
            reloadKey: _rev,
            load: () async => jsonList(await context.api.get('/leave/balances')),
            builder: (context, items, _) => items.isEmpty
                ? const NEmptyState(title: 'No leave policy applies to you yet', message: 'HR sets up leave policies in Admin → Leave.', compact: true, icon: Icons.beach_access_rounded)
                : Wrap(spacing: 12, runSpacing: 12, children: [
                    for (final b in items)
                      SizedBox(
                        width: 200,
                        child: NGlassCard(
                          blur: false,
                          color: t.pillTrack,
                          padding: const EdgeInsets.all(14),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${b['name']}', style: t.text.body(weight: FontWeight.w600)),
                            const SizedBox(height: 6),
                            Text(Fmt.number(b['available']), style: t.text.bigNumber(34)),
                            Text('available', style: t.text.caption()),
                            const SizedBox(height: 8),
                            Text('Accrued ${Fmt.number(b['accrued'])} · used ${Fmt.number(b['used'])} · pending ${Fmt.number(b['pending'])}${(b['carriedForward'] as num? ?? 0) > 0 ? ' · carried ${Fmt.number(b['carriedForward'])}' : ''}', style: t.text.caption()),
                            if (b['paid'] == false) Text('Unpaid', style: t.text.caption(color: t.amber)),
                          ]),
                        ),
                      ),
                  ]),
          ),
        ),
      const SizedBox(height: 14),
      InfoCard(
        title: team ? 'Leave requests' : 'My requests',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Toolbar(children: [
            NFilterChips<String>(
              value: _status,
              onChanged: (v) => setState(() => _status = v),
              options: const [NOption('', 'All'), NOption('pending', 'Pending'), NOption('approved', 'Approved'), NOption('rejected', 'Rejected'), NOption('cancelled', 'Cancelled')],
            ),
          ]),
          PagedList(
            path: '/leave/requests',
            query: {'status': _status, if (!team) 'mine': true},
            reloadKey: '$_status$_rev',
            emptyTitle: 'No leave requests',
            emptyIcon: Icons.beach_access_rounded,
            itemBuilder: (_, __, ___) => const SizedBox.shrink(),
            wrap: (context, items, reload) => NDataTable(
              columns: [
                if (team) const NColumn('Person', flex: 3),
                const NColumn('Type'),
                const NColumn('Dates', flex: 3),
                const NColumn('Days', numeric: true),
                const NColumn('Reason', flex: 3, hideOnTablet: true),
                const NColumn('Status'),
                const NColumn('', flex: 1),
              ],
              rows: [
                for (final r in items)
                  [
                    if (team) Text('${r['employeeName'] ?? ''}'),
                    Text('${jsonMap(r['leaveType'])['code'] ?? ''}'),
                    Text(r['startDate'] == r['endDate'] ? '${Fmt.date(r['startDate'])}${r['partialDay'] != 'none' ? ' (${Fmt.label(r['partialDay'])})' : ''}' : '${Fmt.shortDate(r['startDate'])} – ${Fmt.date(r['endDate'])}'),
                    Text(Fmt.number(r['units'])),
                    Text('${r['reason'] ?? ''}${r['decisionComment'] != null ? '\n↳ ${r['decisionComment']}' : ''}', maxLines: 3, overflow: TextOverflow.ellipsis),
                    StatusChip('${r['status']}'),
                    (r['employeeId'] == me.employeeId && (r['status'] == 'pending' || r['status'] == 'clarification' || (r['status'] == 'approved' && '${r['startDate']}'.compareTo(Fmt.day(DateTime.now())) > 0)))
                        ? IconButton(tooltip: 'Cancel request', icon: Icon(Icons.close_rounded, size: 18, color: t.muted), onPressed: () => _cancel(r))
                        : const SizedBox.shrink(),
                  ],
              ],
            ),
          ),
        ]),
      ),
      if (team) ...[const SizedBox(height: 14), _TeamCalendar(rev: _rev)],
    ]);
  }
}

class _ApplySheet extends StatefulWidget {
  const _ApplySheet();

  @override
  State<_ApplySheet> createState() => _ApplySheetState();
}

class _ApplySheetState extends State<_ApplySheet> {
  String? _type;
  DateTime? _start;
  DateTime? _end;
  String _partial = 'none';
  final _reason = TextEditingController();
  String? _fileId;
  String? _fileName;
  Json? _preview;
  bool _busy = false;
  bool _uploading = false;
  String? _error;
  final String _key = newIdempotencyKey();
  int _previewSeq = 0;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _refreshPreview() async {
    if (_type == null || _start == null) return;
    final end = _partial == 'none' ? (_end ?? _start!) : _start!;
    final seq = ++_previewSeq;
    try {
      final p = jsonMap(await ApiScope.of(context).post('/leave/requests/preview', body: {'leaveTypeId': _type, 'startDate': Fmt.day(_start!), 'endDate': Fmt.day(end), 'partialDay': _partial}));
      if (mounted && seq == _previewSeq) setState(() => _preview = p);
    } catch (e) {
      if (mounted && seq == _previewSeq) setState(() => _preview = {'ok': false, 'message': describeError(e)});
    }
  }

  Future<void> _attach() async {
    final f = await bridge.pickFile(accept: 'application/pdf,image/*');
    if (f == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      final rec = await ApiScope.of(context).upload(f, purpose: 'document');
      setState(() {
        _fileId = rec['id'] as String?;
        _fileName = f.name;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _submit() async {
    if (_type == null || _start == null) {
      setState(() => _error = 'Choose a leave type and dates.');
      return;
    }
    final end = _partial == 'none' ? (_end ?? _start!) : _start!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ApiScope.of(context).post('/leave/requests', idempotencyKey: _key, body: {
        'leaveTypeId': _type,
        'startDate': Fmt.day(_start!),
        'endDate': Fmt.day(end),
        'partialDay': _partial,
        if (_reason.text.trim().isNotEmpty) 'reason': _reason.text.trim(),
        if (_fileId != null) 'attachmentFileId': _fileId,
      });
      if (!mounted) return;
      NToast.of(context).show('Leave request sent for approval.');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = describeError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final p = _preview;
    return NSheetBody(
      actions: [
        NButton(label: 'Cancel', variant: NButtonVariant.secondary, compact: true, onPressed: () => Navigator.of(context).pop(false)),
        NButton(label: 'Send for approval', variant: NButtonVariant.accent, compact: true, busy: _busy, onPressed: _uploading ? null : _submit),
      ],
      children: [
        if (_error != null) NBanner(message: _error!, tone: NBannerTone.danger),
        AsyncView<List<NOption<String>>>(
          load: () => Lookups.leaveTypes(ApiScope.of(context)),
          compact: true,
          skeletonRows: 1,
          builder: (context, opts, _) => NSelect<String>(
            label: 'Leave type',
            required: true,
            options: opts,
            value: _type,
            onChanged: (v) {
              setState(() => _type = v);
              _refreshPreview();
            },
          ),
        ),
        NSelect<String>(
          label: 'Duration',
          value: _partial,
          options: const [NOption('none', 'Full day(s)'), NOption('first_half', 'First half (one day)'), NOption('second_half', 'Second half (one day)')],
          onChanged: (v) {
            setState(() => _partial = v ?? 'none');
            _refreshPreview();
          },
        ),
        NDateField(
          label: _partial == 'none' ? 'From' : 'Date',
          required: true,
          value: _start,
          firstDate: DateTime.now().subtract(const Duration(days: 60)),
          onChanged: (d) {
            setState(() {
              _start = d;
              if (_end != null && d != null && _end!.isBefore(d)) _end = d;
            });
            _refreshPreview();
          },
        ),
        if (_partial == 'none')
          NDateField(
            label: 'To',
            value: _end ?? _start,
            firstDate: _start ?? DateTime.now().subtract(const Duration(days: 60)),
            onChanged: (d) {
              setState(() => _end = d);
              _refreshPreview();
            },
          ),
        if (p != null)
          NBanner(
            tone: p['ok'] == true ? NBannerTone.success : NBannerTone.warning,
            message: p['ok'] == true
                ? '${Fmt.number(p['units'])} working day(s). ${Fmt.number(p['available'])} available now, ${Fmt.number(p['after'])} after this request.'
                : '${p['message'] ?? 'Not possible with these dates.'}',
          ),
        NTextField(label: 'Reason', controller: _reason, maxLines: 3, maxLength: 1000),
        Row(children: [
          NButton(label: _fileId == null ? 'Attach document' : 'Replace document', icon: Icons.attach_file_rounded, variant: NButtonVariant.secondary, compact: true, busy: _uploading, onPressed: _attach),
          const SizedBox(width: 10),
          Expanded(child: Text(_fileName ?? 'Optional (e.g. a medical certificate)', overflow: TextOverflow.ellipsis, style: t.text.caption())),
        ]),
      ],
    );
  }
}

class _TeamCalendar extends StatefulWidget {
  const _TeamCalendar({required this.rev});
  final int rev;

  @override
  State<_TeamCalendar> createState() => _TeamCalendarState();
}

class _TeamCalendarState extends State<_TeamCalendar> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime? _selected;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final from = DateTime(_month.year, _month.month, 1);
    final to = DateTime(_month.year, _month.month + 1, 0);
    return InfoCard(
      title: 'Team leave calendar',
      subtitle: 'Approved and pending leave in your scope.',
      child: AsyncView<List<Json>>(
        reloadKey: '${Fmt.day(from)}-${widget.rev}',
        load: () async => jsonList(await context.api.get('/leave/calendar', query: {'from': Fmt.day(from), 'to': Fmt.day(to)})),
        builder: (context, items, _) {
          final marks = <String, List<NCalendarMark>>{};
          for (final r in items) {
            var d = DateTime.parse('${r['startDate']}T00:00:00');
            final end = DateTime.parse('${r['endDate']}T00:00:00');
            while (!d.isAfter(end)) {
              marks.putIfAbsent(Fmt.day(d), () => []).add(NCalendarMark(color: r['status'] == 'approved' ? t.accent : t.amber, label: '${r['employeeName']} (${jsonMap(r['leaveType'])['code']})'));
              d = d.add(const Duration(days: 1));
            }
          }
          final sel = _selected == null ? null : Fmt.day(_selected!);
          final onDay = sel == null ? <Json>[] : items.where((r) => '${r['startDate']}'.compareTo(sel) <= 0 && '${r['endDate']}'.compareTo(sel) >= 0).toList();
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            NMonthCalendar(month: _month, marks: marks, selectedDay: _selected, weekStart: context.me.weekStart == 0 ? 7 : context.me.weekStart, onMonthChanged: (m) => setState(() => _month = m), onDayTap: (d) => setState(() => _selected = d)),
            if (sel != null) ...[
              const SizedBox(height: 8),
              Text('${Fmt.date(sel)}: ${onDay.isEmpty ? 'nobody on leave' : '${onDay.length} on leave'}', style: t.text.body(weight: FontWeight.w600)),
              for (final r in onDay) NListRow(dense: true, title: '${r['employeeName']}', subtitle: '${jsonMap(r['leaveType'])['name']}', trailing: StatusChip('${r['status']}')),
            ],
          ]);
        },
      ),
    );
  }
}
