import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:n_ui/n_ui.dart';

import '../../app/links.dart';
import '../../app/services.dart';
import '../../data/api.dart';
import '../../shell/app_shell.dart';
import '../../widgets/async_view.dart';
import '../../widgets/format.dart';
import '../../widgets/section.dart';
import '../../widgets/status.dart';
import '../time/attendance_card.dart';

/// Home: "what needs me now?" for whoever is signed in. Sections appear according to the caller's
/// permissions (personal, team, organization, system). Every number comes from `GET /v1/dashboard`.
class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final _view = GlobalKey<AsyncViewState<Json>>();

  String _greeting() {
    final h = DateTime.now().hour;
    return h < 12 ? 'Good morning,' : (h < 17 ? 'Good afternoon,' : 'Good evening,');
  }

  @override
  Widget build(BuildContext context) {
    final me = context.me;
    return PageFrame(
      child: AsyncView<Json>(
        key: _view,
        load: () async => jsonMap(await context.api.get('/dashboard')),
        skeletonRows: 8,
        builder: (context, d, reload) {
          final mine = d['me'] == null ? null : jsonMap(d['me']);
          final team = d['team'] == null ? null : jsonMap(d['team']);
          final org = d['organization'] == null ? null : jsonMap(d['organization']);
          final sys = d['system'] == null ? null : jsonMap(d['system']);
          final attention = jsonList(d['attention']);
          final balances = mine == null ? <Json>[] : jsonList(mine['leaveBalances']);
          final pending = mine == null ? const <String, dynamic>{} : jsonMap(mine['pendingRequests']);
          final pendingTotal = pending.values.fold<num>(0, (a, b) => a + (b is num ? b : 0));
          final showAttendance = me.feature('attendance') && (me.can('attendance', 'create') || me.employeeId != null || me.role == 'super_admin');
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            NEntrance(
              order: 0,
              child: NHeroRow(
                greeting: NGreeting(lead: _greeting(), bold: me.name.split(' ').first, trail: me.orgName.isEmpty ? '' : ' · ${me.orgName}'),
                meters: [
                  for (final b in balances.take(3))
                    NMeter(
                      label: '${b['code']}',
                      valueText: '${Fmt.number(b['available'])} left',
                      fraction: ((b['total'] as num? ?? 0) == 0) ? 0 : ((b['available'] as num? ?? 0) / (b['total'] as num)).clamp(0, 1).toDouble(),
                    ),
                ],
                kpis: [
                  NKpi(label: 'Needs attention', value: attention.length),
                  if (mine != null) NKpi(label: 'My open requests', value: pendingTotal),
                  if (org != null) NKpi(label: 'Active people', value: jsonMap(org['headcount'])['active'] as num?),
                  if (team != null && org == null) NKpi(label: 'Team checked in', value: jsonMap(team['today'])['checkedIn'] as num?),
                ],
              ),
            ),
            const SizedBox(height: 18),
            if (showAttendance) ...[
              NEntrance(
                order: 1,
                child: AttendanceTodayCard(onChanged: () => _view.currentState?.reload()),
              ),
              const SizedBox(height: 16),
            ],
            if (attention.isNotEmpty) ...[
              NEntrance(order: 2, child: _AttentionCard(items: attention, onChanged: () => _view.currentState?.reload())),
              const SizedBox(height: 14),
            ],
            if (me.can('organization', 'configure', 'organization')) ...[const NEntrance(order: 3, child: _SetupChecklist()), const SizedBox(height: 14)],
            if (mine != null) NEntrance(order: 4, child: _Personal(data: mine, onChanged: () => _view.currentState?.reload())),
            if (team != null) ...[const SizedBox(height: 14), NEntrance(order: 5, child: _Team(data: team))],
            if (org != null) ...[const SizedBox(height: 14), NEntrance(order: 6, child: _Organization(data: org))],
            if (sys != null) ...[const SizedBox(height: 14), NEntrance(order: 7, child: _System(data: sys))],
            if (!showAttendance && mine == null && team == null && org == null && sys == null)
              const NEmptyState(title: "You're all set", message: 'Nothing on your dashboard yet. Your administrator can link your account to an employee record.', icon: Icons.check_circle_outline_rounded),
            const SizedBox(height: 8),
            Text('Updated ${Fmt.time(d['generatedAt'])} · ${d['timezone']}', textAlign: TextAlign.end, style: NTokens.of(context).text.caption()),
          ]);
        },
      ),
    );
  }
}

class _AttentionCard extends StatelessWidget {
  const _AttentionCard({required this.items, required this.onChanged});
  final List<Json> items;
  final VoidCallback onChanged;

  Future<void> _snooze(BuildContext context, Json item) async {
    final api = context.api;
    final toast = NToast.of(context);
    final ok = await showFormSheetLite(context, item: item, api: api);
    if (!ok) return;
    toast.show('Snoozed. It comes back when the time is up or the count changes.');
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return InfoCard(
      title: 'Needs attention',
      subtitle: 'From live records. Nothing here was changed automatically.',
      child: Column(children: [
        for (final i in items)
          NListRow(
            leading: Icon(
              switch (i['severity']) {
                'critical' => Icons.error_rounded,
                'warning' => Icons.warning_amber_rounded,
                _ => Icons.info_outline_rounded,
              },
              color: switch (i['severity']) {
                'critical' => t.red,
                'warning' => t.amber,
                _ => t.accent,
              },
            ),
            title: '${i['title']}',
            subtitle: i['detail'] as String?,
            onTap: () => context.go(resolveLink(i['link'] as String?)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              NCountBadge(count: (i['count'] as num?)?.toInt() ?? 0),
              if (i['snoozable'] == true)
                IconButton(tooltip: 'Snooze', icon: Icon(Icons.snooze_rounded, size: 18, color: t.muted), onPressed: () => _snooze(context, i)),
            ]),
          ),
      ]),
    );
  }
}

/// Snooze sheet: hours + required reason (audited on the server).
Future<bool> showFormSheetLite(BuildContext context, {required Json item, required ApiClient api}) async {
  var hours = 24;
  var done = false;
  final reason = TextEditingController();
  await showNSheet<void>(
    context,
    title: 'Snooze “${item['title']}”',
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => NSheetBody(
        actions: [
          NButton(label: 'Cancel', variant: NButtonVariant.secondary, compact: true, onPressed: () => Navigator.of(ctx).pop()),
          NButton(
            label: 'Snooze',
            compact: true,
            variant: NButtonVariant.accent,
            onPressed: reason.text.trim().length < 3
                ? null
                : () async {
                    try {
                      await api.post('/dashboard/attention/${item['key']}/snooze', body: {'hours': hours, 'reason': reason.text.trim()});
                      done = true;
                      if (ctx.mounted) Navigator.of(ctx).pop();
                    } catch (e) {
                      if (ctx.mounted) showError(ctx, e);
                    }
                  },
          ),
        ],
        children: [
          NSelect<int>(
            label: 'For',
            value: hours,
            options: const [NOption(4, '4 hours'), NOption(24, '1 day'), NOption(72, '3 days'), NOption(168, '1 week')],
            onChanged: (v) => setState(() => hours = v ?? 24),
          ),
          NTextField(label: 'Reason', controller: reason, required: true, maxLines: 3, helper: 'Recorded in the audit log.', onChanged: (_) => setState(() {})),
        ],
      ),
    ),
  );
  return done;
}

class _SetupChecklist extends StatefulWidget {
  const _SetupChecklist();

  @override
  State<_SetupChecklist> createState() => _SetupChecklistState();
}

class _SetupChecklistState extends State<_SetupChecklist> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return AsyncView<Json>(
      load: () async => jsonMap(await context.api.get('/dashboard/setup-checklist')),
      compact: true,
      skeletonRows: 2,
      builder: (context, c, _) {
        final steps = jsonList(c['steps']);
        final remaining = (c['requiredRemaining'] as num?)?.toInt() ?? 0;
        final total = (c['total'] as num?)?.toInt() ?? 0;
        final done = (c['done'] as num?)?.toInt() ?? 0;
        if (remaining == 0 && done == total) return const SizedBox.shrink();
        final pending = steps.where((s) => s['done'] != true).toList();
        final fraction = total == 0 ? 0.0 : (done / total).clamp(0.0, 1.0);

        final isMobile = NBreakpoint.of(context).isMobile;

        return InfoCard(
          title: 'Setup checklist',
          subtitle: '$done of $total complete${remaining > 0 ? ' · $remaining required left' : ' · Optional steps'}',
          trailing: isMobile
              ? NButton(
                  label: _expanded ? 'Hide' : 'View',
                  compact: true,
                  variant: NButtonVariant.secondary,
                  icon: _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  onPressed: () => setState(() => _expanded = !_expanded),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 90,
                      child: NProgressBar(fraction: fraction, semanticLabel: 'Setup progress'),
                    ),
                    const SizedBox(width: 8),
                    NButton(
                      label: _expanded ? 'Hide' : 'View ($done/$total)',
                      compact: true,
                      variant: NButtonVariant.secondary,
                      icon: _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                      onPressed: () => setState(() => _expanded = !_expanded),
                    ),
                  ],
                ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isMobile) ...[
                const SizedBox(height: 2),
                ClipRRect(
                  borderRadius: BorderRadius.circular(NTokens.radiusPill),
                  child: NProgressBar(fraction: fraction, semanticLabel: 'Setup progress'),
                ),
                const SizedBox(height: 10),
              ],
              if (!_expanded) ...[
                if (pending.isNotEmpty)
                  InkWell(
                    borderRadius: BorderRadius.circular(t.radiusTile),
                    onTap: () => context.go(resolveLink(pending.first['link'] as String?)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                      child: Row(
                        children: [
                          Icon(
                            pending.first['required'] == true ? Icons.radio_button_unchecked_rounded : Icons.circle_outlined,
                            size: 16,
                            color: pending.first['required'] == true ? t.amber : t.muted,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Next: ${pending.first['title']} — ${pending.first['description']}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: t.text.caption(weight: FontWeight.w500).copyWith(color: t.ink),
                            ),
                          ),
                          Icon(Icons.chevron_right_rounded, size: 16, color: t.muted),
                        ],
                      ),
                    ),
                  ),
              ] else ...[
                for (final s in pending)
                  NListRow(
                    dense: true,
                    leading: Icon(
                      s['required'] == true ? Icons.radio_button_unchecked_rounded : Icons.circle_outlined,
                      size: 18,
                      color: s['required'] == true ? t.amber : t.muted,
                    ),
                    title: '${s['title']}${s['required'] == true ? '' : ' (optional)'}',
                    subtitle: '${s['description']} · ${s['status']}',
                    onTap: () => context.go(resolveLink(s['link'] as String?)),
                    trailing: Icon(Icons.chevron_right_rounded, color: t.muted),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _Personal extends StatelessWidget {
  const _Personal({required this.data, required this.onChanged});
  final Json data;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final me = context.me;
    final balances = jsonList(data['leaveBalances']);
    final tasks = jsonMap(data['tasks']);
    final due = jsonList(tasks['due']);
    final holidays = jsonList(data['upcomingHolidays']);
    final events = jsonList(data['upcomingEvents']);
    final news = jsonList(data['announcements']);
    final payslip = data['latestPayslip'] == null ? null : jsonMap(data['latestPayslip']);
    final pending = jsonMap(data['pendingRequests']);

    Widget emptyTile(IconData icon, String title, String subtitle, {Color? iconColor}) => Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: (iconColor ?? t.muted).withValues(alpha: t.isDark ? 0.16 : 0.08),
                borderRadius: BorderRadius.circular(t.radiusTile),
              ),
              child: Icon(icon, color: iconColor ?? t.muted, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: t.text.body(weight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: t.text.caption(color: t.muted)),
                ],
              ),
            ),
          ],
        );

    return CardGrid(children: [
      if (me.feature('leave'))
        InfoCard(
          title: 'Leave balance',
          subtitle: '${pending['leave'] ?? 0} request(s) waiting',
          trailing: TextButton(onPressed: () => context.go('/time/leave'), child: Text('Apply', style: t.text.caption(color: t.ink, weight: FontWeight.w600))),
          child: balances.isEmpty
              ? emptyTile(Icons.beach_access_rounded, 'No balances yet for this year', 'Policies will be assigned by HR')
              : Column(children: [
                  for (final b in balances)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(child: Text('${b['name']}', style: t.text.body())),
                          Text('${Fmt.number(b['available'])} of ${Fmt.number(b['total'])}', style: t.text.caption()),
                        ]),
                        const SizedBox(height: 4),
                        NProgressBar(fraction: (b['total'] as num? ?? 0) == 0 ? 0 : (b['available'] as num) / (b['total'] as num), semanticLabel: '${b['name']} available'),
                      ]),
                    ),
                ]),
        ),
      if (me.feature('tasks'))
        InfoCard(
          title: 'Due now',
          subtitle: '${(jsonMap(tasks['byStatus']).values.fold<num>(0, (a, b) => a + (b as num)))} open tasks',
          trailing: TextButton(onPressed: () => context.go('/work'), child: Text('Open board', style: t.text.caption(color: t.ink, weight: FontWeight.w600))),
          child: due.isEmpty
              ? emptyTile(Icons.task_alt_rounded, 'Nothing due today or overdue', 'You\'re all caught up with your tasks', iconColor: t.teal)
              : Column(children: [
                  for (final task in due)
                    NListRow(
                      dense: true,
                      title: '${task['title']}',
                      subtitle: 'Due ${Fmt.date(task['dueDate'])}',
                      trailing: StatusChip('${task['priority']}'),
                      onTap: () => context.go('/work?open=${task['id']}'),
                    ),
                ]),
        ),
      InfoCard(
        title: 'Coming up',
        child: (holidays.isEmpty && events.isEmpty && news.isEmpty)
            ? emptyTile(Icons.event_available_rounded, 'No upcoming holidays or events', 'Announcements and events appear here')
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final h in holidays) NListRow(dense: true, leading: Icon(Icons.beach_access_rounded, size: 18, color: t.teal), title: '${h['name']}', subtitle: '${Fmt.weekday(h['date'])}, ${Fmt.date(h['date'])}${h['optional'] == true ? ' · optional' : ''}'),
                for (final e in events) NListRow(dense: true, leading: Icon(Icons.event_rounded, size: 18, color: t.accent), title: '${e['title']}', subtitle: Fmt.dateTime(e['startAt'])),
                for (final a in news) NListRow(dense: true, leading: Icon(Icons.campaign_rounded, size: 18, color: t.amber), title: '${a['title']}', subtitle: Fmt.relative(a['publishedAt']), onTap: () => context.go('/people/announcements')),
              ]),
      ),
      if (payslip != null)
        InfoCard(
          title: 'Latest payslip',
          subtitle: '${payslip['period']}',
          onTap: () => context.go('/money/payslips'),
          child: Row(children: [
            Expanded(child: Text(Fmt.money(payslip['net'], me.currency), style: t.text.bigNumber(30))),
            if (payslip['viewedAt'] == null) const StatusChip('new', label: 'New'),
          ]),
        ),
    ]);
  }
}

class _Team extends StatelessWidget {
  const _Team({required this.data});
  final Json data;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final today = jsonMap(data['today']);
    final trend = jsonList(data['trend']);
    final tasks = jsonMap(data['tasksByStatus']);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const NSectionHeader(title: 'Your', boldWord: 'team'),
      CardGrid(children: [
        InfoCard(
          title: 'Today',
          subtitle: '${data['headcount']} people',
          onTap: () => context.go('/time/team'),
          child: Wrap(spacing: 24, runSpacing: 12, children: [
            NKpi(label: 'Checked in', value: today['checkedIn'] as num?, size: 34),
            NKpi(label: 'Late', value: today['late'] as num?, size: 34),
            NKpi(label: 'On leave', value: today['onLeave'] as num?, size: 34),
            NKpi(label: 'Not yet', value: today['notCheckedIn'] as num?, size: 34),
          ]),
        ),
        InfoCard(
          title: 'Attendance, last 14 days',
          child: trend.isEmpty
              ? Text('No attendance history yet.', style: t.text.body(color: t.muted))
              : NBars(height: 100, semanticLabel: 'People checked in per day', data: [for (final r in trend) NDatum(Fmt.shortDate(r['day']).split(' ').first, r['present'] as num)], highlightLast: true),
        ),
        InfoCard(
          title: 'Team tasks',
          subtitle: '${data['approvalsWaiting']} approvals waiting for you',
          child: tasks.isEmpty
              ? Text('No team tasks.', style: t.text.body(color: t.muted))
              : NDonut(size: 110, semanticLabel: 'Tasks by status', centerLabel: 'tasks', data: [for (final e in tasks.entries) NDatum(Fmt.label(e.key), e.value as num)]),
        ),
      ]),
    ]);
  }
}

class _Organization extends StatelessWidget {
  const _Organization({required this.data});
  final Json data;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final me = context.me;
    final head = jsonMap(data['headcount']);
    final today = jsonMap(data['today']);
    final trend = jsonList(data['trend']);
    final depts = jsonList(data['byDepartment']);
    final exp = data['expensesThisMonth'] == null ? null : jsonMap(data['expensesThisMonth']);
    final funnel = data['leadFunnel'] == null ? null : jsonMap(data['leadFunnel']);
    final payroll = data['latestPayroll'] == null ? null : jsonMap(data['latestPayroll']);
    const stages = ['new', 'contacted', 'interested', 'qualified', 'meeting_scheduled', 'proposal', 'won', 'lost', 'unreachable'];
    final totalLeads = funnel == null ? 0 : funnel.values.fold<num>(0, (a, b) => a + (b is num ? b : 0));

    Widget statusTile(IconData icon, String title, String subtitle, {Color? iconColor}) => Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: (iconColor ?? t.muted).withValues(alpha: t.isDark ? 0.16 : 0.08),
                borderRadius: BorderRadius.circular(t.radiusTile),
              ),
              child: Icon(icon, color: iconColor ?? t.muted, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: t.text.body(weight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: t.text.caption(color: t.muted)),
                ],
              ),
            ),
          ],
        );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const NSectionHeader(title: 'Across the', boldWord: 'organization'),
      CardGrid(children: [
        InfoCard(
          title: 'People',
          onTap: () => context.go('/people'),
          child: Wrap(spacing: 24, runSpacing: 12, children: [
            NKpi(label: 'Active', value: head['active'] as num?, size: 34),
            NKpi(label: 'Joined this month', value: head['joinersThisMonth'] as num?, size: 34),
            NKpi(label: 'Left this month', value: head['exitsThisMonth'] as num?, size: 34),
          ]),
        ),
        InfoCard(
          title: 'Attendance today',
          onTap: () => context.go('/time/team'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: 24, runSpacing: 12, children: [
              NKpi(label: 'Checked in', value: today['checkedIn'] as num?, size: 34),
              NKpi(label: 'Late', value: today['late'] as num?, size: 34),
              NKpi(label: 'On leave', value: today['onLeave'] as num?, size: 34),
            ]),
            const SizedBox(height: 10),
            NSparkline(values: [for (final r in trend) r['present'] as num], semanticLabel: 'Checked in per day, last 14 days'),
          ]),
        ),
        InfoCard(
          title: 'Requests',
          onTap: () => context.go('/approvals'),
          child: Wrap(spacing: 24, runSpacing: 12, children: [
            NKpi(label: 'Approvals pending', value: data['approvalsPending'] as num?, size: 34),
            NKpi(label: 'Leave pending', value: data['leavePending'] as num?, size: 34),
          ]),
        ),
        InfoCard(
          title: 'By department',
          child: depts.isEmpty
              ? statusTile(Icons.apartment_rounded, 'No departments yet', 'Configure departments in Admin')
              : (depts.length == 1
                  ? statusTile(
                      Icons.apartment_rounded,
                      '${depts.first['name']}',
                      '${depts.first['count']} active ${depts.first['count'] == 1 ? 'member' : 'members'}',
                      iconColor: t.accent,
                    )
                  : NBars(
                      height: 100,
                      semanticLabel: 'Active people by department',
                      data: [for (final d in depts.take(6)) NDatum('${d['name']}', d['count'] as num)],
                    )),
        ),
        if (exp != null)
          InfoCard(
            title: 'Expenses this month',
            onTap: () => context.go('/money'),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              NInfoRow(label: 'Submitted', value: '${Fmt.money(jsonMap(exp['submitted'])['amount'] ?? 0, me.currency)} · ${jsonMap(exp['submitted'])['count'] ?? 0}'),
              NInfoRow(label: 'Approved', value: '${Fmt.money(jsonMap(exp['approved'])['amount'] ?? 0, me.currency)} · ${jsonMap(exp['approved'])['count'] ?? 0}'),
            ]),
          ),
        if (funnel != null)
          InfoCard(
            title: 'Lead pipeline',
            onTap: () => context.go('/work/leads'),
            child: totalLeads == 0
                ? statusTile(Icons.filter_alt_outlined, 'No active leads in pipeline', 'Track and nurture opportunities in Work')
                : NBars(
                    height: 100,
                    semanticLabel: 'Leads by stage',
                    data: [for (final s in stages) if (funnel.containsKey(s) && (funnel[s] as num) > 0) NDatum(Fmt.label(s), funnel[s] as num)],
                  ),
          ),
        if (me.can('payroll', 'view', 'organization'))
          InfoCard(
            title: 'Payroll',
            onTap: () => context.go('/money/payroll'),
            child: payroll == null
                ? statusTile(Icons.payments_outlined, 'No payroll run yet', 'Process or review payroll runs in Money')
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [Expanded(child: Text('${payroll['label'] ?? payroll['periodStart']}', style: t.text.body(weight: FontWeight.w600))), StatusChip('${payroll['status']}')]),
                    const SizedBox(height: 8),
                    NInfoRow(label: 'Net pay', value: Fmt.money(jsonMap(payroll['totals'])['net'], me.currency)),
                    NInfoRow(label: 'Anomalies', value: '${payroll['anomalies'] ?? 0}'),
                  ]),
          ),
      ]),
    ]);
  }
}

class _System extends StatelessWidget {
  const _System({required this.data});
  final Json data;

  NHealth _h(Object? s) => switch (s) {
        'healthy' => NHealth.healthy,
        'degraded' => NHealth.degraded,
        'unavailable' => NHealth.unavailable,
        _ => NHealth.unknown,
      };

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final health = jsonMap(data['health']);
    final comps = jsonList(health['components']);
    final backups = jsonMap(data['backups']);
    final verified = backups['lastVerified'] == null ? null : jsonMap(backups['lastVerified']);
    final last = backups['last'] == null ? null : jsonMap(backups['last']);
    final storage = data['storage'] == null ? null : jsonMap(data['storage']);
    final logins = jsonMap(data['logins24h']);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const NSectionHeader(title: 'Control', boldWord: 'center'),
      CardGrid(children: [
        InfoCard(
          title: 'System health',
          trailing: NStatusChip.health(_h(health['state'])),
          onTap: () => context.go('/system'),
          child: Column(children: [
            for (final c in comps)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Expanded(child: Text(Fmt.label(c['component']), style: t.text.body())),
                  NStatusChip.health(_h(c['state'])),
                ]),
              ),
          ]),
        ),
        InfoCard(
          title: 'Backups',
          onTap: () => context.go('/system/backups'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            NInfoRow(label: 'Last verified', value: verified == null ? 'None yet' : Fmt.relative(verified['verifiedAt'])),
            NInfoRow(label: 'Restore tested', value: verified?['restoreTestedAt'] == null ? 'Not yet' : Fmt.relative(verified!['restoreTestedAt'])),
            if (last != null) NInfoRow(label: 'Latest run', value: '', valueWidget: Row(children: [StatusChip('${last['status']}'), const SizedBox(width: 6), Text(Fmt.relative(last['startedAt']), style: t.text.caption())])),
          ]),
        ),
        InfoCard(
          title: 'Sign-ins, last 24 hours',
          onTap: () => context.go('/system/security'),
          child: Wrap(spacing: 24, runSpacing: 12, children: [
            NKpi(label: 'Successful', value: (logins['success'] as num?) ?? 0, size: 34),
            NKpi(label: 'Failed', value: (logins['failure'] as num?) ?? 0, size: 34),
            NKpi(label: 'Blocked', value: ((logins['blocked'] as num?) ?? 0) + ((logins['locked'] as num?) ?? 0), size: 34),
          ]),
        ),
        if (storage != null)
          InfoCard(
            title: 'Storage',
            subtitle: Fmt.label(storage['provider']),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              NInfoRow(label: 'Used by files', value: Fmt.bytes(storage['totalBytes'])),
              NInfoRow(label: 'Failed uploads', value: '${storage['failedUploads'] ?? 0}'),
            ]),
          ),
      ]),
    ]);
  }
}
