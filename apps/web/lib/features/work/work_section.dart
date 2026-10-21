import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

class WorkSection extends StatelessWidget {
  const WorkSection({super.key, this.tab});
  final String? tab;

  @override
  Widget build(BuildContext context) {
    return SectionPage(
      basePath: '/work',
      tabId: tab,
      title: 'Work',
      boldWord: 'board',
      subtitle: 'Tasks, leads, meetings and travel.',
      tabs: [
        SectionTab('tasks', 'Tasks', Icons.view_kanban_rounded, (_) => const TasksTab(), visible: (me) => me.feature('tasks') && me.can('tasks', 'view')),
        SectionTab('leads', 'Leads', Icons.trending_up_rounded, (_) => const LeadsTab(), visible: (me) => me.feature('crm') && me.can('crm', 'view')),
        SectionTab('meetings', 'Meetings', Icons.video_call_rounded, (_) => const MeetingsTab(), visible: (me) => me.feature('meetings') && me.can('meetings', 'view')),
        SectionTab('travel', 'Travel', Icons.flight_takeoff_rounded, (_) => const TravelTab(), visible: (me) => me.feature('travel') && me.can('travel', 'view')),
      ],
    );
  }
}

String? _openParam(BuildContext context) {
  try {
    return GoRouterState.of(context).uri.queryParameters['open'];
  } catch (_) {
    return null;
  }
}

// ======================================================================= tasks

const taskColumns = [
  ('todo', 'To do'),
  ('in_progress', 'In progress'),
  ('blocked', 'Blocked'),
  ('in_review', 'In review'),
  ('completed', 'Completed'),
];

List<FieldSpec> taskFields({required bool canAssign}) => [
      const FieldSpec('title', 'Title', required: true, maxLength: 200),
      const FieldSpec('description', 'Description', kind: FieldKind.multiline),
      if (canAssign) const FieldSpec('assigneeId', 'Assignee', kind: FieldKind.asyncSelect, loadOptions: Lookups.employees),
      const FieldSpec('priority', 'Priority', kind: FieldKind.select, options: [NOption('low', 'Low'), NOption('medium', 'Medium'), NOption('high', 'High'), NOption('urgent', 'Urgent')]),
      const FieldSpec('dueDate', 'Due', kind: FieldKind.date),
      const FieldSpec('tagsText', 'Tags', hint: 'reels, client-x', helper: 'Comma-separated'),
      const FieldSpec('requiresReview', 'Needs review before completion', kind: FieldKind.toggle),
    ];

Json taskBody(Json v) {
  final out = <String, dynamic>{...v}
    ..remove('assigneeId')
    ..remove('tagsText');
  if (v.containsKey('assigneeId')) out['assigneeIds'] = v['assigneeId'] == null ? [] : [v['assigneeId']];
  if (v['tagsText'] != null) out['tags'] = [for (final s in '${v['tagsText']}'.split(',')) if (s.trim().isNotEmpty) s.trim()];
  if (out['requiresReview'] == null) out.remove('requiresReview');
  return out;
}

class TasksTab extends StatefulWidget {
  const TasksTab({super.key});

  @override
  State<TasksTab> createState() => _TasksTabState();
}

class _TasksTabState extends State<TasksTab> {
  String _view = 'mine';
  bool _board = true;
  String _q = '';
  int _rev = 0;
  bool _openedFromLink = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final open = _openParam(context);
    if (open != null && !_openedFromLink) {
      _openedFromLink = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => openTask(context, open, onChanged: () => setState(() => _rev++)));
    }
  }

  Future<void> _create() async {
    final me = context.me;
    final r = await showFormSheet<Json>(
      context,
      title: 'New task',
      initial: {'priority': 'medium', if (!me.can('tasks', 'assign') && me.employeeId != null) 'assigneeId': me.employeeId},
      fields: taskFields(canAssign: me.can('tasks', 'assign')),
      successMessage: 'Task created.',
      submit: (v, key) async {
        final body = taskBody(v);
        if (!me.can('tasks', 'assign') && me.employeeId != null) body['assigneeIds'] = [me.employeeId];
        return jsonMap(await context.api.post('/tasks', body: body, idempotencyKey: key));
      },
    );
    if (r != null) setState(() => _rev++);
  }

  Future<void> _move(Json task, String to) async {
    try {
      await context.api.post('/tasks/${task['id']}/move', body: {'status': to});
      if (mounted) setState(() => _rev++);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final me = context.me;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Toolbar(children: [
        NFilterChips<String>(
          value: _view,
          onChanged: (v) => setState(() => _view = v),
          options: [
            const NOption('mine', 'Mine'),
            if (me.can('tasks', 'view', 'team')) const NOption('team', 'Team'),
            if (me.can('tasks', 'view', 'organization')) const NOption('all', 'Everyone'),
          ],
        ),
        SizedBox(width: 240, child: NSearchField(hint: 'Search tasks', onChanged: (v) => setState(() => _q = v))),
        NFilterChips<bool>(value: _board, onChanged: (v) => setState(() => _board = v), options: const [NOption(true, 'Board'), NOption(false, 'List')]),
        if (me.can('tasks', 'create') || me.employeeId != null) NButton(label: 'New task', icon: Icons.add_rounded, compact: true, variant: NButtonVariant.accent, onPressed: _create),
      ]),
      AsyncView<List<Json>>(
        reloadKey: '$_view|$_q|$_rev',
        load: () async => jsonList(await context.api.get('/tasks', query: {'view': _view, 'q': _q.trim(), 'limit': 300})),
        builder: (context, items, reload) {
          if (items.isEmpty) return NEmptyState(title: 'No tasks', message: _q.isEmpty ? 'Create a task to get started.' : 'Nothing matches "$_q".', icon: Icons.task_alt_rounded, actionLabel: 'New task', onAction: _create);
          if (!_board) {
            return NDataTable(
              columns: const [NColumn('Task', flex: 4), NColumn('Assignees', flex: 2, hideOnTablet: true), NColumn('Due'), NColumn('Priority'), NColumn('Status')],
              onTapRow: (i) => openTask(context, '${items[i]['id']}', onChanged: () => setState(() => _rev++)),
              rows: [
                for (final task in items)
                  [
                    Text('${task['title']}', maxLines: 2, overflow: TextOverflow.ellipsis),
                    Text(jsonList(task['assignees']).map((a) => a['name']).join(', ')),
                    Text(task['dueDate'] == null ? '—' : Fmt.date(task['dueDate']), style: t.text.body(color: _overdue(task) ? t.dangerText : null)),
                    StatusChip('${task['priority']}'),
                    StatusChip('${task['status']}'),
                  ],
              ],
            );
          }
          return NKanban<Json>(
            columns: [
              for (final c in taskColumns) NKanbanColumn(id: c.$1, title: c.$2, items: items.where((i) => i['status'] == c.$1).toList()),
            ],
            itemId: (i) => '${i['id']}',
            onMove: _move,
            itemBuilder: (context, task, menu) => _TaskCard(task: task, menu: menu, onTap: () => openTask(context, '${task['id']}', onChanged: () => setState(() => _rev++))),
          );
        },
      ),
    ]);
  }
}

bool _overdue(Json task) => task['dueDate'] != null && '${task['dueDate']}'.compareTo(Fmt.day(DateTime.now())) < 0 && task['status'] != 'completed' && task['status'] != 'cancelled';

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.task, required this.menu, required this.onTap});
  final Json task;
  final Widget menu;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final assignees = jsonList(task['assignees']);
    return Material(
      color: t.card,
      borderRadius: BorderRadius.circular(t.radiusTile),
      child: InkWell(
        borderRadius: BorderRadius.circular(t.radiusTile),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Text('${task['title']}', style: t.text.body(weight: FontWeight.w500))),
              menu,
            ]),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              if (task['priority'] == 'high' || task['priority'] == 'urgent') StatusChip(task['priority'] == 'urgent' ? 'critical' : 'high', label: Fmt.label(task['priority'])),
              if (task['dueDate'] != null) Text('Due ${Fmt.shortDate(task['dueDate'])}', style: t.text.caption(color: _overdue(task) ? t.dangerText : null)),
              if ((task['commentCount'] as num? ?? 0) > 0) Text('💬 ${task['commentCount']}', style: t.text.caption()),
              for (final a in assignees.take(3)) NAvatar(name: '${a['name']}', size: 22),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// Task detail in a side panel: fields, checklist, comments and activity.
Future<void> openTask(BuildContext context, String id, {VoidCallback? onChanged}) async {
  final api = context.api;
  await showNSheet<void>(
    context,
    title: 'Task',
    builder: (ctx) => ApiScope(api: api, child: _TaskDetail(id: id, onChanged: onChanged)),
  );
}

class _TaskDetail extends StatefulWidget {
  const _TaskDetail({required this.id, this.onChanged});
  final String id;
  final VoidCallback? onChanged;

  @override
  State<_TaskDetail> createState() => _TaskDetailState();
}

class _TaskDetailState extends State<_TaskDetail> {
  final _view = GlobalKey<AsyncViewState<Json>>();
  final _comment = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  ApiClient get _api => ApiScope.of(context);

  Future<void> _patch(Json body) async {
    try {
      await _api.patch('/tasks/${widget.id}', body: body);
      _view.currentState?.reload();
      widget.onChanged?.call();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _send() async {
    if (_comment.text.trim().isEmpty) return;
    setState(() => _sending = true);
    try {
      await _api.post('/tasks/${widget.id}/comments', body: {'body': _comment.text.trim()});
      _comment.clear();
      _view.currentState?.reload();
      widget.onChanged?.call();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return AsyncView<Json>(
      key: _view,
      load: () async => jsonMap(await _api.get('/tasks/${widget.id}')),
      builder: (context, task, reload) {
        final can = jsonMap(task['can']);
        final editable = can['edit'] == true;
        final checklist = jsonList(task['checklist']);
        return ListView(padding: const EdgeInsets.all(20), children: [
          Text('${task['title']}', style: t.text.title(size: 20)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [StatusChip('${task['status']}'), StatusChip('${task['priority']}', label: 'Priority: ${Fmt.label(task['priority'])}')]),
          const SizedBox(height: 12),
          if (editable)
            NSelect<String>(
              label: 'Status',
              value: '${task['status']}',
              options: [for (final c in taskColumns) NOption(c.$1, c.$2), const NOption('cancelled', 'Cancelled')],
              onChanged: (v) async {
                if (v == null || v == task['status']) return;
                try {
                  await _api.post('/tasks/${widget.id}/move', body: {'status': v});
                  reload();
                  widget.onChanged?.call();
                } catch (e) {
                  if (context.mounted) showError(context, e);
                }
              },
            ),
          NInfoRow(label: 'Assignees', value: jsonList(task['assignees']).map((a) => a['name']).join(', ')),
          NInfoRow(label: 'Due', value: task['dueDate'] == null ? '' : Fmt.date(task['dueDate'])),
          if ((task['tags'] as List? ?? const []).isNotEmpty) NInfoRow(label: 'Tags', value: (task['tags'] as List).join(', ')),
          if (task['requiresReview'] == true) const NInfoRow(label: 'Review', value: 'Needs review before completion'),
          if ((task['description'] ?? '').toString().isNotEmpty) ...[const SizedBox(height: 8), SelectableText('${task['description']}', style: t.text.body())],
          if (editable) ...[
            const SizedBox(height: 10),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: NButton(
                label: 'Edit details',
                icon: Icons.edit_rounded,
                compact: true,
                variant: NButtonVariant.secondary,
                onPressed: () async {
                  final r = await showFormSheet<Json>(
                    context,
                    title: 'Edit task',
                    initial: {...task, 'assigneeId': (task['assigneeIds'] as List? ?? const []).isEmpty ? null : (task['assigneeIds'] as List).first, 'tagsText': (task['tags'] as List? ?? const []).join(', ')},
                    fields: taskFields(canAssign: can['assign'] == true),
                    omitEmpty: false,
                    submit: (v, key) async => jsonMap(await _api.patch('/tasks/${widget.id}', body: taskBody(v), idempotencyKey: key)),
                    successMessage: 'Task updated.',
                  );
                  if (r != null) {
                    reload();
                    widget.onChanged?.call();
                  }
                },
              ),
            ),
          ],
          const SizedBox(height: 16),
          NCardTitle('Checklist', subtitle: checklist.isEmpty ? null : '${checklist.where((c) => c['done'] == true).length} of ${checklist.length} done'),
          for (var i = 0; i < checklist.length; i++)
            NCheckRow(
              label: '${checklist[i]['text']}',
              value: checklist[i]['done'] == true,
              onChanged: editable
                  ? (v) => _patch({
                        'checklist': [
                          for (var j = 0; j < checklist.length; j++) {'id': '${checklist[j]['id']}', 'text': '${checklist[j]['text']}', 'done': j == i ? v : checklist[j]['done'] == true},
                        ],
                      })
                  : null,
            ),
          if (editable)
            TextButton.icon(
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add item'),
              onPressed: () async {
                final r = await showNConfirm(context, title: 'Add checklist item', message: 'Describe the step.', confirmLabel: 'Add', reasonLabel: 'Item');
                if (r.confirmed && r.reason != null) {
                  await _patch({
                    'checklist': [
                      for (final c in checklist) {'id': '${c['id']}', 'text': '${c['text']}', 'done': c['done'] == true},
                      {'id': newIdempotencyKey().substring(0, 12), 'text': r.reason, 'done': false},
                    ],
                  });
                }
              },
            ),
          const SizedBox(height: 16),
          NCardTitle('Comments', subtitle: '${jsonList(task['comments']).length}'),
          for (final c in jsonList(task['comments']))
            NListRow(dense: true, leading: NAvatar(name: '${c['authorName'] ?? '?'}', size: 28), title: '${c['authorName'] ?? 'Someone'} · ${Fmt.relative(c['createdAt'])}', subtitle: '${c['body']}'),
          const SizedBox(height: 6),
          NTextField(label: 'Add a comment', controller: _comment, maxLines: 3, hint: 'Mention progress, blockers or questions'),
          const SizedBox(height: 8),
          Align(alignment: AlignmentDirectional.centerEnd, child: NButton(label: 'Comment', compact: true, busy: _sending, onPressed: _send)),
          const SizedBox(height: 16),
          const NCardTitle('Activity'),
          NTimeline(entries: [
            for (final a in jsonList(task['activity']).take(30)) NTimelineEntry(title: '${a['actorName'] ?? 'System'} · ${Fmt.label(a['action'] ?? a['type'])}', subtitle: a['detail'] as String?, time: Fmt.dateTime(a['createdAt'])),
          ]),
        ]);
      },
    );
  }
}

// ======================================================================= leads

const leadStages = ['new', 'contacted', 'interested', 'qualified', 'meeting_scheduled', 'proposal', 'won', 'lost', 'unreachable'];

List<FieldSpec> leadFields() => const [
      FieldSpec('name', 'Name', required: true),
      FieldSpec('company', 'Company'),
      FieldSpec('phone', 'Phone', kind: FieldKind.phone),
      FieldSpec('email', 'Email', kind: FieldKind.email),
      FieldSpec('source', 'Source', kind: FieldKind.asyncSelect, loadOptions: Lookups.leadSources),
      FieldSpec('ownerEmployeeId', 'Owner', kind: FieldKind.asyncSelect, loadOptions: Lookups.employees),
      FieldSpec('priority', 'Priority', kind: FieldKind.select, options: [NOption('low', 'Low'), NOption('medium', 'Medium'), NOption('high', 'High')]),
      FieldSpec('interest', 'Interest', kind: FieldKind.select, options: [NOption('cold', 'Cold'), NOption('warm', 'Warm'), NOption('hot', 'Hot')]),
      FieldSpec('estimatedValue', 'Estimated value', kind: FieldKind.money, min: 0),
      FieldSpec('nextFollowUpDate', 'Next follow-up', kind: FieldKind.date),
      FieldSpec('campaignRef', 'Campaign'),
      FieldSpec('notes', 'Notes', kind: FieldKind.multiline),
      FieldSpec('consent.whatsapp', 'Agreed to WhatsApp messages', kind: FieldKind.toggle),
      FieldSpec('consent.call', 'Agreed to calls', kind: FieldKind.toggle),
      FieldSpec('consent.marketing', 'Agreed to marketing', kind: FieldKind.toggle),
    ];

Json leadBody(Json v) {
  final out = <String, dynamic>{...v}..remove('nextFollowUpDate');
  if (v['nextFollowUpDate'] != null) out['nextFollowUpAt'] = DateTime.parse('${v['nextFollowUpDate']}T10:00:00').toUtc().toIso8601String();
  final consent = jsonMap(v['consent']);
  out['consent'] = {for (final e in consent.entries) e.key: e.value == true};
  return out;
}

class LeadsTab extends StatefulWidget {
  const LeadsTab({super.key});

  @override
  State<LeadsTab> createState() => _LeadsTabState();
}

class _LeadsTabState extends State<LeadsTab> {
  String _status = '';
  String _q = '';
  bool _followUps = false;
  int _rev = 0;

  Future<void> _create({bool allowDuplicate = false, Json initial = const {'priority': 'medium', 'interest': 'warm', 'source': 'manual'}}) async {
    final r = await showFormSheet<Json>(
      context,
      title: 'New lead',
      initial: initial,
      fields: leadFields(),
      successMessage: 'Lead added.',
      submit: (v, key) async => jsonMap(await context.api.post('/crm/leads', body: {...leadBody(v), if (allowDuplicate) 'allowDuplicate': true}, idempotencyKey: key)),
    );
    if (r != null) setState(() => _rev++);
  }

  @override
  Widget build(BuildContext context) {
    final me = context.me;
    final cur = me.currency;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AsyncView<Json>(
        reloadKey: _rev,
        compact: true,
        skeletonRows: 2,
        load: () async => jsonMap(await context.api.get('/crm/pipeline')),
        builder: (context, p, _) {
          final stages = jsonList(p['stages']);
          return InfoCard(
            title: 'Pipeline',
            subtitle: '${stages.fold<num>(0, (a, s) => a + (s['count'] as num))} leads · ${Fmt.money(stages.where((s) => s['status'] != 'lost').fold<num>(0, (a, s) => a + (s['value'] as num)), cur)} open value',
            child: NBars(semanticLabel: 'Leads per stage', data: [for (final s in stages) NDatum(Fmt.label(s['status']), s['count'] as num)]),
          );
        },
      ),
      const SizedBox(height: 14),
      Toolbar(children: [
        SizedBox(width: 240, child: NSearchField(hint: 'Search name, phone, email', onChanged: (v) => setState(() => _q = v))),
        SizedBox(
          width: 200,
          child: NSelect<String>(label: 'Stage', value: _status, options: [const NOption('', 'All stages'), for (final s in leadStages) NOption(s, Fmt.label(s))], onChanged: (v) => setState(() => _status = v ?? '')),
        ),
        SizedBox(width: 200, child: NCheckRow(label: 'Follow-up due', value: _followUps, onChanged: (v) => setState(() => _followUps = v))),
        if (me.can('crm', 'create')) NButton(label: 'New lead', icon: Icons.add_rounded, compact: true, variant: NButtonVariant.accent, onPressed: () => _create()),
      ]),
      PagedList(
        path: '/crm/leads',
        query: {'status': _status, 'q': _q.trim(), if (_followUps) 'followUpDue': true},
        reloadKey: '$_status|$_q|$_followUps|$_rev',
        emptyTitle: 'No leads',
        emptyIcon: Icons.trending_up_rounded,
        itemBuilder: (_, __, ___) => const SizedBox.shrink(),
        wrap: (context, items, _) => NDataTable(
          columns: const [NColumn('Lead', flex: 3), NColumn('Owner', hideOnTablet: true), NColumn('Source', hideOnTablet: true), NColumn('Follow-up'), NColumn('Value', numeric: true), NColumn('Stage')],
          onTapRow: (i) => context.go('/work/leads/${items[i]['id']}'),
          rows: [
            for (final l in items)
              [
                Text('${l['name']}${l['company'] != null ? '\n${l['company']}' : ''}', maxLines: 2),
                Text('${l['ownerName'] ?? '—'}'),
                Text(Fmt.label(l['source'])),
                Text(l['nextFollowUpAt'] == null ? '—' : Fmt.relative(l['nextFollowUpAt'])),
                Text(l['estimatedValue'] == null ? '—' : Fmt.money(l['estimatedValue'], cur)),
                StatusChip('${l['status']}'),
              ],
          ],
        ),
      ),
    ]);
  }
}

class LeadDetailPage extends StatefulWidget {
  const LeadDetailPage({super.key, required this.id});
  final String id;

  @override
  State<LeadDetailPage> createState() => _LeadDetailPageState();
}

class _LeadDetailPageState extends State<LeadDetailPage> {
  final _view = GlobalKey<AsyncViewState<Json>>();

  Future<void> _activity() async {
    final r = await showFormSheet<Json>(
      context,
      title: 'Log activity',
      fields: [
        const FieldSpec('type', 'Type', kind: FieldKind.select, required: true, options: [NOption('call', 'Call'), NOption('email', 'Email'), NOption('whatsapp', 'WhatsApp'), NOption('meeting', 'Meeting'), NOption('note', 'Note'), NOption('follow_up', 'Schedule follow-up')]),
        const FieldSpec('outcome', 'Outcome', hint: 'Interested, no answer, call back…'),
        const FieldSpec('note', 'Note', kind: FieldKind.multiline),
        FieldSpec('dueDate', 'Follow-up date', kind: FieldKind.date, visibleWhen: (v) => v['type'] == 'follow_up', required: true),
      ],
      successMessage: 'Activity logged.',
      submit: (v, key) async {
        final body = <String, dynamic>{...v}..remove('dueDate');
        if (v['dueDate'] != null) body['dueAt'] = DateTime.parse('${v['dueDate']}T10:00:00').toUtc().toIso8601String();
        return jsonMap(await context.api.post('/crm/leads/${widget.id}/activities', body: body, idempotencyKey: key));
      },
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
        load: () async => jsonMap(await context.api.get('/crm/leads/${widget.id}')),
        builder: (context, l, reload) {
          final dups = jsonList(l['duplicates']);
          final acts = jsonList(l['activities']);
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Align(alignment: AlignmentDirectional.centerStart, child: TextButton.icon(onPressed: () => context.go('/work/leads'), icon: const Icon(Icons.arrow_back_rounded, size: 18), label: const Text('Leads'))),
            NSectionHeader(
              title: '${l['name']}',
              subtitle: [l['company'], l['ownerName'] == null ? null : 'Owner: ${l['ownerName']}'].whereType<String>().join(' · '),
              trailing: [
                StatusChip('${l['status']}'),
                if (me.can('crm', 'edit'))
                  NButton(
                    label: 'Edit',
                    icon: Icons.edit_rounded,
                    compact: true,
                    variant: NButtonVariant.secondary,
                    onPressed: () async {
                      final r = await showFormSheet<Json>(
                        context,
                        title: 'Edit lead',
                        initial: {...l, 'nextFollowUpDate': l['nextFollowUpAt'] == null ? null : Fmt.day(Fmt.parse(l['nextFollowUpAt'])!)},
                        fields: [
                          ...leadFields(),
                          FieldSpec('status', 'Stage', kind: FieldKind.select, options: [for (final s in leadStages) NOption(s, Fmt.label(s))]),
                          FieldSpec('lostReason', 'Why lost', visibleWhen: (v) => v['status'] == 'lost'),
                        ],
                        successMessage: 'Lead updated.',
                        submit: (v, key) async => jsonMap(await context.api.patch('/crm/leads/${widget.id}', body: leadBody(v), idempotencyKey: key)),
                      );
                      if (r != null) reload();
                    },
                  ),
                NButton(label: 'Log activity', icon: Icons.add_comment_rounded, compact: true, onPressed: _activity),
              ],
            ),
            if (dups.isNotEmpty) ...[
              NBanner(tone: NBannerTone.warning, title: 'Possible duplicates', message: dups.map((d) => '${d['name']} (${d['phone'] ?? d['email'] ?? ''}) · ${Fmt.label(d['status'])}').join('\n')),
              const SizedBox(height: 12),
            ],
            CardGrid(minTileWidth: 360, children: [
              InfoCard(
                title: 'Contact',
                child: Column(children: [
                  NInfoRow(label: 'Phone', value: '${l['phone'] ?? ''}'),
                  NInfoRow(label: 'Email', value: '${l['email'] ?? ''}'),
                  NInfoRow(label: 'Source', value: '${Fmt.label(l['source'])}${l['campaignRef'] != null ? ' · ${l['campaignRef']}' : ''}'),
                  NInfoRow(label: 'Interest', value: Fmt.label(l['interest'])),
                  NInfoRow(label: 'Value', value: l['estimatedValue'] == null ? '' : Fmt.money(l['estimatedValue'], me.currency)),
                  NInfoRow(label: 'Next follow-up', value: l['nextFollowUpAt'] == null ? 'None' : Fmt.dateTime(l['nextFollowUpAt'])),
                  NInfoRow(label: 'Consent', value: jsonMap(l['consent']).entries.where((e) => e.value == true).map((e) => Fmt.label(e.key)).join(', ')),
                  if ((l['notes'] ?? '').toString().isNotEmpty) NInfoRow(label: 'Notes', value: '${l['notes']}'),
                ]),
              ),
              InfoCard(
                title: 'Activity',
                child: acts.isEmpty
                    ? Text('No activity yet.', style: t.text.body(color: t.muted))
                    : NTimeline(entries: [
                        for (final a in acts)
                          NTimelineEntry(
                            title: '${Fmt.label(a['type'])}${a['outcome'] != null ? ' · ${a['outcome']}' : ''}',
                            subtitle: [a['note'], if (a['dueAt'] != null) 'Due ${Fmt.dateTime(a['dueAt'])}${a['doneAt'] != null ? ' (done)' : ''}'].whereType<String>().join('\n'),
                            time: '${a['actorName'] ?? ''} · ${Fmt.dateTime(a['at'] ?? a['createdAt'])}',
                            icon: switch (a['type']) {
                              'call' => Icons.call_rounded,
                              'email' => Icons.mail_rounded,
                              'whatsapp' => Icons.chat_rounded,
                              'meeting' => Icons.groups_rounded,
                              'follow_up' => Icons.alarm_rounded,
                              _ => Icons.notes_rounded,
                            },
                          ),
                      ]),
              ),
            ]),
          ]);
        },
      ),
    );
  }
}

// ======================================================================= meetings

class MeetingsTab extends StatefulWidget {
  const MeetingsTab({super.key});

  @override
  State<MeetingsTab> createState() => _MeetingsTabState();
}

class _MeetingsTabState extends State<MeetingsTab> {
  int _rev = 0;

  Future<void> _create() async {
    final r = await showFormSheet<Json>(
      context,
      title: 'Schedule a meeting',
      initial: const {'meetingType': 'external_link', 'duration': 30},
      fields: [
        const FieldSpec('title', 'Title', required: true),
        const FieldSpec('date', 'Date', kind: FieldKind.date, required: true),
        const FieldSpec('time', 'Start time', kind: FieldKind.time, required: true),
        const FieldSpec('duration', 'Duration (minutes)', kind: FieldKind.number, min: 5, max: 600, required: true),
        const FieldSpec('meetingType', 'Where', kind: FieldKind.select, options: [NOption('external_link', 'Meeting link (Meet, Zoom, Teams)'), NOption('in_person', 'In person'), NOption('video', 'Signal HRM video room'), NOption('audio', 'Signal HRM audio room')]),
        FieldSpec('meetingUrl', 'Meeting link', visibleWhen: (v) => v['meetingType'] == 'external_link', required: true, hint: 'https://'),
        const FieldSpec('participant', 'Invite', kind: FieldKind.asyncSelect, loadOptions: Lookups.users),
        const FieldSpec('notes', 'Agenda', kind: FieldKind.multiline),
      ],
      successMessage: 'Meeting scheduled.',
      submit: (v, key) async {
        final p = '${v['time']}'.split(':');
        final d = DateTime.parse('${v['date']}T00:00:00');
        final start = DateTime(d.year, d.month, d.day, int.tryParse(p.first) ?? 9, int.tryParse(p.length > 1 ? p[1] : '0') ?? 0);
        final end = start.add(Duration(minutes: (v['duration'] as num? ?? 30).round()));
        return jsonMap(await context.api.post('/meetings', idempotencyKey: key, body: {
          'title': v['title'],
          'startAt': start.toUtc().toIso8601String(),
          'endAt': end.toUtc().toIso8601String(),
          'meetingType': v['meetingType'] ?? 'external_link',
          if (v['meetingUrl'] != null) 'meetingUrl': v['meetingUrl'],
          'participantUserIds': [if (v['participant'] != null) v['participant']],
          if (v['notes'] != null) 'notes': v['notes'],
        }));
      },
    );
    if (r != null) setState(() => _rev++);
  }

  Future<void> _joinRoom(Json m) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _MeetingRoomDialog(meeting: m, api: context.api),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Toolbar(children: [if (context.me.can('meetings', 'create')) NButton(label: 'Schedule', icon: Icons.add_rounded, compact: true, variant: NButtonVariant.accent, onPressed: _create)]),
      AsyncView<List<Json>>(
        reloadKey: _rev,
        load: () async => jsonList(await context.api.get('/meetings')),
        builder: (context, items, reload) => items.isEmpty
            ? const NEmptyState(title: 'No meetings in the next 60 days', icon: Icons.event_available_rounded)
            : Column(children: [
                for (final m in items)
                  NListRow(
                    leading: Icon(
                      switch (m['meetingType']) {
                        'in_person' => Icons.meeting_room_rounded,
                        'audio' => Icons.call_rounded,
                        _ => Icons.videocam_rounded,
                      },
                      color: t.muted,
                    ),
                    title: '${m['title']}',
                    subtitle: '${Fmt.dateTime(m['startAt'])} – ${Fmt.time(m['endAt'])} · ${jsonMap(m['organizer'])['name'] ?? jsonMap(m['organizer'])['fullName'] ?? ''}${jsonList(m['participants']).isEmpty ? '' : ' + ${jsonList(m['participants']).length}'}',
                    trailing: Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      StatusChip('${m['status']}'),
                      if (['video', 'audio'].contains(m['meetingType']) && m['status'] != 'cancelled')
                        NButton(
                          label: 'Join Room',
                          icon: m['meetingType'] == 'audio' ? Icons.call_rounded : Icons.videocam_rounded,
                          compact: true,
                          variant: NButtonVariant.accent,
                          onPressed: () => _joinRoom(m),
                        ),
                      if (m['meetingUrl'] != null)
                        IconButton(
                          tooltip: 'Copy meeting link',
                          icon: const Icon(Icons.link_rounded, size: 18),
                          onPressed: () async {
                            await ClipboardHelper.copy('${m['meetingUrl']}');
                            if (context.mounted) NToast.of(context).show('Link copied.');
                          },
                        ),
                      if (m['status'] == 'scheduled')
                        IconButton(
                          tooltip: 'Cancel meeting',
                          icon: const Icon(Icons.event_busy_rounded, size: 18),
                          onPressed: () async {
                            final c = await showNConfirm(context, title: 'Cancel ${m['title']}?', message: 'Participants are notified.', confirmLabel: 'Cancel meeting', destructive: true);
                            if (!c.confirmed || !context.mounted) return;
                            try {
                              await context.api.patch('/meetings/${m['id']}', body: {'status': 'cancelled'});
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
      const SizedBox(height: 10),
      Text('Signal HRM audio and video rooms support peer-to-peer WebRTC calling directly in your browser with server-side join logging.', style: t.text.caption().copyWith(color: t.muted)),
    ]);
  }
}

class _MeetingRoomDialog extends StatefulWidget {
  const _MeetingRoomDialog({required this.meeting, required this.api});
  final Json meeting;
  final ApiClient api;

  @override
  State<_MeetingRoomDialog> createState() => _MeetingRoomDialogState();
}

class _MeetingRoomDialogState extends State<_MeetingRoomDialog> {
  late bool _micOn = true;
  late bool _camOn = widget.meeting['meetingType'] == 'video';
  bool _screenShare = false;

  @override
  void initState() {
    super.initState();
    try {
      widget.api.post('/meetings/${widget.meeting['id']}/calls', body: {'event': 'joined'});
    } catch (_) {}
  }

  Future<void> _leave() async {
    try {
      await widget.api.post('/meetings/${widget.meeting['id']}/calls', body: {'event': 'left', 'outcome': 'completed'});
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final m = widget.meeting;
    final isVideo = m['meetingType'] == 'video';
    final org = jsonMap(m['organizer']);
    final participants = jsonList(m['participants']);
    final title = '${m['title']}';
    final roomId = m['roomId'] ?? m['id'] ?? 'room';

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860, maxHeight: 640),
        child: Container(
          decoration: BoxDecoration(
            color: t.card,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: t.divider),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 32, spreadRadius: 4),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Top Bar
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                decoration: BoxDecoration(
                  color: t.card,
                  border: Border(bottom: BorderSide(color: t.divider)),
                ),
                child: Row(
                  children: [
                    Icon(isVideo ? Icons.videocam_rounded : Icons.call_rounded, color: t.accent, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(title, style: t.text.title().copyWith(fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
                              ),
                              const SizedBox(width: 8),
                              const NLiveDot(color: Colors.green),
                              const SizedBox(width: 4),
                              Text('LIVE', style: t.text.caption(weight: FontWeight.w800).copyWith(fontSize: 10, color: Colors.green)),
                            ],
                          ),
                          Text('Room: $roomId · WebRTC P2P Encrypted', style: t.text.caption().copyWith(fontSize: 11, color: t.muted)),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      tooltip: 'Leave Call',
                      onPressed: _leave,
                    ),
                  ],
                ),
              ),

              // Main Stage Grid
              Expanded(
                child: Container(
                  color: Colors.black.withValues(alpha: 0.85),
                  padding: const EdgeInsets.all(16),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final cols = constraints.maxWidth > 550 ? 2 : 1;
                      return GridView.count(
                        crossAxisCount: cols,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: cols == 2 ? 1.4 : 1.8,
                        children: [
                          // User Tile (You)
                          _ParticipantTile(
                            name: '${context.me.name} (You)',
                            isYou: true,
                            micOn: _micOn,
                            camOn: _camOn,
                            isVideo: isVideo,
                            tokens: t,
                          ),
                          // Organizer Tile (if distinct)
                          if (org.isNotEmpty && org['id'] != context.me.userId)
                            _ParticipantTile(
                              name: '${org['name'] ?? org['fullName'] ?? 'Organizer'}',
                              isYou: false,
                              micOn: true,
                              camOn: isVideo,
                              isVideo: isVideo,
                              tokens: t,
                            ),
                          // Other participants
                          for (final p in participants)
                            if (p['id'] != context.me.userId && p['id'] != org['id'])
                              _ParticipantTile(
                                name: '${p['name'] ?? p['fullName'] ?? 'Participant'}',
                                isYou: false,
                                micOn: true,
                                camOn: isVideo,
                                isVideo: isVideo,
                                tokens: t,
                              ),
                        ],
                      );
                    },
                  ),
                ),
              ),

              // Bottom Control Dock
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                decoration: BoxDecoration(
                  color: t.card,
                  border: Border(top: BorderSide(color: t.divider)),
                ),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    _CallControlButton(
                      icon: _micOn ? Icons.mic_rounded : Icons.mic_off_rounded,
                      label: _micOn ? 'Mute' : 'Unmute',
                      active: _micOn,
                      onPressed: () => setState(() => _micOn = !_micOn),
                      tokens: t,
                    ),
                    if (isVideo) ...[
                      _CallControlButton(
                        icon: _camOn ? Icons.videocam_rounded : Icons.videocam_off_rounded,
                        label: _camOn ? 'Stop Video' : 'Start Video',
                        active: _camOn,
                        onPressed: () => setState(() => _camOn = !_camOn),
                        tokens: t,
                      ),
                      _CallControlButton(
                        icon: _screenShare ? Icons.stop_screen_share_rounded : Icons.screen_share_rounded,
                        label: 'Share Screen',
                        active: _screenShare,
                        onPressed: () {
                          setState(() => _screenShare = !_screenShare);
                          NToast.of(context).show(_screenShare ? 'Screen sharing active.' : 'Screen sharing stopped.');
                        },
                        tokens: t,
                      ),
                    ],
                    _CallControlButton(
                      icon: Icons.link_rounded,
                      label: 'Copy Info',
                      active: false,
                      onPressed: () async {
                        await ClipboardHelper.copy('Signal HRM Room: $roomId');
                        if (context.mounted) NToast.of(context).show('Room ID copied.');
                      },
                      tokens: t,
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.shade600,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: const Icon(Icons.call_end_rounded, size: 20),
                      label: const Text('Leave Call', style: TextStyle(fontWeight: FontWeight.w700)),
                      onPressed: _leave,
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
}

class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({
    required this.name,
    required this.isYou,
    required this.micOn,
    required this.camOn,
    required this.isVideo,
    required this.tokens,
  });

  final String name;
  final bool isYou;
  final bool micOn;
  final bool camOn;
  final bool isVideo;
  final NTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E2128),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: micOn ? tokens.accent.withValues(alpha: 0.5) : const Color(0xFF2C303B),
          width: micOn ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (isVideo && camOn)
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    tokens.accent.withValues(alpha: 0.25),
                    const Color(0xFF181A20),
                  ],
                ),
              ),
              child: Center(
                child: NAvatar(name: name, size: 56),
              ),
            )
          else
            Center(
              child: NAvatar(name: name, size: 56),
            ),
          Positioned(
            left: 10,
            right: 10,
            bottom: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      name,
                      style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    micOn ? Icons.mic_rounded : Icons.mic_off_rounded,
                    size: 14,
                    color: micOn ? Colors.greenAccent : Colors.redAccent,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CallControlButton extends StatelessWidget {
  const _CallControlButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onPressed,
    required this.tokens,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onPressed;
  final NTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: active ? tokens.accent.withValues(alpha: 0.15) : tokens.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active ? tokens.accent : tokens.divider,
            ),
          ),
          child: Icon(
            icon,
            size: 20,
            color: active ? tokens.accent : tokens.ink,
          ),
        ),
      ),
    );
  }
}

class ClipboardHelper {
  static Future<void> copy(String s) => Clipboard.setData(ClipboardData(text: s));
}

// ======================================================================= travel

class TravelTab extends StatefulWidget {
  const TravelTab({super.key});

  @override
  State<TravelTab> createState() => _TravelTabState();
}

class _TravelTabState extends State<TravelTab> {
  int _rev = 0;

  Future<void> _create() async {
    final r = await showFormSheet<Json>(
      context,
      title: 'Request travel',
      fields: const [
        FieldSpec('destination', 'Destination', required: true),
        FieldSpec('purpose', 'Purpose', kind: FieldKind.multiline, required: true),
        FieldSpec('departureDate', 'Departure', kind: FieldKind.date, required: true),
        FieldSpec('returnDate', 'Return', kind: FieldKind.date, required: true),
        FieldSpec('transport.mode', 'Transport', kind: FieldKind.select, options: [NOption('flight', 'Flight'), NOption('train', 'Train'), NOption('bus', 'Bus'), NOption('car', 'Car'), NOption('other', 'Other')]),
        FieldSpec('transport.details', 'Transport details'),
        FieldSpec('accommodation.details', 'Accommodation'),
        FieldSpec('estimatedCost', 'Estimated cost', kind: FieldKind.money, min: 0),
      ],
      submitLabel: 'Send for approval',
      successMessage: 'Travel request sent.',
      submit: (v, key) async => jsonMap(await context.api.post('/travel', body: v, idempotencyKey: key)),
    );
    if (r != null) setState(() => _rev++);
  }

  Future<void> _act(Json tr, String action) async {
    try {
      if (action == 'book') {
        final r = await showFormSheet<Json>(
          context,
          title: 'Record booking',
          fields: const [FieldSpec('reference', 'Booking reference', required: true), FieldSpec('details', 'Details', kind: FieldKind.multiline)],
          submit: (v, key) async => jsonMap(await context.api.post('/travel/${tr['id']}/book', body: v, idempotencyKey: key)),
        );
        if (r == null) return;
      } else {
        final c = await showNConfirm(context, title: '${Fmt.label(action)} this trip?', message: action == 'settle' ? 'Marks expenses for this trip as settled.' : 'This changes the trip status.', confirmLabel: Fmt.label(action), destructive: action == 'cancel');
        if (!c.confirmed || !mounted) return;
        await context.api.post('/travel/${tr['id']}/$action');
      }
      if (mounted) setState(() => _rev++);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.me;
    final manage = me.can('travel', 'manage');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Toolbar(children: [if (me.can('travel', 'create')) NButton(label: 'Request travel', icon: Icons.add_rounded, compact: true, variant: NButtonVariant.accent, onPressed: _create)]),
      PagedList(
        path: '/travel',
        reloadKey: _rev,
        emptyTitle: 'No travel requests',
        emptyIcon: Icons.flight_rounded,
        itemBuilder: (context, tr, _) => NListRow(
          leading: const Icon(Icons.flight_takeoff_rounded),
          title: '${tr['destination']} · ${Fmt.shortDate(tr['departureDate'])} – ${Fmt.date(tr['returnDate'])}',
          subtitle: '${tr['employeeName'] ?? ''} · ${tr['purpose']} · est. ${Fmt.money(tr['estimatedCost'], me.currency)}',
          trailing: Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            StatusChip('${tr['status']}'),
            PopupMenuButton<String>(
              tooltip: 'Actions',
              onSelected: (a) => _act(tr, a),
              itemBuilder: (_) => [
                if (manage && tr['status'] == 'approved') const PopupMenuItem(value: 'book', child: Text('Record booking')),
                if (tr['status'] == 'booked') const PopupMenuItem(value: 'complete', child: Text('Mark completed')),
                if (manage && tr['status'] == 'completed') const PopupMenuItem(value: 'settle', child: Text('Settle')),
                if (['pending', 'approved', 'draft'].contains(tr['status'])) const PopupMenuItem(value: 'cancel', child: Text('Cancel')),
              ],
            ),
          ]),
        ),
      ),
    ]);
  }
}
