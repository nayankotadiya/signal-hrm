import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:n_ui/n_ui.dart';

import '../../app/services.dart';
import '../../data/api.dart';
import '../../data/lookups.dart';
import '../../shell/app_shell.dart';
import '../../widgets/async_view.dart';
import '../../widgets/form_kit.dart';
import '../../widgets/format.dart';
import '../../widgets/section.dart';
import '../../widgets/status.dart';

class PeopleSection extends StatelessWidget {
  const PeopleSection({super.key, this.tab});
  final String? tab;

  @override
  Widget build(BuildContext context) {
    return SectionPage(
      basePath: '/people',
      tabId: tab,
      title: 'People',
      boldWord: 'directory',
      subtitle: 'Employees, departments, teams and company news.',
      tabs: [
        SectionTab('directory', 'Directory', Icons.badge_rounded, (_) => const DirectoryTab(), visible: (me) => me.can('employees', 'view', 'team')),
        SectionTab('org', 'Departments & teams', Icons.account_tree_rounded, (_) => const OrgTab(), visible: (me) => me.can('departments', 'view') || me.can('teams', 'view')),
        SectionTab('announcements', 'Announcements', Icons.campaign_rounded, (_) => const AnnouncementsTab(), visible: (me) => me.feature('announcements') && me.can('announcements', 'view')),
      ],
    );
  }
}

const _employmentTypes = [NOption('full_time', 'Full-time'), NOption('part_time', 'Part-time'), NOption('contract', 'Contract'), NOption('intern', 'Intern'), NOption('consultant', 'Consultant')];

bool _hasTeam(Json v) => v['teamId'] != null && v['teamId'].toString().isNotEmpty;

List<FieldSpec> employeeFields({bool create = false}) => [
      const FieldSpec('firstName', 'First name', required: true),
      const FieldSpec('lastName', 'Last name'),
      const FieldSpec('displayName', 'Preferred name'),
      const FieldSpec('contactEmail', 'Work email', kind: FieldKind.email, required: false),
      const FieldSpec('contactPhone', 'Phone', kind: FieldKind.phone),
      const FieldSpec('designation', 'Designation'),
      const FieldSpec('employmentType', 'Employment type', kind: FieldKind.select, options: _employmentTypes),
      const FieldSpec('joiningDate', 'Joining date', kind: FieldKind.date),
      const FieldSpec('departmentId', 'Department', kind: FieldKind.asyncSelect, loadOptions: Lookups.departments),
      const FieldSpec('teamId', 'Team', kind: FieldKind.asyncSelect, loadOptions: Lookups.teams),
      const FieldSpec(
        'isTeamLeader',
        'Team Leader',
        kind: FieldKind.toggle,
        description: 'Set as the official Team Leader of this team in the company structure.',
        visibleWhen: _hasTeam,
      ),
      const FieldSpec('reportingManagerId', 'Reporting manager', kind: FieldKind.asyncSelect, loadOptions: Lookups.employees),
      const FieldSpec('locationId', 'Work location', kind: FieldKind.asyncSelect, loadOptions: Lookups.locations, helper: 'Check-in is verified against this location.'),
      const FieldSpec('shiftId', 'Default shift', kind: FieldKind.asyncSelect, loadOptions: Lookups.shifts),
      const FieldSpec('probation.status', 'Probation', kind: FieldKind.select, options: [NOption('none', 'None'), NOption('on_probation', 'On probation'), NOption('confirmed', 'Confirmed'), NOption('extended', 'Extended')]),
      const FieldSpec('probation.endsOn', 'Probation ends', kind: FieldKind.date),
      const FieldSpec('employeeCode', 'Employee code', helper: 'Leave empty to number automatically.'),
      if (create) const FieldSpec('inviteNow', 'Create a sign-in account', kind: FieldKind.toggle),
      if (create) FieldSpec('inviteRole', 'Role', kind: FieldKind.asyncSelect, loadOptions: Lookups.roles, visibleWhen: (v) => v['inviteNow'] == true),
      if (create)
        const FieldSpec(
          'setPassword',
          'Set Password directly',
          kind: FieldKind.toggle,
          visibleWhen: _isInviting,
          description: 'Employee can sign in immediately with email & password without waiting for an email invitation.',
        ),
      if (create)
        FieldSpec(
          'password',
          'Password',
          kind: FieldKind.password,
          visibleWhen: (v) => v['inviteNow'] == true && v['setPassword'] == true,
          helper: 'Minimum 6 characters.',
        ),
    ];

bool _isInviting(Json v) => v['inviteNow'] == true;

Json employeeBody(Json v) {
  final out = <String, dynamic>{...v}
    ..remove('inviteNow')
    ..remove('inviteRole')
    ..remove('setPassword');
  final pwd = out.remove('password')?.toString().trim();
  final isLeader = v['isTeamLeader'] == true || v['inviteRole'] == 'team_leader';
  out['isTeamLeader'] = isLeader;
  if (v['inviteNow'] == true) {
    out['invite'] = {
      'role': v['inviteRole'] ?? (isLeader ? 'team_leader' : 'employee'),
      if (v['setPassword'] == true && pwd != null && pwd.isNotEmpty) 'password': pwd,
    };
  }
  return out;
}

class DirectoryTab extends StatefulWidget {
  const DirectoryTab({super.key});

  @override
  State<DirectoryTab> createState() => _DirectoryTabState();
}

class _DirectoryTabState extends State<DirectoryTab> {
  String _q = '';
  String? _dept;
  bool _archived = false;
  int _rev = 0;
  bool _handledNew = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    String? newParam;
    try {
      newParam = GoRouterState.of(context).uri.queryParameters['new'];
    } catch (_) {}
    if (newParam == '1' && !_handledNew && context.me.can('employees', 'create')) {
      _handledNew = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _create());
    }
  }

  Future<void> _create() async {
    final r = await showFormSheet<Json>(
      context,
      title: 'Add employee',
      initial: const {'employmentType': 'full_time', 'inviteNow': true, 'setPassword': true, 'inviteRole': 'employee', 'probation': {'status': 'none'}},
      fields: employeeFields(create: true),
      successMessage: 'Employee added.',
      submit: (v, key) async => jsonMap(await context.api.post('/employees', body: employeeBody(v), idempotencyKey: key)),
    );
    if (r != null && mounted) {
      setState(() => _rev++);
      context.go('/people/employee/${r['id']}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.me;
    final t = NTokens.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Toolbar(children: [
        SizedBox(width: 260, child: NSearchField(hint: 'Search name, code, email, role', onChanged: (v) => setState(() => _q = v))),
        SizedBox(
          width: 220,
          child: AsyncView<List<NOption<String>>>(
            load: () => Lookups.departments(context.api),
            compact: true,
            skeletonRows: 1,
            builder: (context, opts, _) => NSelect<String>(label: 'Department', value: _dept ?? '', options: [const NOption('', 'All departments'), ...opts], onChanged: (v) => setState(() => _dept = (v == null || v.isEmpty) ? null : v)),
          ),
        ),
        SizedBox(width: 180, child: NCheckRow(label: 'Former employees', value: _archived, onChanged: (v) => setState(() => _archived = v))),
        if (me.can('employees', 'create')) NButton(label: 'Add employee', icon: Icons.person_add_alt_1_rounded, compact: true, variant: NButtonVariant.accent, onPressed: _create),
      ]),
      PagedList(
        path: '/employees',
        query: {'q': _q.trim(), 'departmentId': _dept, if (_archived) 'archived': true},
        reloadKey: '$_q|$_dept|$_archived|$_rev',
        emptyTitle: 'No employees found',
        emptyMessage: me.can('employees', 'create') ? 'Add your first employee to get started.' : null,
        emptyIcon: Icons.badge_rounded,
        itemBuilder: (_, __, ___) => const SizedBox.shrink(),
        wrap: (context, items, _) => NDataTable(
          columns: const [NColumn('Name', flex: 3), NColumn('Code'), NColumn('Designation', flex: 2, hideOnTablet: true), NColumn('Department', flex: 2), NColumn('Joined', hideOnTablet: true), NColumn('Status')],
          onTapRow: (i) => context.go('/people/employee/${items[i]['id']}'),
          rows: [
            for (final e in items)
              [
                Row(children: [
                  NAvatar(name: employeeName(e), size: 28),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Flexible(child: Text(employeeName(e), overflow: TextOverflow.ellipsis)),
                      if (e['isTeamLeader'] == true) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(color: t.accent.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4)),
                          child: Text('TL', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: t.accent)),
                        ),
                      ],
                    ]),
                  ),
                ]),
                Text('${e['employeeCode']}'),
                Text('${e['designation'] ?? '—'}'),
                Text('${e['departmentName'] ?? '—'}'),
                Text(Fmt.date(e['joiningDate'])),
                StatusChip('${e['status']}'),
              ],
          ],
        ),
      ),
    ]);
  }
}

class EmployeePage extends StatefulWidget {
  const EmployeePage({super.key, required this.id});
  final String id;

  @override
  State<EmployeePage> createState() => _EmployeePageState();
}

class _EmployeePageState extends State<EmployeePage> {
  final _view = GlobalKey<AsyncViewState<Json>>();
  int _tab = 0;

  Future<void> _edit(Json e) async {
    final r = await showFormSheet<Json>(
      context,
      title: 'Edit ${employeeName(e)}',
      initial: e,
      fields: [
        ...employeeFields(),
        const FieldSpec('status', 'Employment status', kind: FieldKind.select, options: [NOption('onboarding', 'Onboarding'), NOption('active', 'Active'), NOption('probation', 'Probation'), NOption('notice', 'Notice period')]),
        const FieldSpec('effectiveOn', 'Change effective from', kind: FieldKind.date, helper: 'Recorded in the job history.'),
        const FieldSpec('note', 'Note for history'),
      ],
      omitEmpty: false,
      successMessage: 'Saved.',
      submit: (v, key) async {
        final body = employeeBody(v)..removeWhere((k, val) => val == null && e[k] == null);
        if (body['employeeCode'] == null) body.remove('employeeCode');
        return jsonMap(await context.api.patch('/employees/${widget.id}', body: body, idempotencyKey: key));
      },
    );
    if (r != null) _view.currentState?.reload();
  }

  Future<void> _sensitive() async {
    final r = await showFormSheet<Json>(
      context,
      title: 'Sensitive details',
      subtitle: 'Encrypted at rest. Leave a field empty to keep the stored value. Every change is audited.',
      fields: const [
        FieldSpec('dateOfBirth', 'Date of birth', kind: FieldKind.date),
        FieldSpec('bank.accountName', 'Account holder name'),
        FieldSpec('bank.accountNumber', 'Account number', helper: '6 to 20 digits'),
        FieldSpec('bank.ifsc', 'IFSC', hint: 'HDFC0001234'),
        FieldSpec('bank.bankName', 'Bank'),
        FieldSpec('tax.pan', 'PAN', hint: 'ABCDE1234F'),
        FieldSpec('tax.uan', 'UAN', helper: '12 digits'),
        FieldSpec('tax.regime', 'Tax regime', kind: FieldKind.select, options: [NOption('new', 'New'), NOption('old', 'Old')]),
      ],
      successMessage: 'Sensitive details saved.',
      submit: (v, key) async {
        v.removeWhere((k, val) => val is Map && val.values.every((x) => x == null));
        return jsonMap(await context.api.patch('/employees/${widget.id}/sensitive', body: v, idempotencyKey: key));
      },
    );
    if (r != null) _view.currentState?.reload();
  }

  Future<void> _invite(Json e) async {
    final r = await showFormSheet<Json>(
      context,
      title: 'Create Account / Invite',
      subtitle: 'Create Login ID & password directly, or send an email invitation.',
      initial: {'email': e['contactEmail'], 'fullName': '${e['firstName']} ${e['lastName'] ?? ''}'.trim(), 'role': e['isTeamLeader'] == true ? 'team_leader' : 'employee', 'createPassword': true},
      fields: [
        const FieldSpec('fullName', 'Full name', required: true),
        const FieldSpec('email', 'Email (Login ID)', kind: FieldKind.email, required: true),
        const FieldSpec('role', 'Role', kind: FieldKind.asyncSelect, loadOptions: Lookups.roles, required: true),
        const FieldSpec(
          'createPassword',
          'Create Password directly',
          kind: FieldKind.toggle,
          description: 'Employee can sign in immediately with email & password without waiting for an email invitation.',
        ),
        FieldSpec(
          'password',
          'Password',
          kind: FieldKind.password,
          visibleWhen: (v) => v['createPassword'] == true,
          helper: 'Minimum 6 characters. Employee logs in with email and this password.',
        ),
      ],
      submitLabel: 'Create Account',
      successMessage: 'Account created.',
      submit: (v, key) async {
        final body = Map<String, dynamic>.from(v);
        final createPwd = body.remove('createPassword') == true;
        final pwd = body['password']?.toString().trim();
        if (!createPwd || pwd == null || pwd.isEmpty) {
          body.remove('password');
          body['sendInvitation'] = true;
        } else {
          body['password'] = pwd;
          body['sendInvitation'] = false;
        }
        return jsonMap(await context.api.post('/users', body: {...body, 'employeeId': widget.id}, idempotencyKey: key));
      },
    );
    if (r != null) {
      if (r['hasPassword'] == true && mounted) {
        NToast.of(context).show('Account ready! Employee can now log in with their email and password.');
      }
      _view.currentState?.reload();
    }
  }

  Future<void> _offboard() async {
    final r = await showFormSheet<Json>(
      context,
      title: 'Start offboarding',
      subtitle: 'Creates the offboarding checklist. Access ends when you complete it.',
      fields: const [
        FieldSpec('lastWorkingDay', 'Last working day', kind: FieldKind.date, required: true),
        FieldSpec('reason', 'Reason', kind: FieldKind.multiline, helper: 'Stored as a sensitive field.'),
        FieldSpec('note', 'Internal note'),
      ],
      submitLabel: 'Start offboarding',
      successMessage: 'Offboarding started.',
      submit: (v, key) async => jsonMap(await context.api.post('/employees/${widget.id}/offboarding', body: v, idempotencyKey: key)),
    );
    if (r != null) _view.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final me = context.me;
    return PageFrame(
      child: AsyncView<Json>(
        key: _view,
        load: () async => jsonMap(await context.api.get('/employees/${widget.id}')),
        builder: (context, e, reload) {
          final can = jsonMap(e['can']);
          final s = jsonMap(e['sensitive']);
          final account = e['account'] == null ? null : jsonMap(e['account']);
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Align(alignment: AlignmentDirectional.centerStart, child: TextButton.icon(onPressed: () => context.go('/people'), icon: const Icon(Icons.arrow_back_rounded, size: 18), label: const Text('People'))),
            Row(children: [
              NAvatar(name: employeeName(e), size: 64),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(employeeName(e), style: t.text.heading(size: 28)),
                  Text([e['designation'], jsonMap(e['department'])['name'], e['employeeCode']].whereType<String>().join(' · '), style: t.text.body(color: t.muted)),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    StatusChip('${e['status']}'),
                    if (e['isTeamLeader'] == true) const StatusChip('active', label: 'Team Leader'),
                    if (account != null) StatusChip('${account['status']}', label: 'Account: ${Fmt.label(account['status'])} · ${Fmt.label(account['role'])}') else const StatusChip('none', label: 'No sign-in account'),
                  ]),
                ]),
              ),
            ]),
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (can['edit'] == true) NButton(label: 'Edit', icon: Icons.edit_rounded, compact: true, variant: NButtonVariant.secondary, onPressed: () => _edit(e)),
              if (can['editSensitive'] == true) NButton(label: 'Sensitive details', icon: Icons.lock_rounded, compact: true, variant: NButtonVariant.secondary, onPressed: _sensitive),
              if (account == null && me.can('users', 'create', 'organization')) NButton(label: 'Invite to sign in', icon: Icons.mail_rounded, compact: true, variant: NButtonVariant.secondary, onPressed: () => _invite(e)),
              if (account != null && account['status'] == 'invited' && me.can('users', 'create', 'organization'))
                NButton(
                  label: 'Resend invitation',
                  icon: Icons.forward_to_inbox_rounded,
                  compact: true,
                  variant: NButtonVariant.secondary,
                  onPressed: () async {
                    try {
                      await context.api.post('/users/${account['id']}/invitation');
                      if (context.mounted) NToast.of(context).show('Invitation sent again.');
                    } catch (err) {
                      if (context.mounted) showError(context, err);
                    }
                  },
                ),
              if (can['offboard'] == true && e['status'] != 'exited' && e['status'] != 'notice') NButton(label: 'Offboard', icon: Icons.logout_rounded, compact: true, variant: NButtonVariant.secondary, onPressed: _offboard),
            ]),
            const SizedBox(height: 16),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: NSlidingPills(
                items: const [NPillItem(label: 'Profile'), NPillItem(label: 'Checklists'), NPillItem(label: 'History'), NPillItem(label: 'Leave')],
                selectedIndex: _tab,
                onChanged: (i) => setState(() => _tab = i),
                semanticLabel: 'Employee sections',
              ),
            ),
            const SizedBox(height: 14),
            NViewSwitcher(
              index: _tab,
              child: KeyedSubtree(
                key: ValueKey(_tab),
                child: switch (_tab) {
                  0 => CardGrid(minTileWidth: 360, children: [
                      InfoCard(
                        title: 'Job',
                        child: Column(children: [
                          NInfoRow(label: 'Employment type', value: Fmt.label(e['employmentType'])),
                          NInfoRow(label: 'Joined', value: Fmt.date(e['joiningDate'])),
                          NInfoRow(label: 'Manager', value: '${jsonMap(e['manager'])['name'] ?? ''}'),
                          NInfoRow(label: 'Team', value: '${jsonMap(e['team'])['name'] ?? ''}'),
                          NInfoRow(label: 'Location', value: '${jsonMap(e['location'])['name'] ?? 'Not assigned'}'),
                          NInfoRow(label: 'Shift', value: e['shift'] == null ? 'Not assigned' : '${jsonMap(e['shift'])['name']} ${jsonMap(e['shift'])['startTime']}–${jsonMap(e['shift'])['endTime']}'),
                          NInfoRow(label: 'Probation', value: '${Fmt.label(jsonMap(e['probation'])['status'])}${jsonMap(e['probation'])['endsOn'] != null ? ' · ends ${Fmt.date(jsonMap(e['probation'])['endsOn'])}' : ''}'),
                          if (e['exitDate'] != null) NInfoRow(label: 'Exit date', value: Fmt.date(e['exitDate'])),
                        ]),
                      ),
                      InfoCard(
                        title: 'Contact',
                        child: Column(children: [
                          NInfoRow(label: 'Email', value: '${e['contactEmail'] ?? ''}'),
                          NInfoRow(label: 'Phone', value: '${e['contactPhone'] ?? ''}'),
                          NInfoRow(label: 'Emergency contact', value: [jsonMap(e['emergencyContact'])['name'], jsonMap(e['emergencyContact'])['relation'], jsonMap(e['emergencyContact'])['phone']].whereType<String>().join(' · ')),
                          if (account != null) NInfoRow(label: 'Last sign-in', value: account['lastLoginAt'] == null ? 'Never' : Fmt.relative(account['lastLoginAt'])),
                        ]),
                      ),
                      InfoCard(
                        title: 'Sensitive',
                        subtitle: s['locked'] == true ? 'Hidden. Needs the sensitive-fields permission.' : 'Masked. Full values are never shown.',
                        child: s['locked'] == true
                            ? Row(children: [Icon(Icons.lock_rounded, color: t.muted, size: 18), const SizedBox(width: 8), Text('Restricted', style: t.text.body(color: t.muted))])
                            : Column(children: [
                                NInfoRow(label: 'Date of birth', value: Fmt.date(s['dateOfBirth'])),
                                NInfoRow(label: 'Bank', value: [jsonMap(s['bank'])['bankName'], jsonMap(s['bank'])['accountNumber'], jsonMap(s['bank'])['ifsc']].whereType<String>().join(' · ')),
                                NInfoRow(label: 'PAN', value: '${jsonMap(s['tax'])['pan'] ?? ''}'),
                                NInfoRow(label: 'UAN', value: '${jsonMap(s['tax'])['uan'] ?? ''}'),
                                NInfoRow(label: 'Tax regime', value: Fmt.label(jsonMap(s['tax'])['regime'])),
                              ]),
                      ),
                    ]),
                  1 => _Checklists(employeeId: widget.id, editable: can['edit'] == true, onCompleteOffboarding: can['offboard'] == true ? reload : null),
                  2 => AsyncView<List<Json>>(
                      load: () async => jsonList(await context.api.get('/employees/${widget.id}/history')),
                      builder: (context, items, _) => items.isEmpty
                          ? const NEmptyState(title: 'No history yet', compact: true, icon: Icons.history_rounded)
                          : InfoCard(
                              title: 'Job history',
                              child: NTimeline(entries: [
                                for (final h in items)
                                  NTimelineEntry(
                                    title: Fmt.label(h['changeType'] ?? h['type'] ?? 'change'),
                                    subtitle: [
                                      for (final c in jsonMap(h['changes']).entries) '${Fmt.label(c.key)}: ${jsonMap(c.value)['from'] ?? '—'} → ${jsonMap(c.value)['to'] ?? '—'}',
                                      if (h['note'] != null) '${h['note']}',
                                    ].join('\n'),
                                    time: Fmt.date(h['effectiveOn'] ?? h['createdAt']),
                                  ),
                              ]),
                            ),
                    ),
                  _ => _LeaveBalances(employeeId: widget.id),
                },
              ),
            ),
          ]);
        },
      ),
    );
  }
}

class _Checklists extends StatelessWidget {
  const _Checklists({required this.employeeId, required this.editable, this.onCompleteOffboarding});
  final String employeeId;
  final bool editable;
  final VoidCallback? onCompleteOffboarding;

  @override
  Widget build(BuildContext context) {
    return CardGrid(minTileWidth: 380, children: [
      for (final kind in ['onboarding', 'offboarding'])
        AsyncView<Json?>(
          load: () async {
            final j = await context.api.get('/employees/$employeeId/checklists/$kind');
            return j == null ? null : jsonMap(j);
          },
          compact: true,
          builder: (context, c, reload) {
            if (c == null) return InfoCard(title: Fmt.label(kind), child: const NEmptyState(title: 'No checklist', compact: true, icon: Icons.checklist_rounded));
            final items = jsonList(c['items']);
            return InfoCard(
              title: Fmt.label(kind),
              subtitle: '${c['progress']}% done · ${Fmt.label(c['status'])}',
              trailing: SizedBox(width: 100, child: NProgressBar(fraction: ((c['progress'] as num?) ?? 0) / 100, semanticLabel: '$kind progress')),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final i in items)
                  NCheckRow(
                    label: '${i['title']}',
                    description: [if (i['ownerRole'] != null) 'Owner: ${Fmt.label(i['ownerRole'])}', if (i['dueOn'] != null) 'Due ${Fmt.date(i['dueOn'])}', if (i['doneAt'] != null) 'Done ${Fmt.relative(i['doneAt'])}'].join(' · '),
                    value: i['done'] == true,
                    onChanged: editable && c['status'] == 'open'
                        ? (v) async {
                            try {
                              await context.api.post('/employees/$employeeId/checklists/$kind/items/${i['key']}', body: {'done': v});
                              reload();
                            } catch (e) {
                              if (context.mounted) showError(context, e);
                            }
                          }
                        : null,
                  ),
                if (kind == 'offboarding' && c['status'] == 'open' && onCompleteOffboarding != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: NButton(
                      label: 'Complete offboarding',
                      icon: Icons.task_alt_rounded,
                      compact: true,
                      onPressed: () async {
                        final r = await showNConfirm(context, title: 'Complete offboarding?', message: 'The employee is marked as exited and their sessions are revoked. Records are kept under your retention rules.', confirmLabel: 'Complete', destructive: true);
                        if (!r.confirmed || !context.mounted) return;
                        try {
                          await context.api.post('/employees/$employeeId/offboarding/complete');
                          onCompleteOffboarding!();
                        } catch (e) {
                          if (context.mounted) showError(context, e);
                        }
                      },
                    ),
                  ),
              ]),
            );
          },
        ),
    ]);
  }
}

class _LeaveBalances extends StatelessWidget {
  const _LeaveBalances({required this.employeeId});
  final String employeeId;

  @override
  Widget build(BuildContext context) {
    final me = context.me;
    return AsyncView<List<Json>>(
      load: () async => jsonList(await context.api.get('/leave/balances', query: {'employeeId': employeeId})),
      builder: (context, items, reload) => InfoCard(
        title: 'Leave balances ${DateTime.now().year}',
        trailing: me.can('leave', 'manage')
            ? NButton(
                label: 'Adjust',
                compact: true,
                variant: NButtonVariant.secondary,
                onPressed: () async {
                  final r = await showFormSheet<Json>(
                    context,
                    title: 'Adjust balance',
                    subtitle: 'Recorded in the leave ledger with your reason.',
                    fields: [
                      FieldSpec('leaveTypeId', 'Leave type', kind: FieldKind.select, required: true, options: [for (final b in items) NOption('${b['leaveTypeId']}', '${b['name']}')]),
                      const FieldSpec('delta', 'Days (+ to add, − to remove; halves allowed)', kind: FieldKind.number, required: true),
                      const FieldSpec('reason', 'Reason', required: true),
                    ],
                    successMessage: 'Balance adjusted.',
                    submit: (v, key) async => jsonMap(await context.api.post('/leave/balances/adjust', idempotencyKey: key, body: {...v, 'employeeId': employeeId, 'year': DateTime.now().year})),
                  );
                  if (r != null) reload();
                },
              )
            : null,
        child: items.isEmpty
            ? const NEmptyState(title: 'No leave policy applies', compact: true, icon: Icons.beach_access_rounded)
            : NDataTable(
                columns: const [NColumn('Type', flex: 3), NColumn('Accrued', numeric: true), NColumn('Used', numeric: true), NColumn('Pending', numeric: true), NColumn('Adjusted', numeric: true, hideOnTablet: true), NColumn('Available', numeric: true)],
                rows: [
                  for (final b in items)
                    [Text('${b['name']}'), Text(Fmt.number(b['accrued'])), Text(Fmt.number(b['used'])), Text(Fmt.number(b['pending'])), Text(Fmt.number(b['adjusted'])), Text(Fmt.number(b['available']))],
                ],
              ),
      ),
    );
  }
}

// ======================================================================= org structure

class OrgTab extends StatefulWidget {
  const OrgTab({super.key});

  @override
  State<OrgTab> createState() => _OrgTabState();
}

class _OrgTabState extends State<OrgTab> {
  int _rev = 0;

  Future<void> _dept([Json? d]) async {
    final api = context.api;
    final r = await showFormSheet<Json>(
      context,
      title: d == null ? 'New department' : 'Edit ${d['name']}',
      initial: d ?? const {},
      fields: const [
        FieldSpec('name', 'Name', required: true),
        FieldSpec('description', 'Description', kind: FieldKind.multiline),
        FieldSpec('headEmployeeId', 'Head of department', kind: FieldKind.asyncSelect, loadOptions: Lookups.employees, helper: 'Approval chains can route to the department head.'),
      ],
      successMessage: 'Department saved.',
      submit: (v, key) async => jsonMap(d == null ? await api.post('/departments', body: v, idempotencyKey: key) : await api.patch('/departments/${d['id']}', body: v, idempotencyKey: key)),
    );
    if (r != null) setState(() => _rev++);
  }

  Future<void> _team([Json? tm]) async {
    final api = context.api;
    final r = await showFormSheet<Json>(
      context,
      title: tm == null ? 'New team' : 'Edit ${tm['name']}',
      initial: tm ?? const {},
      fields: const [
        FieldSpec('name', 'Name', required: true),
        FieldSpec('departmentId', 'Department', kind: FieldKind.asyncSelect, loadOptions: Lookups.departments),
        FieldSpec('leadEmployeeId', 'Team Leader', kind: FieldKind.asyncSelect, loadOptions: Lookups.employees, helper: 'Designated Team Leader in company structure.'),
      ],
      successMessage: 'Team saved.',
      submit: (v, key) async => jsonMap(tm == null ? await api.post('/teams', body: v, idempotencyKey: key) : await api.patch('/teams/${tm['id']}', body: v, idempotencyKey: key)),
    );
    if (r != null) setState(() => _rev++);
  }

  Future<void> _archive(String kind, Json x) async {
    final c = await showNConfirm(context, title: 'Archive ${x['name']}?', message: 'People keep their records; the $kind disappears from pickers.', confirmLabel: 'Archive', destructive: true);
    if (!c.confirmed || !mounted) return;
    try {
      await context.api.delete('/${kind == 'department' ? 'departments' : 'teams'}/${x['id']}');
      setState(() => _rev++);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.me;
    return CardGrid(minTileWidth: 380, children: [
      InfoCard(
        title: 'Departments',
        trailing: me.can('departments', 'create') ? NButton(label: 'New', icon: Icons.add_rounded, compact: true, onPressed: () => _dept()) : null,
        child: AsyncView<List<Json>>(
          reloadKey: _rev,
          load: () async => jsonList(await context.api.get('/departments')),
          builder: (context, items, _) => items.isEmpty
              ? const NEmptyState(title: 'No departments', compact: true, icon: Icons.account_tree_rounded)
              : Column(children: [
                  for (final d in items.where((d) => d['status'] != 'archived'))
                    NListRow(
                      title: '${d['name']}',
                      subtitle: [if (d['memberCount'] != null) '${d['memberCount']} people', if (d['headName'] != null) 'Head: ${d['headName']}', if (d['description'] != null) '${d['description']}'].join(' · '),
                      trailing: me.can('departments', 'edit')
                          ? Wrap(children: [
                              IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_rounded, size: 18), onPressed: () => _dept(d)),
                              if (me.can('departments', 'delete')) IconButton(tooltip: 'Archive', icon: const Icon(Icons.archive_outlined, size: 18), onPressed: () => _archive('department', d)),
                            ])
                          : null,
                    ),
                ]),
        ),
      ),
      InfoCard(
        title: 'Teams',
        trailing: me.can('teams', 'create') ? NButton(label: 'New', icon: Icons.add_rounded, compact: true, onPressed: () => _team()) : null,
        child: AsyncView<List<Json>>(
          reloadKey: _rev,
          load: () async => jsonList(await context.api.get('/teams')),
          builder: (context, items, _) => items.isEmpty
              ? const NEmptyState(title: 'No teams', compact: true, icon: Icons.groups_rounded)
              : Column(children: [
                  for (final tm in items.where((x) => x['status'] != 'archived'))
                    NListRow(
                      title: '${tm['name']}',
                      subtitle: [if (tm['departmentName'] != null) '${tm['departmentName']}', '${(tm['memberIds'] as List? ?? const []).length} members', if (tm['leadName'] != null) 'Team Leader: ${tm['leadName']}'].join(' · '),
                      trailing: me.can('teams', 'edit')
                          ? Wrap(children: [
                              IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_rounded, size: 18), onPressed: () => _team(tm)),
                              if (me.can('teams', 'delete')) IconButton(tooltip: 'Archive', icon: const Icon(Icons.archive_outlined, size: 18), onPressed: () => _archive('team', tm)),
                            ])
                          : null,
                    ),
                ]),
        ),
      ),
    ]);
  }
}

// ======================================================================= announcements

class AnnouncementsTab extends StatefulWidget {
  const AnnouncementsTab({super.key});

  @override
  State<AnnouncementsTab> createState() => _AnnouncementsTabState();
}

class _AnnouncementsTabState extends State<AnnouncementsTab> {
  int _rev = 0;

  Future<void> _publish({bool kudos = false}) async {
    final r = await showFormSheet<Json>(
      context,
      title: kudos ? 'Give kudos' : 'New announcement',
      fields: [
        if (kudos) const FieldSpec('toEmployeeId', 'To', kind: FieldKind.asyncSelect, loadOptions: Lookups.employees, required: true),
        FieldSpec('title', kudos ? 'Headline' : 'Title', required: true, maxLength: 140),
        const FieldSpec('body', 'Message', kind: FieldKind.multiline, maxLength: 5000),
        if (!kudos) const FieldSpec('pinned', 'Pin to the top', kind: FieldKind.toggle),
        if (!kudos) const FieldSpec('expiresAt', 'Hide after', kind: FieldKind.date),
      ],
      submitLabel: kudos ? 'Send kudos' : 'Publish',
      successMessage: kudos ? 'Kudos sent.' : 'Published.',
      submit: (v, key) async => jsonMap(await context.api.post('/announcements', idempotencyKey: key, body: {...v, 'kind': kudos ? 'kudos' : 'announcement', 'pinned': v['pinned'] == true})),
    );
    if (r != null) setState(() => _rev++);
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final me = context.me;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Toolbar(children: [
        if (me.can('announcements', 'create')) NButton(label: 'Announce', icon: Icons.campaign_rounded, compact: true, variant: NButtonVariant.accent, onPressed: _publish),
        NButton(label: 'Give kudos', icon: Icons.celebration_rounded, compact: true, variant: NButtonVariant.secondary, onPressed: () => _publish(kudos: true)),
      ]),
      AsyncView<List<Json>>(
        reloadKey: _rev,
        load: () async => jsonList(await context.api.get('/announcements')),
        builder: (context, items, reload) => items.isEmpty
            ? const NEmptyState(title: 'No announcements yet', icon: Icons.campaign_rounded)
            : Column(children: [
                for (final a in items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: NGlassCard(
                      blur: false,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Row(children: [
                          Icon(a['kind'] == 'kudos' ? Icons.celebration_rounded : (a['pinned'] == true ? Icons.push_pin_rounded : Icons.campaign_rounded), size: 18, color: a['kind'] == 'kudos' ? t.amber : t.muted),
                          const SizedBox(width: 8),
                          Expanded(child: Text('${a['title']}', style: t.text.title(size: 16))),
                          Text(Fmt.relative(a['publishedAt'] ?? a['createdAt']), style: t.text.caption()),
                        ]),
                        if (a['kind'] == 'kudos' && a['toName'] != null) Text('To ${a['toName']}${a['authorName'] != null ? ' from ${a['authorName']}' : ''}', style: t.text.caption()),
                        if ((a['body'] ?? '').toString().isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: SelectableText('${a['body']}', style: t.text.body())),
                        const SizedBox(height: 8),
                        Wrap(spacing: 6, children: [
                          for (final (key, emoji) in const [('clap', '👏'), ('party', '🎉'), ('heart', '❤️'), ('thumbs_up', '👍')])
                            ActionChip(
                              label: Text('$emoji ${jsonMap(a['reactions'])[key] ?? 0}'),
                              tooltip: 'React ${Fmt.label(key)}',
                              onPressed: () async {
                                try {
                                  await context.api.post('/announcements/${a['id']}/react', body: {'emoji': key});
                                  reload();
                                } catch (e) {
                                  if (context.mounted) showError(context, e);
                                }
                              },
                            ),
                          if (me.can('announcements', 'manage'))
                            IconButton(
                              tooltip: 'Remove',
                              icon: Icon(Icons.delete_outline_rounded, size: 18, color: t.muted),
                              onPressed: () async {
                                final c = await showNConfirm(context, title: 'Remove this post?', message: 'It disappears for everyone. The removal is audited.', confirmLabel: 'Remove', destructive: true);
                                if (!c.confirmed || !context.mounted) return;
                                try {
                                  await context.api.delete('/announcements/${a['id']}');
                                  reload();
                                } catch (e) {
                                  if (context.mounted) showError(context, e);
                                }
                              },
                            ),
                        ]),
                      ]),
                    ),
                  ),
              ]),
      ),
    ]);
  }
}
